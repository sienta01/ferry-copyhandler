import AppKit
import Combine
import FerryCore
import SwiftUI
import UserNotifications

/// Owns the queue, the windows and every user-facing action. Main thread only.
final class AppController: NSObject, NSWindowDelegate, UNUserNotificationCenterDelegate {
    static let shared = AppController()

    let queue = TransferQueue()
    let settings = Settings.shared
    private var statusItem: StatusItemController?
    var statusButton: NSView? { statusItem?.button }
    var statusItemVisible: Bool { statusItem?.isVisible ?? false }
    private var transfersWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var refreshTimer: Timer?
    private var askedForNotifications = false
    private var cancellables = Set<AnyCancellable>()

    func start(showWindow: Bool) {
        queue.jobWillStart = { [weak self] job in
            job.useInteractivePrompts { _ in
                self?.queue.objectWillChange.send()
                self?.showTransfers(activate: true)
            }
            self?.scheduleRefresh()
        }
        queue.jobDidFinish = { [weak self] job in self?.jobFinished(job) }
        statusItem = StatusItemController(app: self)
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate = self }

        settings.$handleFinderPaste
            .removeDuplicates()
            .sink { PasteInterceptor.shared.setEnabled($0) }
            .store(in: &cancellables)
        settings.$showPercentInMenuBar
            .sink { [weak self] _ in DispatchQueue.main.async { self?.statusItem?.update() } }
            .store(in: &cancellables)
        settings.$hideMenuBarIconWhenIdle
            .sink { [weak self] _ in DispatchQueue.main.async { self?.statusItem?.update() } }
            .store(in: &cancellables)

