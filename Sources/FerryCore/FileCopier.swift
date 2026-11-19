import CryptoKit
import Darwin
import Foundation

enum Flow { case proceed, skip, cancel }

/// Thrown when the user skipped the current file or cancelled the job mid-copy.
struct CopyAborted: Error { let flow: Flow }

/// Copies single files. One instance per running job; its buffers are reused for every
/// file and released when the job ends.
///
/// Strategy per regular file:
///  1. Same APFS volume: `clonefile` (instant, no extra space).
///  2. Small or HFS-compressed files: `copyfile(3)` (lowest per-file overhead, handles decmpfs).
///  3. Everything else: a reader thread and a writer overlap I/O through a small ring of large,
///     page-aligned buffers with `F_NOCACHE`, so a big copy neither serialises read/write nor
///     evicts the rest of the system's file cache. Metadata is copied with `fcopyfile`.
/// The data always lands in a hidden temp file that is renamed over the destination at the end.
final class FileCopier {
    static let smallFileLimit: Int64 = 4 << 20

    private let chunk: Int
    private let bufferCount: Int
    private var buffers: [UnsafeMutableRawPointer] = []
    private let readerQueue = DispatchQueue(label: "ferry.reader", qos: .userInitiated)

    init(bufferSize: Int, bufferCount: Int) {
        chunk = max(256 << 10, bufferSize)
        self.bufferCount = max(2, bufferCount)
    }

    deinit { releaseBuffers() }

    func releaseBuffers() {
        buffers.forEach { free($0) }
        buffers.removeAll()
    }

    private func ensureBuffers() {
        guard buffers.isEmpty else { return }
        for _ in 0..<bufferCount {
            var p: UnsafeMutableRawPointer?
            if posix_memalign(&p, 16384, chunk) != 0 || p == nil { p = malloc(chunk) }
            buffers.append(p!)
        }
    }

    // MARK: Regular files

