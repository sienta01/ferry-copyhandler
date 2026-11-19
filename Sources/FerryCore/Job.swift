import Combine
import Foundation

public enum FinishState: Equatable, Sendable {
    case completed, completedWithIssues, cancelled
    case failed(String)
}

public enum JobPhase: Equatable, Sendable {
    case queued, scanning, running
    case finished(FinishState)
}

/// Progress counters written by the engine thread and copied out for the UI.
public struct JobStats: Equatable, Sendable {
    public var phase: JobPhase = .queued
    public var totalBytes: Int64 = 0
    /// Bytes of items that are finished (copied, skipped or failed).
    public var committedBytes: Int64 = 0
    /// Bytes of the item in flight.
    public var currentBytes: Int64 = 0
    /// Bytes actually read and written (excludes clones and renames); drives the speed readout.
    public var transferredBytes: Int64 = 0
    public var totalItems = 0
    public var finishedItems = 0
    public var copiedItems = 0
    public var skippedItems = 0
    public var failedItems = 0
    public var currentPath = ""
    /// Index of the item in flight in the job's file list, or -1.
    public var currentIndex = -1
    public var verifying = false
    public var waitingForAnswer = false
    public var startedAt: Date?
    public var finishedAt: Date?

    public var processedBytes: Int64 { committedBytes + currentBytes }
    public var isFinished: Bool {
        if case .finished = phase { return true }
        return false
    }
    public var fraction: Double {
        switch phase {
        case .finished(.completed), .finished(.completedWithIssues): return 1
        default: break
        }
        if totalBytes > 0 { return min(1, Double(processedBytes) / Double(totalBytes)) }
        if totalItems > 0 { return Double(finishedItems) / Double(totalItems) }
        return 0
    }
}

/// Pause / cancel / skip switches shared between the UI and the engine thread.
public final class JobControl: @unchecked Sendable {
    private let cond = NSCondition()
    private var paused = false
    private var cancelled = false
    private var skip = false

    public init() {}

    public var isPaused: Bool { cond.lock(); defer { cond.unlock() }; return paused }
    public var isCancelled: Bool { cond.lock(); defer { cond.unlock() }; return cancelled }

    public func pause() { cond.lock(); paused = true; cond.unlock() }
    public func resume() { cond.lock(); paused = false; cond.broadcast(); cond.unlock() }
    public func cancel() { cond.lock(); cancelled = true; paused = false; cond.broadcast(); cond.unlock() }
    /// Abandons the file in flight; the job carries on with the next one (and stays paused if it was).
    public func skipCurrent() { cond.lock(); skip = true; cond.broadcast(); cond.unlock() }

    func clearSkip() { cond.lock(); skip = false; cond.unlock() }

    /// Blocks while paused. Called between files and after every chunk.
    func checkpoint() -> Flow {
        cond.lock(); defer { cond.unlock() }
        while paused && !cancelled && !skip { cond.wait() }
        if cancelled { return .cancel }
        if skip { skip = false; return .skip }
        return .proceed
    }
}

/// A question waiting for the user. Answer it on the main thread.
public final class PendingPrompt: Identifiable {
    public let id = UUID()
    public let prompt: Prompt
    private let reply: (PromptResponse) -> Void
    private var answered = false

    init(_ prompt: Prompt, reply: @escaping (PromptResponse) -> Void) {
        self.prompt = prompt
        self.reply = reply
    }

    public func answer(_ response: PromptResponse) {
        guard !answered else { return }
        answered = true
        reply(response)
    }
}

public final class Job: ObservableObject, Identifiable, @unchecked Sendable {
    public let id = UUID()
    public let kind: TransferKind
    public let sources: [String]
    public let destination: String
    public let options: TransferOptions
    public let control = JobControl()
    public let createdAt = Date()

    /// Called on the engine thread when a decision is needed; the job waits for the answer.
    /// Without a handler the job uses safe defaults (skip on conflicts and errors).
    public var promptHandler: ((Prompt) -> PromptResponse)?

    // Engine state, guarded by `lock`.
    private let lock = NSLock()
    private var stats = JobStats()
    private var items: [TransferItem] = []
    private var roots: [TransferRoot] = []

    // Main-thread state for SwiftUI, refreshed by `refresh()` at a fixed rate rather than per chunk.
    @Published public private(set) var snapshot = JobStats()
    @Published public private(set) var speed: Double = 0
    @Published public private(set) var isPaused = false
    @Published public private(set) var isStarted = false
    @Published public private(set) var isDone = false
    @Published public var pendingPrompt: PendingPrompt?
    private var lastSample: (time: TimeInterval, bytes: Int64)?

