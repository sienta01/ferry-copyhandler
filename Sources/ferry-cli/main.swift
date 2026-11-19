import Darwin
import FerryCore
import Foundation

let usage = """
usage: ferry-cli copy|move [options] SOURCE... DESTINATION_FOLDER

options:
  --on-conflict skip|replace|newer|keep-both   (default: skip)
  --verify                                     re-read copies and compare SHA-256
  --no-clone                                   always copy data, even on the same APFS volume
  --quiet                                      no progress line

Runs the same engine as Ferry.app, without the app.
"""

var args = Array(CommandLine.arguments.dropFirst())
guard let verb = args.first, let kind = TransferKind(rawValue: verb) else {
    FileHandle.standardError.write(usage.data(using: .utf8)!)
    exit(64)
}
args.removeFirst()

var options = TransferOptions()
options.collision = .skip
options.errors = .skip
var quiet = false
var paths: [String] = []

var it = args.makeIterator()
while let a = it.next() {
    switch a {
    case "--verify": options.verify = true
    case "--no-clone": options.useClones = false
    case "--quiet": quiet = true
    case "--on-conflict":
        switch it.next() {
        case "skip": options.collision = .skip
        case "replace": options.collision = .overwrite
        case "newer": options.collision = .overwriteIfNewer
        case "keep-both": options.collision = .keepBoth
        default:
            FileHandle.standardError.write("--on-conflict needs skip, replace, newer or keep-both\n".data(using: .utf8)!)
            exit(64)
        }
    default: paths.append(a)
    }
}
guard paths.count >= 2 else {
    FileHandle.standardError.write(usage.data(using: .utf8)!)
    exit(64)
}

let cwd = FileManager.default.currentDirectoryPath
func absolute(_ p: String) -> String {
    p.hasPrefix("/") ? p : (cwd as NSString).appendingPathComponent(p)
}
let destination = absolute(paths.removeLast())
let job = Job(kind: kind, sources: paths.map(absolute), destination: destination, options: options)

signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler { job.control.cancel() }
sigint.resume()

let done = DispatchSemaphore(value: 0)
Thread.detachNewThread {
    job.runSynchronously()
    done.signal()
}

let showProgress = !quiet && isatty(STDERR_FILENO) != 0
var lastBytes: Int64 = 0
var lastTime = Date()
while done.wait(timeout: .now() + .milliseconds(500)) == .timedOut {
    guard showProgress else { continue }
    let s = job.currentStats()
    let now = Date()
    let speed = Double(s.transferredBytes - lastBytes) / now.timeIntervalSince(lastTime)
    lastBytes = s.transferredBytes
    lastTime = now
    let line: String
    if s.phase == .scanning {
        line = "Scanning… \(Fmt.count(s.totalItems)) items, \(Fmt.bytes(s.totalBytes))"
    } else {
        line = String(format: "%3.0f%%  ", s.fraction * 100)
            + "\(Fmt.bytes(s.processedBytes)) of \(Fmt.bytes(s.totalBytes))  \(Fmt.speed(speed))  \(s.currentPath)"
    }
    FileHandle.standardError.write(("\r\u{1B}[K" + String(line.prefix(160))).data(using: .utf8)!)
}

let s = job.currentStats()
if showProgress { FileHandle.standardError.write("\r\u{1B}[K".data(using: .utf8)!) }
let elapsed = (s.finishedAt ?? Date()).timeIntervalSince(s.startedAt ?? Date())
let rate = elapsed > 0 ? Double(s.transferredBytes) / elapsed : 0
print("\(kind.past) \(Fmt.count(s.copiedItems)) items (\(Fmt.bytes(s.totalBytes))) in \(Fmt.duration(elapsed)), \(Fmt.speed(rate)) average. Skipped \(s.skippedItems), failed \(s.failedItems).")
for row in job.problemRows() {
    print("  ✗ \(row.path): \(row.message ?? "failed")")
}
switch s.phase {
case .finished(.completed): exit(0)
case .finished(.completedWithIssues): exit(1)
case .finished(.failed(let message)):
    FileHandle.standardError.write("ferry-cli: \(message)\n".data(using: .utf8)!)
    exit(2)
default: exit(130)
}
