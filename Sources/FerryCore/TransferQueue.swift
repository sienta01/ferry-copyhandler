import Combine
import Foundation

/// Ordered list of jobs. Runs one at a time (parallel copies to the same disk are slower,
/// not faster); a queued job can be started early with `startNow`.
public final class TransferQueue: ObservableObject {
    @Published public private(set) var jobs: [Job] = []

    /// Called on the main thread just before a job's thread starts.
    public var jobWillStart: ((Job) -> Void)?
    /// Called on the main thread after a job ends (completed, cancelled or failed).
    public var jobDidFinish: ((Job) -> Void)?

    public init() {}

    @discardableResult
    public func add(_ kind: TransferKind, sources: [String], destination: String, options: TransferOptions) -> Job {
        let job = Job(kind: kind, sources: sources, destination: destination, options: options)
        jobs.append(job)
        pump()
        return job
    }

    public var activeJobs: [Job] { jobs.filter { $0.isStarted && !$0.isDone } }
    public var waitingJobs: [Job] { jobs.filter { !$0.isStarted && !$0.isDone } }
    public var hasUnfinishedJobs: Bool { jobs.contains { !$0.isDone } }
    public var hasFinishedJobs: Bool { jobs.contains { $0.isDone } }

    public func startNow(_ job: Job) {
        guard !job.isStarted, !job.isDone else { return }
        start(job)
    }

    public func cancel(_ job: Job) {
        if job.isStarted {
            job.control.cancel()
        } else if !job.isDone {
            job.markCancelledBeforeStart()
            jobDidFinish?(job)
            objectWillChange.send()
        }
    }

    public func remove(_ job: Job) {
        cancel(job)
        jobs.removeAll { $0 === job }
        pump()
    }

    public func clearFinished() { jobs.removeAll { $0.isDone } }

    public func pauseAll() { activeJobs.forEach { $0.pause() } }
    public func resumeAll() { activeJobs.forEach { $0.resume() } }
    public func cancelAll() { jobs.filter { !$0.isDone }.forEach(cancel) }

    /// Combined progress of unfinished jobs, for the menu bar.
    public var overallFraction: Double {
        let active = jobs.filter { !$0.isDone }
        let total = active.reduce(Int64(0)) { $0 + $1.snapshot.totalBytes }
        guard total > 0 else { return active.first?.snapshot.fraction ?? 0 }
        let done = active.reduce(Int64(0)) { $0 + $1.snapshot.processedBytes }
        return min(1, Double(done) / Double(total))
    }

    public var overallSpeed: Double { activeJobs.reduce(0) { $0 + $1.speed } }

    /// Refreshes every running job and tells observers of the queue (overall progress) to update.
    public func refreshProgress(notify: Bool) {
        for job in jobs where job.isStarted && !job.isDone { job.refresh() }
        if notify { objectWillChange.send() }
    }

    private func pump() {
        guard activeJobs.isEmpty, let next = waitingJobs.first else { return }
        start(next)
    }

    private func start(_ job: Job) {
        jobWillStart?(job)
        job.start { [weak self, weak job] in
            guard let self, let job else { return }
            self.jobDidFinish?(job)
            self.objectWillChange.send()
            self.pump()
        }
        objectWillChange.send()
    }
}