    public init(kind: TransferKind, sources: [String], destination: String, options: TransferOptions) {
        self.kind = kind
        self.sources = sources.map(Job.clean)
        self.destination = Job.clean(destination)
        self.options = options
    }

    private static func clean(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    // MARK: Running

    /// Runs the job on its own thread; `completion` is called on the main thread.
    func start(completion: @escaping () -> Void) {
        isStarted = true
        let thread = Thread { [self] in
            JobRunner(job: self).run()
            DispatchQueue.main.async {
                self.isDone = true
                self.refresh()
                completion()
            }
        }
        thread.name = "Ferry transfer"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Runs the job on the calling thread (command line tool, tests).
    public func runSynchronously() {
        JobRunner(job: self).run()
    }

    func markCancelledBeforeStart() {
        control.cancel()
        update { $0.phase = .finished(.cancelled) }
        isDone = true
        refresh()
    }

    // MARK: UI-side helpers (main thread)

    public func refresh() {
        let s = currentStats()
        let now = ProcessInfo.processInfo.systemUptime
        let paused = control.isPaused
        if s.phase == .running && !paused && !s.waitingForAnswer {
            if let last = lastSample {
                let dt = now - last.time
                if dt >= 0.2 {
                    let instant = Double(s.transferredBytes - last.bytes) / dt
                    let next = speed == 0 ? instant : speed * 0.7 + instant * 0.3
                    if next != speed { speed = next }
                    lastSample = (now, s.transferredBytes)
                }
            } else {
                lastSample = (now, s.transferredBytes)
            }
        } else {
            if speed != 0 { speed = 0 }
            lastSample = nil
        }
        if s != snapshot { snapshot = s }
        if paused != isPaused { isPaused = paused }
    }

    public func pause() { control.pause(); refresh() }
    public func resume() { control.resume(); refresh() }
    public func skipCurrent() { control.skipCurrent() }

    /// Remaining time from the smoothed speed, if it can be estimated.
    public var secondsRemaining: Double? {
        guard speed > 1 else { return nil }
        return Double(max(0, snapshot.totalBytes - snapshot.processedBytes)) / speed
    }

    public var averageSpeed: Double {
        guard let start = snapshot.startedAt else { return 0 }
        let end = snapshot.finishedAt ?? Date()
        let t = end.timeIntervalSince(start)
        return t > 0 ? Double(snapshot.transferredBytes) / t : 0
    }

    public var title: String {
        let first = (sources.first.map { ($0 as NSString).lastPathComponent }) ?? ""
        switch sources.count {
        case 0: return "Nothing"
        case 1: return "“\(first)”"
        default: return "“\(first)” and \(sources.count - 1) more"
        }
    }

    public var destinationName: String { FileManager.default.displayName(atPath: destination) }

    /// Routes prompts to `pendingPrompt` on the main thread and blocks the engine until answered.
    public func useInteractivePrompts(onPrompt: @escaping (Job) -> Void) {
        promptHandler = { [weak self] prompt in
            guard let self else { return PromptResponse(.cancel) }
            let done = DispatchSemaphore(value: 0)
            var response = PromptResponse(.cancel)
            let pending = PendingPrompt(prompt) { r in
                response = r
                done.signal()
            }
            DispatchQueue.main.async {
                self.pendingPrompt = pending
                onPrompt(self)
            }
            while done.wait(timeout: .now() + .milliseconds(250)) == .timedOut {
                if self.control.isCancelled {
                    DispatchQueue.main.async { if self.pendingPrompt === pending { self.pendingPrompt = nil } }
                    return PromptResponse(.cancel)
                }
            }
            DispatchQueue.main.async { if self.pendingPrompt === pending { self.pendingPrompt = nil } }
            return response
        }
    }

    // MARK: Item access (any thread)

    public struct Row {
        public let status: ItemStatus
        public let kind: ItemKind
        /// Path shown in the Name column (relative, starting with the top-level item).
        public let path: String
        public let size: Int64
        public let message: String?
        /// Full source path.
        public let source: String
        /// Full destination path (where it went, or will go).
        public let destination: String
    }

    public var itemCount: Int { lock.lock(); defer { lock.unlock() }; return items.count }

    public func row(_ i: Int) -> Row? {
        lock.lock(); defer { lock.unlock() }
        guard i >= 0, i < items.count else { return nil }
        let it = items[i]
        guard Int(it.root) < roots.count else { return nil }
        let root = roots[Int(it.root)]
        let path = it.rel.isEmpty ? root.destName : root.destName + "/" + it.rel
        let source = it.rel.isEmpty ? root.source : joinPath(root.source, it.rel)
        return Row(status: it.status, kind: it.kind, path: path, size: it.size, message: it.message,
                   source: source, destination: it.destinationOverride ?? defaultDestination(it, root))
    }

    private func defaultDestination(_ it: TransferItem, _ root: TransferRoot) -> String {
        let top = joinPath(destination, root.destName)
        return it.rel.isEmpty ? top : joinPath(top, it.rel)
    }

    /// Where each top-level item ended up (for "Show in Finder").
    public func destinationPaths() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return roots.map { joinPath(destination, $0.destName) }
    }

    /// Items that failed, for the error report.
    public func problemRows() -> [Row] {
        let n = itemCount
        return (0..<n).compactMap { row($0) }.filter { $0.status == .failed }
    }

    public func currentStats() -> JobStats {
        lock.lock(); defer { lock.unlock() }
        return stats
    }

    // MARK: Engine-side mutation (engine thread)

    @discardableResult
    func update<T>(_ body: (inout JobStats) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&stats)
    }