        if showWindow { showTransfers(activate: true) }
    }

    // MARK: Transfers

    func enqueue(_ kind: TransferKind, sources: [URL], destination: URL) {
        let paths = sources.filter(\.isFileURL).map(\.path)
        guard !paths.isEmpty else { return }
        let job = queue.add(kind, sources: paths, destination: destination.path, options: settings.transferOptions)
        scheduleRefresh()
        statusItem?.update()
        if settings.notifyWhenDone && !askedForNotifications && Bundle.main.bundleIdentifier != nil && !DevSnapshot.isActive {
            askedForNotifications = true
            Notifier.requestAuthorization()
        }
        if settings.showWindowOnTransfer {
            // Quick copies finish before this fires, so they never flash a window.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self, weak job] in
                guard let self, let job, !job.isDone else { return }
                self.showTransfers(activate: false)
            }
        }
    }

    /// Menu bar / window "Copy Files…": pick sources, then a destination.
    func chooseSourcesAndTransfer(_ kind: TransferKind) {
        activate()
        let panel = NSOpenPanel()
        panel.title = kind == .copy ? "Choose What to Copy" : "Choose What to Move"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        chooseDestination(for: panel.urls, kind)
    }

    func chooseDestination(for sources: [URL], _ kind: TransferKind) {
        guard !sources.isEmpty else { return }
        activate()
        let panel = NSOpenPanel()
        let what = sources.count == 1 ? "“\(sources[0].lastPathComponent)”" : plural(sources.count, "item")
        panel.title = "\(kind.verb) \(what) To…"
        panel.message = "Choose where to \(kind == .copy ? "copy" : "move") \(what)."
        panel.prompt = kind == .copy ? "Copy Here" : "Move Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        enqueue(kind, sources: sources, destination: destination)
    }

    /// Transfers the files currently on the clipboard (copied in Finder with ⌘C).
    func pasteFromClipboard(into destination: URL?, _ kind: TransferKind) {
        let files = Clipboard.fileURLs()
        guard !files.isEmpty else {
            activate()
            let alert = NSAlert()
            alert.messageText = "There are no copied files"
            alert.informativeText = "Select files in Finder and press ⌘C first, then paste them with Ferry."
            alert.runModal()
            return
        }
        if let destination {
            enqueue(kind, sources: files, destination: destination)
        } else {
            chooseDestination(for: files, kind)
        }
    }

    func reveal(_ job: Job) {
        let urls = job.destinationPaths()
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
        if urls.isEmpty {
            NSWorkspace.shared.open(URL(fileURLWithPath: job.destination))
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    func copyProblemReport(_ job: Job) {
        let lines = job.problemRows().map { "\($0.path): \($0.message ?? "failed")" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    // MARK: Incoming requests (URL scheme, services, files)

    func open(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty {
            DispatchQueue.main.async { self.chooseDestination(for: files, .copy) }
        }
        for url in urls where url.scheme == "ferry" { handle(url) }
    }

    private func handle(_ url: URL) {
        if url.host == "show" {
            showTransfers(activate: true)
            return
        }
        guard let request = IPCRequest(url: url), request.isAuthentic else {
            NSLog("Ferry: ignored a ferry:// request that didn't come from the Finder extension")
            return
        }
        let sources = request.sources.map { URL(fileURLWithPath: $0) }
        // Return from the Apple event first; panels and alerts can then run without blocking Finder.
        DispatchQueue.main.async {
            switch request.action {
            case "paste":
                self.pasteFromClipboard(into: request.destination.map { URL(fileURLWithPath: $0, isDirectory: true) },
                                        request.move ? .move : .copy)
            case "copyto": self.chooseDestination(for: sources, .copy)
            case "moveto": self.chooseDestination(for: sources, .move)
            default: break
            }
        }
    }

    // MARK: Windows and Dock icon

    func showTransfers(activate: Bool) {
        if transfersWindow == nil {
            let host = NSHostingController(rootView: TransfersView(queue: queue, app: self))
            let window = NSWindow(contentViewController: host)
            window.title = "Ferry"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 900, height: 560))
            window.minSize = NSSize(width: 520, height: 380)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("FerryTransfers")
            transfersWindow = window
        }
        present(transfersWindow!, activate: activate)
        scheduleRefresh()
    }

    func showSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(settings: settings))
            host.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: host)
            window.title = "Ferry Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        present(settingsWindow!, activate: true)
    }

    /// The Dock icon only exists while a Ferry window is open.
    private func present(_ window: NSWindow, activate: Bool) {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        if activate {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else if !window.isVisible {
            window.orderFrontRegardless() // shows up without stealing focus from Finder
        }
    }

    private func activate() {
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        DispatchQueue.main.async {
            // Drop closed windows so their views are freed; they're rebuilt on demand.
            if window === self.transfersWindow { self.transfersWindow = nil }
            if window === self.settingsWindow { self.settingsWindow = nil }
            self.updateActivationPolicy()
        }
    }

    private func updateActivationPolicy() {
        let open = [transfersWindow, settingsWindow].contains { w in
            guard let w else { return false }
            return w.isVisible || w.isMiniaturized
        }
        let policy: NSApplication.ActivationPolicy = open ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    // MARK: Refresh loop (runs only while something is transferring)

    private var windowIsOnScreen: Bool {
        guard let w = transfersWindow else { return false }
        return w.isVisible && w.occlusionState.contains(.visible)
    }

    private func scheduleRefresh() {
        guard queue.hasUnfinishedJobs else {
            refreshTimer?.invalidate()
            refreshTimer = nil
            return
        }
        let interval: TimeInterval = windowIsOnScreen ? 0.25 : 1.0
        if let t = refreshTimer, abs(t.timeInterval - interval) < 0.01 { return }
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = interval * 0.25
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func tick() {
        queue.refreshProgress(notify: windowIsOnScreen)
        statusItem?.update()
        scheduleRefresh()
    }

    private func jobFinished(_ job: Job) {
        statusItem?.update()
        scheduleRefresh()
        let watching = NSApp.isActive && transfersWindow?.isKeyWindow == true
        if settings.notifyWhenDone && !watching && Bundle.main.bundleIdentifier != nil { Notifier.post(for: job) }
    }

    // MARK: Quit

    private var quitDeadline: Date?

    func applicationShouldTerminate() -> NSApplication.TerminateReply {
        guard queue.hasUnfinishedJobs else { return .terminateNow }
        activate()
        let alert = NSAlert()
        alert.messageText = "Stop transfers and quit?"
        alert.informativeText = "Files that are already done stay where they are. The file in progress is discarded."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        queue.cancelAll()
        // Give the engine a moment to delete its half-written temp file before exiting.
        quitDeadline = Date().addingTimeInterval(3)
        waitForJobsThenQuit()
        return .terminateLater
    }

    private func waitForJobsThenQuit() {
        if queue.activeJobs.isEmpty || Date() > (quitDeadline ?? .distantPast) {
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.waitForJobsThenQuit() }
    }

    // MARK: Notifications

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { self.showTransfers(activate: true) }
        completionHandler()
    }
}
