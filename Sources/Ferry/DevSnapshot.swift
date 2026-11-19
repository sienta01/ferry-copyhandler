import AppKit
import FerryCore

/// Developer aid: renders Ferry's windows to PNG files without needing screen-recording permission.
/// Only active when FERRY_SNAPSHOT_DIR is set, e.g.
///
///   FERRY_SNAPSHOT_DIR=/tmp/shots \
///   FERRY_DEMO_JOBS="copy|/path/a,/path/b|/dest;move|/path/c|/dest2" \
///   FERRY_DEMO_PAUSE=0.4 Ferry.app/Contents/MacOS/Ferry
enum DevSnapshot {
    static var isActive: Bool { ProcessInfo.processInfo.environment["FERRY_SNAPSHOT_DIR"] != nil }

    static func run() {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["FERRY_SNAPSHOT_DIR"] else { return }
        let app = AppController.shared
        let visibleWhenIdle = app.statusItemVisible
        for spec in (env["FERRY_DEMO_JOBS"] ?? "").split(separator: ";") {
            let parts = spec.split(separator: "|").map(String.init)
            guard parts.count == 3, let kind = TransferKind(rawValue: parts[0]) else { continue }
            let sources = parts[1].split(separator: ",").map { URL(fileURLWithPath: String($0)) }
            app.enqueue(kind, sources: sources, destination: URL(fileURLWithPath: parts[2]))
            app.queue.jobs.last.map(app.queue.startNow)
        }
        app.showTransfers(activate: false)
        let pause = Double(env["FERRY_DEMO_PAUSE"] ?? "") ?? 0.4
        DispatchQueue.main.asyncAfter(deadline: .now() + pause) {
            app.queue.jobs.filter { $0.isStarted && !$0.isDone && $0.pendingPrompt == nil }.forEach { $0.pause() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + pause + 1.5) {
            app.queue.refreshProgress(notify: true)
            let lines = app.queue.jobs.map { "\($0.headline): \($0.statusText)" }
                + ["menu bar icon visible: idle=\(visibleWhenIdle) busy=\(app.statusItemVisible)"]
            try? lines.joined(separator: "\n").write(toFile: dir + "/jobs.txt", atomically: true, encoding: .utf8)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3)) // let SwiftUI apply the update
            if let w = NSApp.windows.first(where: { $0.title == "Ferry" }) { save(w, to: dir + "/transfers.png") }
            if let button = app.statusButton { save(button, to: dir + "/menubar.png") }
            app.showSettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if let w = NSApp.windows.first(where: { $0.title == "Ferry Settings" }) { save(w, to: dir + "/settings.png") }
                let rss = residentMemory()
                try? "\(rss)\n".write(toFile: dir + "/rss.txt", atomically: true, encoding: .utf8)
                app.queue.cancelAll()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let line = "\nmenu bar icon visible after the last transfer ended: \(app.statusItemVisible)\n"
                    if let h = FileHandle(forWritingAtPath: dir + "/jobs.txt") { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
                    exit(0)
                }
            }
        }
    }

    private static func save(_ window: NSWindow, to path: String) {
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        save(view, to: path)
    }

    private static func save(_ view: NSView, to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Physical footprint: the "Memory" column in Activity Monitor.
    static func residentMemory() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint) : -1
    }
}