    var rootCount: Int { lock.lock(); defer { lock.unlock() }; return roots.count }

    func addRoot(_ root: TransferRoot) { lock.lock(); roots.append(root); lock.unlock() }

    func root(_ i: Int) -> TransferRoot { lock.lock(); defer { lock.unlock() }; return roots[i] }

    func setRootDestName(_ i: Int, _ name: String) { lock.lock(); roots[i].destName = name; lock.unlock() }

    func item(_ i: Int) -> TransferItem { lock.lock(); defer { lock.unlock() }; return items[i] }

    func addItems(_ new: [TransferItem]) {
        guard !new.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        items.append(contentsOf: new)
        for it in new {
            stats.totalItems += 1
            stats.totalBytes += it.size
            if it.status != .pending { count(it.status, size: it.size, kind: it.kind) }
        }
    }

    func addItem(_ item: TransferItem) { addItems([item]) }

    /// Sum of pending file bytes, split by root, for the free-space check.
    func pendingBytes(where include: (Int32) -> Bool) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        var total: Int64 = 0
        for it in items where it.status == .pending && it.kind == .file && include(it.root) { total += it.size }
        return total
    }

    func beginItem(_ i: Int) {
        lock.lock(); defer { lock.unlock() }
        items[i].status = .active
        let it = items[i]
        let rootName = Int(it.root) < roots.count ? roots[Int(it.root)].destName : ""
        stats.currentPath = it.rel.isEmpty ? rootName : rootName + "/" + it.rel
        stats.currentIndex = i
        stats.currentBytes = 0
        stats.verifying = false
    }

    /// Records where an item is going when that isn't simply the mirrored source path.
    func setTarget(_ i: Int, _ path: String) {
        lock.lock(); defer { lock.unlock() }
        let it = items[i]
        guard Int(it.root) < roots.count else { return }
        items[i].destinationOverride = path == defaultDestination(it, roots[Int(it.root)]) ? nil : path
    }

    func progress(_ n: Int64) {
        guard n != 0 else { return }
        lock.lock()
        stats.currentBytes += n
        stats.transferredBytes += n
        lock.unlock()
    }

    func setVerifying() { lock.lock(); stats.verifying = true; lock.unlock() }

    func resetCurrent() { lock.lock(); stats.currentBytes = 0; lock.unlock() }

    func finishItem(_ i: Int, _ status: ItemStatus, _ message: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        items[i].status = status
        items[i].message = message
        stats.currentBytes = 0
        stats.verifying = false
        count(status, size: items[i].size, kind: items[i].kind)
    }

    /// The job was cancelled while this item was in flight; it goes back to pending.
    func abandonItem(_ i: Int) {
        lock.lock(); defer { lock.unlock() }
        items[i].status = .pending
        stats.currentBytes = 0
        stats.verifying = false
    }

    private func count(_ status: ItemStatus, size: Int64, kind: ItemKind) {
        stats.committedBytes += size
        stats.finishedItems += 1
        switch status {
        case .done: if kind != .directory { stats.copiedItems += 1 }
        case .skipped: stats.skippedItems += 1
        case .failed: stats.failedItems += 1
        case .pending, .active: break
        }
    }
}
