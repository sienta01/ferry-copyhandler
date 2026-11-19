import Darwin
import Foundation
import Testing
@testable import FerryCore

/// A scratch folder per test, removed afterwards.
final class Sandbox {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ferry-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        // Undo read-only folders and locks first so the cleanup can't fail halfway.
        if let e = FileManager.default.enumerator(atPath: root.path) {
            for case let rel as String in e {
                let p = root.appendingPathComponent(rel).path
                chflags(p, 0)
                chmod(p, 0o755)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    func path(_ rel: String) -> String { root.appendingPathComponent(rel).path }

    @discardableResult
    func file(_ rel: String, bytes: Int = 64, seed: UInt8 = 1) throws -> String {
        let p = path(rel)
        try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { buf in
            for i in 0..<bytes { buf[i] = UInt8(truncatingIfNeeded: i &* 31 &+ Int(seed)) }
        }
        try data.write(to: URL(fileURLWithPath: p))
        return p
    }

    func dir(_ rel: String) throws -> String {
        try FileManager.default.createDirectory(atPath: path(rel), withIntermediateDirectories: true)
        return path(rel)
    }

    func read(_ rel: String) -> Data? { FileManager.default.contents(atPath: path(rel)) }
    func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: path(rel)) }

    func leftovers() -> [String] {
        (FileManager.default.subpaths(atPath: root.path) ?? []).filter { ($0 as NSString).lastPathComponent.hasPrefix(".ferry-") }
    }
}

func run(_ kind: TransferKind, _ sources: [String], to dest: String, _ configure: (inout TransferOptions) -> Void = { _ in }) -> JobStats {
    var options = TransferOptions()
    configure(&options)
    let job = Job(kind: kind, sources: sources, destination: dest, options: options)
    job.runSynchronously()
    return job.currentStats()
}

@Test func copiesTreeWithMetadata() throws {
    let box = try Sandbox()
    try box.file("src/a.txt", bytes: 10)
    try box.file("src/sub/deep/b.bin", bytes: 6 << 20) // pipelined path
    try box.file("src/empty", bytes: 0)
    symlink("a.txt", box.path("src/link"))
    setxattr(box.path("src/a.txt"), "com.example.tag", "x", 1, 0, 0)
    chmod(box.path("src/a.txt"), 0o640)
    let dest = try box.dir("dest")

    let s = run(.copy, [box.path("src")], to: dest) { $0.useClones = false }

    #expect(s.phase == .finished(.completed))
    #expect(box.read("dest/src/sub/deep/b.bin") == box.read("src/sub/deep/b.bin"))
    #expect(box.read("dest/src/empty")?.count == 0)
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: box.path("dest/src/link"))) == "a.txt")
    #expect(getxattr(box.path("dest/src/a.txt"), "com.example.tag", nil, 0, 0, 0) == 1)
    #expect(lstatPath(box.path("dest/src/a.txt"))!.st_mode & 0o777 == 0o640)
    #expect(box.leftovers().isEmpty)
}

@Test func collisionPolicies() throws {
    let box = try Sandbox()
    let src = try box.file("src/f.txt", bytes: 5, seed: 1)
    let dest = try box.dir("dest")
    try box.file("dest/f.txt", bytes: 7, seed: 9)

    #expect(run(.copy, [src], to: dest) { $0.collision = .skip }.skippedItems == 1)
    #expect(box.read("dest/f.txt")?.count == 7)

    _ = run(.copy, [src], to: dest) { $0.collision = .keepBoth }
    #expect(box.read("dest/f 2.txt") == box.read("src/f.txt"))

    _ = run(.copy, [src], to: dest) { $0.collision = .overwrite }
    #expect(box.read("dest/f.txt") == box.read("src/f.txt"))
    #expect(box.leftovers().isEmpty)
}

@Test func duplicateInSameFolderGetsCopyName() throws {
    let box = try Sandbox()
    let src = try box.file("here/report.pdf")
    _ = run(.copy, [src], to: box.path("here"))
    _ = run(.copy, [src], to: box.path("here"))
    #expect(box.exists("here/report copy.pdf"))
    #expect(box.exists("here/report copy 2.pdf"))
}

@Test func refusesToCopyFolderIntoItself() throws {
    let box = try Sandbox()
    try box.file("a/inner/x")
    let s = run(.copy, [box.path("a")], to: box.path("a/inner"))
    #expect(s.failedItems == 1)
    #expect(!box.exists("a/inner/a"))
}

