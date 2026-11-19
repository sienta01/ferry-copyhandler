import AppKit
import FerryCore
import SwiftUI
import UniformTypeIdentifiers

/// The main window: the copy list. This is what opens when you launch Ferry; there's no file picker.
struct TransfersView: View {
    @ObservedObject var queue: TransferQueue
    let app: AppController
    // ObservableObjects instead of SwiftUI's State: in this SDK State is a macro whose plugin
    // ships only with Xcode, and Ferry builds with the Command Line Tools alone.
    @StateObject private var ui = TransfersUIState()

    private var selectedJob: Job? {
        if let selection = ui.selection, let job = queue.jobs.first(where: { $0.id == selection }) { return job }
        return queue.jobs.first(where: { !$0.isDone }) ?? queue.jobs.last
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // Questions (conflicts, errors, low space) sit above the list so they're never scrolled away.
            ForEach(queue.jobs.filter { !$0.isDone }) { job in
                PromptBanner(job: job)
            }
            if queue.jobs.isEmpty {
                EmptyStateView(app: app)
            } else {
                GeometryReader { geo in
                    VStack(spacing: 0) {
                        if ui.showFiles {
                            // Jobs get the height their rows need (up to half); the file list gets the rest.
                            jobList.frame(height: jobListHeight(available: geo.size.height))
                        } else {
                            jobList.frame(maxHeight: .infinity)
                        }
                        FilePane(job: selectedJob, expanded: $ui.showFiles)
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 340)
        .overlay(dropOverlay)
        .onDrop(of: [UTType.fileURL], isTargeted: $ui.dropTargeted, perform: handleDrop)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summaryTitle).font(.headline)
                Text(summarySubtitle).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Menu {
                Button("Copy Files To…") { app.chooseSourcesAndTransfer(.copy) }
                Button("Move Files To…") { app.chooseSourcesAndTransfer(.move) }
                Divider()
                Button("Paste Copied Files Into…") { app.pasteFromClipboard(into: nil, .copy) }
            } label: {
                Label("New", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .focusable(false)
            .help("Start a new copy or move")

            if !queue.activeJobs.isEmpty {
                let allPaused = queue.activeJobs.allSatisfy(\.isPaused)
                Button {
                    allPaused ? queue.resumeAll() : queue.pauseAll()
                } label: {
                    Image(systemName: allPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .help(allPaused ? "Resume all" : "Pause all")
            }
            Button("Clear Finished") {
                if let s = ui.selection, queue.jobs.first(where: { $0.id == s })?.isDone == true { ui.selection = nil }
                queue.clearFinished()
            }
            .disabled(!queue.hasFinishedJobs)
            .focusable(false)
            Button {
                app.showSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .focusable(false)
            .help("Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var jobList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(queue.jobs) { job in
                    JobRow(job: job, queue: queue, app: app, selected: job.id == selectedJob?.id)
                        .contentShape(Rectangle())
                        .onTapGesture { ui.selection = job.id }
                    Divider()
                }
            }
        }
    }

    private func jobListHeight(available: CGFloat) -> CGFloat {
        let wanted = CGFloat(queue.jobs.count) * 92 + 2
        return min(max(wanted, 96), max(120, available * 0.5))
    }

    private var summaryTitle: String {
        let active = queue.activeJobs.count
        let waiting = queue.waitingJobs.count
        if active == 0 && waiting == 0 { return "All transfers finished" }
        var parts: [String] = []
        if active > 0 { parts.append("\(active) running") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        return parts.joined(separator: ", ")
    }

    private var summarySubtitle: String {
        guard !queue.activeJobs.isEmpty else { return "Drop files here, or use Ferry from Finder's right-click menu." }
        let speed = queue.overallSpeed
        return "\(Int(queue.overallFraction * 100))% overall" + (speed > 1 ? " — \(Fmt.speed(speed))" : "")
    }

    @ViewBuilder private var dropOverlay: some View {
        if ui.dropTargeted {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.08)))
                .overlay(Text("Drop to choose a destination (hold ⌥ to move)").font(.title3.weight(.medium)))
                .padding(8)
                .allowsHitTesting(false)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let kind: TransferKind = NSEvent.modifierFlags.contains(.option) ? .move : .copy
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                lock.lock(); urls.append(url); lock.unlock()
            }
        }
        group.notify(queue: .main) { app.chooseDestination(for: urls, kind) }
        return true
    }
}

final class TransfersUIState: ObservableObject {
    @Published var selection: UUID?
    @Published var dropTargeted = false
    @Published var showFiles = UserDefaults.standard.object(forKey: "showFileList") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showFiles, forKey: "showFileList") }
    }
}

struct EmptyStateView: View {
    let app: AppController
    @ObservedObject private var status = SystemStatus.shared

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.secondary)
            Text("No transfers").font(.title2.weight(.semibold))
            Text("Drop files here, or select files in Finder, press ⌘C, then right-click a folder and choose “Paste with Ferry”.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            HStack {
                Button("Copy Files To…") { app.chooseSourcesAndTransfer(.copy) }
                Button("Move Files To…") { app.chooseSourcesAndTransfer(.move) }
                Button("Paste Copied Files…") { app.pasteFromClipboard(into: nil, .copy) }
            }
            if !status.extensionEnabled {
                Button("Turn On the Finder Right-Click Menu…") { FinderBridge.openExtensionSettings() }
                    .buttonStyle(.link)
                    .padding(.top, 4)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { status.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            status.refresh()
        }
    }
}
