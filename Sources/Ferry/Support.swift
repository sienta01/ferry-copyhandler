import AppKit
import FerryCore
import UserNotifications

enum Clipboard {
    /// Checks only the pasteboard's types, which doesn't count as reading it.
    static var hasFiles: Bool { NSPasteboard.general.availableType(from: [.fileURL]) != nil }

    static func fileURLs() -> [URL] {
        let objects = NSPasteboard.general.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true])
        return (objects as? [URL]) ?? []
    }
}

func plural(_ n: Int, _ word: String) -> String {
    "\(Fmt.count(n)) \(word)\(n == 1 ? "" : "s")"
}

extension Job {
    /// One-line status used by the window rows and the menu bar menu.
    var statusText: String {
        let s = snapshot
        switch s.phase {
        case .queued:
            return "Waiting for the transfer ahead of it"
        case .scanning:
            return "Preparing… \(plural(s.totalItems, "item")), \(Fmt.bytes(s.totalBytes))"
        case .running:
            if pendingPrompt != nil || s.waitingForAnswer { return "Waiting for your answer" }
            var text = "\(Fmt.bytes(s.processedBytes)) of \(Fmt.bytes(s.totalBytes))"
            if isPaused { return "Paused — " + text }
            if speed > 1 { text += " — \(Fmt.speed(speed))" }
            if let left = secondsRemaining, left >= 1 { text += " — \(Fmt.duration(left)) left" }
            if s.verifying { text += " — verifying" }
            return text
        case .finished(let state):
            let elapsed = (s.finishedAt ?? Date()).timeIntervalSince(s.startedAt ?? Date())
            var summary = "\(kind.past) \(plural(s.copiedItems, "file")) (\(Fmt.bytes(s.totalBytes))) in \(Fmt.duration(elapsed))"
            if averageSpeed > 1, elapsed >= 1 { summary += " — \(Fmt.speed(averageSpeed))" }
            if s.skippedItems > 0 { summary += " — \(Fmt.count(s.skippedItems)) skipped" }
            switch state {
            case .completed: return summary
            case .completedWithIssues: return "\(plural(s.failedItems, "problem")) — " + summary
            case .cancelled: return "Stopped — \(Fmt.count(s.copiedItems)) of \(plural(s.totalItems, "item")) done"
            case .failed(let message): return message
            }
        }
    }

    var headline: String { "\(kind.progressive) \(title) to “\(destinationName)”" }
}

enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(for job: Job) {
        let s = job.snapshot
        let content = UNMutableNotificationContent()
        switch s.phase {
        case .finished(.completed):
            content.title = "\(job.kind.verb) complete"
            content.body = "\(plural(s.copiedItems, "file")) (\(Fmt.bytes(s.totalBytes))) to “\(job.destinationName)”"
                + (s.skippedItems > 0 ? ", \(Fmt.count(s.skippedItems)) skipped" : "")
        case .finished(.completedWithIssues):
            content.title = "\(job.kind.verb) finished with \(plural(s.failedItems, "problem"))"
            content.body = "Open Ferry to see which files weren't \(job.kind == .copy ? "copied" : "moved")."
        case .finished(.failed(let message)):
            content.title = "\(job.kind.verb) failed"
            content.body = message
        default:
            return
        }
        content.sound = .default
        let request = UNNotificationRequest(identifier: job.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