@Test func moveMergesAndRemovesSources() throws {
    let box = try Sandbox()
    try box.file("src/keep/one.txt")
    try box.file("src/two.txt")
    try box.file("dest/src/keep/existing.txt")
    let s = run(.move, [box.path("src")], to: box.path("dest"))
    #expect(s.phase == .finished(.completed))
    #expect(box.exists("dest/src/keep/one.txt"))
    #expect(box.exists("dest/src/keep/existing.txt"))
    #expect(box.exists("dest/src/two.txt"))
    #expect(!box.exists("src"))
}

@Test func verifyModeCopiesCorrectly() throws {
    let box = try Sandbox()
    try box.file("src/big.bin", bytes: 9 << 20)
    try box.file("src/small.bin", bytes: 100)
    let s = run(.copy, [box.path("src")], to: try box.dir("dest")) {
        $0.verify = true
        $0.useClones = false
    }
    #expect(s.phase == .finished(.completed))
    #expect(box.read("dest/src/big.bin") == box.read("src/big.bin"))
}

@Test func cancelMidFileLeavesNoPartialFile() throws {
    let box = try Sandbox()
    try box.file("big.bin", bytes: 64 << 20)
    var options = TransferOptions()
    options.useClones = false
    options.bufferSize = 256 << 10
    let job = Job(kind: .copy, sources: [box.path("big.bin")], destination: try box.dir("dest"), options: options)
    job.control.pause()
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        job.runSynchronously()
        done.signal()
    }
    // Let exactly one chunk through, then cancel while the file is half written.
    while job.currentStats().phase != .running { usleep(1000) }
    job.control.resume()
    while job.currentStats().currentBytes == 0 { usleep(100) }
    job.control.cancel()
    done.wait()
    #expect(job.currentStats().phase == .finished(.cancelled))
    #expect(!box.exists("dest/big.bin"))
    #expect(box.leftovers().isEmpty)
}

@Test func promptHandlerDecidesConflicts() throws {
    let box = try Sandbox()
    let src = try box.file("s/a.txt", bytes: 3, seed: 2)
    try box.file("d/a.txt", bytes: 4, seed: 3)
    let job = Job(kind: .copy, sources: [src], destination: box.path("d"), options: TransferOptions())
    var asked = 0
    job.promptHandler = { prompt in
        if case .collision = prompt { asked += 1 }
        return PromptResponse(.replace)
    }
    job.runSynchronously()
    #expect(asked == 1)
    #expect(box.read("d/a.txt") == box.read("s/a.txt"))
}

@Test func rowsShowRealSourceAndDestination() throws {
    let box = try Sandbox()
    try box.file("src/docs/a.txt", seed: 1)
    try box.file("dest/src/docs/a.txt", seed: 2) // forces "Keep both"
    let job = Job(kind: .copy, sources: [box.path("src")], destination: box.path("dest"), options: {
        var o = TransferOptions()
        o.collision = .keepBoth
        return o
    }())
    job.runSynchronously()
    let rows = (0..<job.itemCount).compactMap { job.row($0) }
    let file = try #require(rows.first { $0.path == "src/docs/a.txt" })
    #expect(file.source == box.path("src/docs/a.txt"))
    #expect(file.destination == box.path("dest/src/docs/a 2.txt"))
    #expect(file.message == "Saved as “a 2.txt”.")
    let folder = try #require(rows.first { $0.path == "src/docs" })
    #expect(folder.destination == box.path("dest/src/docs"))
    #expect(job.currentStats().currentIndex == -1)
}

@Test func scanOrderMatchesFinder() throws {
    let box = try Sandbox()
    for name in ["Lecture 10.mkv", "lecture 2.mkv", "Lecture 1.mkv", "B.txt", "a.txt", "Lecture 02b.mkv"] {
        try box.file("src/\(name)")
    }
    let job = Job(kind: .copy, sources: [box.path("src")], destination: try box.dir("dest"), options: TransferOptions())
    job.runSynchronously()
    let names = (1..<job.itemCount).compactMap { job.row($0)?.path }
    #expect(names == ["src/a.txt", "src/B.txt", "src/Lecture 1.mkv", "src/lecture 2.mkv", "src/Lecture 02b.mkv", "src/Lecture 10.mkv"])
}