    /// `replacing`: something already exists at `destination` and gets swapped out atomically.
    /// New small files are written in place, which saves a rename per file (it adds up over
    /// thousands of files). Replacements and large files go through a hidden temp file, so an
    /// interrupted copy never leaves a truncated file under the real name or destroys the old one.
    func copyFile(from src: String, stat st: stat, to destination: String, replacing: Bool, sameDevice: Bool,
                  options: TransferOptions, progress: (Int64) -> Flow, verifying: () -> Void) throws {
        let size = Int64(st.st_size)
        let compressed = st.st_flags & UInt32(UF_COMPRESSED) != 0
        let small = size < Self.smallFileLimit || compressed
        let direct = !replacing && small
        let target = direct ? destination : temporarySibling(of: destination)
        let check = { progress(0) }

        do {
            var cloned = false
            if sameDevice && options.useClones {
                if clonefile(src, target, UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)) == 0 {
                    cloned = true
                } else if errno == EEXIST && direct {
                    throw POSIXFailure("create the copy", code: EEXIST)
                } else if !direct {
                    _ = unlink(target)
                }
            }
            if !cloned {
                if small {
                    try copyWithCopyfile(src, target, size: size, progress: progress)
                    if options.verify {
                        verifying()
                        guard try digest(of: src, check: check) == digest(of: target, check: check) else {
                            throw FerryError("Verification failed: the copy doesn't match the original.")
                        }
                    }
                } else {
                    let sourceDigest = try pipelinedCopy(from: src, to: target, size: size,
                                                         hashing: options.verify, progress: progress)
                    if let sourceDigest {
                        verifying()
                        guard try digest(of: target, check: check) == sourceDigest else {
                            throw FerryError("Verification failed: the copy doesn't match the original.")
                        }
                    }
                }
            }
            try finalize(tmp: target, destination: destination, source: st, restoreCreation: !cloned)
        } catch {
            // Remove what we wrote, but never a file that appeared at the destination meanwhile.
            if !(direct && (error as? POSIXFailure)?.code == EEXIST) { _ = unlink(target) }
            throw error
        }
    }

    func copySymlink(from src: String, to destination: String) throws {
        let tmp = temporarySibling(of: destination)
        defer { _ = unlink(tmp) }
        if copyfile(src, tmp, nil, copyfile_flags_t(CF.all | CF.nofollow | CF.excl)) != 0 {
            _ = unlink(tmp)
            var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let n = readlink(src, &buf, buf.count - 1)
            guard n >= 0 else { throw POSIXFailure("read the link") }
            buf[n] = 0
            guard symlink(buf, tmp) == 0 else { throw POSIXFailure("create the link") }
        }
        guard rename(tmp, destination) == 0 else { throw POSIXFailure("move the link into place") }
    }

    // MARK: copyfile(3) path

    private final class CallbackBox {
        let progress: (Int64) -> Flow
        var reported: Int64 = 0
        var abort: Flow = .proceed
        init(_ progress: @escaping (Int64) -> Flow) { self.progress = progress }
    }

    private func copyWithCopyfile(_ src: String, _ dst: String, size: Int64, progress: (Int64) -> Flow) throws {
        try withoutActuallyEscaping(progress) { progress in
            let box = CallbackBox(progress)
            guard let state = copyfile_state_alloc() else { throw POSIXFailure("copy", code: ENOMEM) }
            defer { copyfile_state_free(state) }

            let callback: copyfile_callback_t = { what, stage, state, _, _, ctx in
                guard let ctx, what == 4 /* COPYFILE_COPY_DATA */, stage == 4 /* COPYFILE_PROGRESS */ else {
                    return 0 // COPYFILE_CONTINUE
                }
                let box = Unmanaged<CallbackBox>.fromOpaque(ctx).takeUnretainedValue()
                var copied: off_t = 0
                copyfile_state_get(state, 8 /* COPYFILE_STATE_COPIED */, &copied)
                let delta = Int64(copied) - box.reported
                box.reported = Int64(copied)
                let flow = box.progress(delta)
                if flow != .proceed {
                    box.abort = flow
                    return 2 // COPYFILE_QUIT
                }
                return 0
            }
            copyfile_state_set(state, CF.stateStatusCB, unsafeBitCast(callback, to: UnsafeRawPointer.self))
            copyfile_state_set(state, CF.stateStatusCtx, Unmanaged.passUnretained(box).toOpaque())

            let rc = copyfile(src, dst, state, copyfile_flags_t(CF.all | CF.nofollowSrc | CF.excl))
            let err = errno
            withExtendedLifetime(box) {}
            if rc != 0 {
                if box.abort != .proceed { throw CopyAborted(flow: box.abort) }
                throw POSIXFailure("copy", code: err)
            }
            if size > box.reported { _ = progress(size - box.reported) }
        }
    }

    // MARK: Pipelined path

    private final class Channel {
        private let lock = NSLock()
        private var chunks: [(index: Int, count: Int)] = []
        private var stop = false

        func push(_ index: Int, _ count: Int) {
            lock.lock(); chunks.append((index, count)); lock.unlock()
        }
        func pop() -> (index: Int, count: Int) {
            lock.lock(); defer { lock.unlock() }
            return chunks.removeFirst()
        }
        var stopped: Bool { lock.lock(); defer { lock.unlock() }; return stop }
        func halt() { lock.lock(); stop = true; lock.unlock() }
    }

    /// Returns the SHA-256 of the source data when `hashing` is on (computed on the reader thread).
    private func pipelinedCopy(from src: String, to tmp: String, size: Int64, hashing: Bool,
                               progress: (Int64) -> Flow) throws -> SHA256.Digest? {
        let sfd = open(src, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard sfd >= 0 else { throw POSIXFailure("open the original") }
        defer { close(sfd) }
        let dfd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard dfd >= 0 else { throw POSIXFailure("create the copy") }
        var dfdOpen = true
        defer { if dfdOpen { close(dfd) } }

        _ = fcntl(sfd, F_NOCACHE, 1)
        _ = fcntl(dfd, F_NOCACHE, 1)
        var store = fstore_t(fst_flags: UInt32(F_ALLOCATEALL), fst_posmode: F_PEOFPOSMODE,
                             fst_offset: 0, fst_length: off_t(size), fst_bytesalloc: 0)
        if fcntl(dfd, F_PREALLOCATE, &store) != 0 && errno == ENOSPC {
            throw POSIXFailure("reserve space", code: ENOSPC)
        }

        ensureBuffers()
        let bufs = buffers
        let chunk = self.chunk
        let channel = Channel()
        // Semaphores start at 0 and are signalled up: libdispatch traps if one is freed below its initial value.
        let free = DispatchSemaphore(value: 0)
        for _ in bufs { free.signal() }
        let filled = DispatchSemaphore(value: 0)
        let readerDone = DispatchSemaphore(value: 0)
        var hasher: SHA256? = hashing ? SHA256() : nil

        readerQueue.async {
            var idx = 0
            while true {
                free.wait()
                if channel.stopped { break }
                let p = bufs[idx]
                var got = 0
                var err: Int32 = 0
                while got < chunk {
                    let n = read(sfd, p + got, chunk - got)
                    if n > 0 { got += n } else if n == 0 { break } else if errno == EINTR { continue } else { err = errno; break }
                }
                if err != 0 { channel.push(idx, -Int(err)); filled.signal(); break }
                if got > 0 {
                    hasher?.update(bufferPointer: UnsafeRawBufferPointer(start: p, count: got))
                    channel.push(idx, got); filled.signal()
                }
                if got < chunk { channel.push(-1, 0); filled.signal(); break } // EOF
                idx = (idx + 1) % bufs.count
            }
            readerDone.signal()
        }

        var failure: Error?
        writing: while true {
            filled.wait()
            let (idx, count) = channel.pop()
            if count < 0 { failure = POSIXFailure("read the original", code: Int32(-count)); break }
            if count == 0 { break }
            let p = bufs[idx]
            var off = 0
            while off < count {
                let w = write(dfd, p + off, count - off)
                if w > 0 { off += w } else if w < 0 && errno == EINTR { continue } else {
                    failure = POSIXFailure("write the copy", code: w < 0 ? errno : EIO)
                    break writing
                }
            }
            let flow = progress(Int64(count))
            if flow != .proceed { failure = CopyAborted(flow: flow); break }
            free.signal()
        }
        if failure != nil {
            channel.halt()
            free.signal() // wake the reader if it's waiting for a buffer
        }
        readerDone.wait()
        if let failure { throw failure }

        // Permissions, flags, ACLs, extended attributes (tags, quarantine, resource forks), dates.
        _ = fcopyfile(sfd, dfd, nil, copyfile_flags_t(CF.metadata))
        dfdOpen = false
        if close(dfd) != 0 { throw POSIXFailure("finish writing the copy") }
        return hasher?.finalize()
    }

    // MARK: Verification

    private func digest(of path: String, check: () -> Flow) throws -> SHA256.Digest {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXFailure("open for verification") }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        ensureBuffers()
        let p = buffers[0]
        var h = SHA256()
        while true {
            let n = read(fd, p, chunk)
            if n > 0 {
                h.update(bufferPointer: UnsafeRawBufferPointer(start: p, count: n))
            } else if n == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                throw POSIXFailure("read for verification")
            }
            let flow = check()
            if flow != .proceed { throw CopyAborted(flow: flow) }
        }
        return h.finalize()
    }

    // MARK: Finishing

    private func finalize(tmp: String, destination: String, source st: stat, restoreCreation: Bool) throws {
        guard let t = lstatPath(tmp) else { throw POSIXFailure("finish the copy") }
        // A locked (uchg) file can't be renamed, so unlock the temp file and re-lock after.
        let lockBits = UInt32(UF_IMMUTABLE | UF_APPEND)
        let locked = t.st_flags & lockBits
        if locked != 0 { _ = lchflags(tmp, t.st_flags & ~lockBits) }
        // copyfile(3) doesn't carry the creation date over; Finder does, so we do too.
        if restoreCreation { setTimes(tmp, birth: st.st_birthtimespec, modified: nil, accessed: nil) }
        if tmp != destination && rename(tmp, destination) != 0 {
            throw POSIXFailure("move the copy into place")
        }
        if locked != 0 { _ = lchflags(destination, t.st_flags) }
    }
}
