import AppKit
import FerryCore

/// The menu bar item. Uses template images so it's visible on light, dark and tinted menu bars
/// (Ultracopier's tray icon is a fixed-colour bitmap, which is why it disappears on macOS).
final class StatusItemController: NSObject, NSMenuDelegate, NSWindowDelegate {
    private let item: NSStatusItem
    var button: NSStatusBarButton? { item.button }
    var isVisible: Bool { item.isVisible }
    private unowned let app: AppController
    private let idleImage: NSImage?
    private let pausedImage: NSImage?
    private let attentionImage: NSImage?
    private var lastRingStep = -1

    init(app: AppController) {
        self.app = app
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        idleImage = StatusItemController.symbol("doc.on.doc.fill")
        pausedImage = StatusItemController.symbol("pause.circle.fill")
        attentionImage = StatusItemController.symbol("exclamationmark.circle.fill")
        super.init()

        item.autosaveName = "FerryStatusItem"
        item.behavior = [] // can't be ⌘-dragged out of the menu bar by accident
        // Visible unless the user chose to hide it while idle (nothing is queued at launch).
        item.isVisible = !app.settings.hideMenuBarIconWhenIdle

        if let button = item.button {
            button.image = idleImage
            button.imagePosition = .imageLeading
            button.toolTip = "Ferry"
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
            // Dropping files on the icon asks where to copy them (hold ⌥ to move).
            button.window?.registerForDraggedTypes([.fileURL])
            button.window?.delegate = self
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
    }

    private static func symbol(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Ferry")?.withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    /// A progress ring drawn as a template image.
    private static func ring(_ fraction: Double) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let inset = rect.insetBy(dx: 1.5, dy: 1.5)
            let track = NSBezierPath(ovalIn: inset)
            track.lineWidth = 2
            NSColor.black.withAlphaComponent(0.3).setStroke()
            track.stroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: inset.width / 2,
                          startAngle: 90, endAngle: 90 - 360 * CGFloat(max(0.03, min(1, fraction))), clockwise: true)
            arc.lineWidth = 2
            arc.lineCapStyle = .round
            NSColor.black.setStroke()
            arc.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Ferry progress"
        return image
    }

    func update() {
        // "Hide when not in use": the icon appears while anything is queued, running or waiting
        // for an answer, and disappears when the last transfer ends.
        let shouldShow = !app.settings.hideMenuBarIconWhenIdle || app.queue.hasUnfinishedJobs
        if item.isVisible != shouldShow { item.isVisible = shouldShow }

        guard let button = item.button else { return }
        let running = app.queue.activeJobs
        guard !running.isEmpty else {
            button.image = idleImage
            button.title = ""
            button.toolTip = "Ferry"
            lastRingStep = -1
            return
        }
        let fraction = app.queue.overallFraction
        let percent = Int((fraction * 100).rounded(.down))
        if running.contains(where: { $0.pendingPrompt != nil }) {
            button.image = attentionImage
            lastRingStep = -1
        } else if running.allSatisfy(\.isPaused) {
            button.image = pausedImage
            lastRingStep = -1
        } else {
            let step = Int(fraction * 40) // redraw the ring only when it visibly changes
            if step != lastRingStep {
                lastRingStep = step
                button.image = StatusItemController.ring(fraction)
            }
        }
        button.title = app.settings.showPercentInMenuBar ? " \(percent)%" : ""
        let speed = app.queue.overallSpeed
        button.toolTip = "Ferry — \(percent)%" + (speed > 1 ? ", \(Fmt.speed(speed))" : "")
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let actions = MenuActions.shared
        let unfinished = app.queue.jobs.filter { !$0.isDone }

        if unfinished.isEmpty {
            let idle = NSMenuItem(title: "No transfers in progress", action: nil, keyEquivalent: "")
            idle.isEnabled = false
            menu.addItem(idle)
        } else {
            for job in unfinished.prefix(4) {
                job.refresh()
                let entry = NSMenuItem(title: job.headline, action: #selector(MenuActions.transfers), keyEquivalent: "")
                entry.target = actions
                entry.attributedTitle = twoLine(job.headline, job.statusText)
                menu.addItem(entry)
            }
            if unfinished.count > 4 {
                let more = NSMenuItem(title: "and \(unfinished.count - 4) more…", action: nil, keyEquivalent: "")
                more.isEnabled = false
                menu.addItem(more)
            }
        }
        menu.addItem(MainMenu.item("Show Transfers", #selector(MenuActions.transfers), "", target: actions))
        menu.addItem(.separator())
        menu.addItem(MainMenu.item("Copy Files To…", #selector(MenuActions.copyFiles), "", target: actions))
        menu.addItem(MainMenu.item("Move Files To…", #selector(MenuActions.moveFiles), "", target: actions))
        let paste = MainMenu.item("Paste Copied Files Into…", #selector(MenuActions.pasteFiles), "", target: actions)
        paste.isEnabled = Clipboard.hasFiles
        menu.addItem(paste)

        if !unfinished.isEmpty {
            menu.addItem(.separator())
            if app.queue.activeJobs.contains(where: { !$0.isPaused }) {
                menu.addItem(MainMenu.item("Pause All", #selector(MenuActions.pauseAll), "", target: actions))
            } else {
                menu.addItem(MainMenu.item("Resume All", #selector(MenuActions.resumeAll), "", target: actions))
            }
            menu.addItem(MainMenu.item("Stop All", #selector(MenuActions.cancelAll), "", target: actions))
        }
        menu.addItem(.separator())
        menu.addItem(MainMenu.item("Settings…", #selector(MenuActions.settings), ",", target: actions))
        menu.addItem(MainMenu.item("Quit Ferry", #selector(MenuActions.quit), "q", target: actions))
    }

    private func twoLine(_ first: String, _ second: String) -> NSAttributedString {
        let text = NSMutableAttributedString(string: first, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        text.append(NSAttributedString(string: "\n" + second, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return text
    }

    // MARK: Drag and drop onto the icon (NSWindow forwards dragging messages to its delegate)

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? [] : (NSEvent.modifierFlags.contains(.option) ? .move : .copy)
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        let kind: TransferKind = NSEvent.modifierFlags.contains(.option) ? .move : .copy
        DispatchQueue.main.async { self.app.chooseDestination(for: urls, kind) }
        return true
    }

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}
