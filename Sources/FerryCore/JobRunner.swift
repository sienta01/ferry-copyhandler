import Darwin
import Foundation

/// Executes one job on the calling thread: plan → (space check) → transfer → folder metadata.
final class JobRunner {
    private let job: Job
    private let ctl: JobControl
    private let options: TransferOptions
    private var collision: CollisionPolicy
    private var errorPolicy: ErrorPolicy
    private let copier: FileCopier
    private let destDir: String
    private var destDev: dev_t = 0
    private var rootOnSameDevice: [Bool] = []

    /// Folders we created; their permissions and dates are applied after their contents are written.
    private var createdDirs: [(src: String, dst: String, st: stat)] = []
    /// Source folders to remove at the end of a move (only if they ended up empty).
    private var sourceDirsToRemove: [String] = []

    /// How a folder's contents are handled: copied into `normal(dest)`, skipped, or already
    /// carried along by a single rename of the folder to `handled(dest)`.
    private enum Subtree { case normal(String), skipped, handled(String) }
    private struct Frame { let root: Int32; let prefix: String; let mode: Subtree }
    private enum Resolution { case replace, rename(String), skip, cancel }
    private enum ErrorChoice { case retry, skip, cancel }

    init(job: Job) {
        self.job = job
        ctl = job.control
        options = job.options
        collision = options.collision
        errorPolicy = options.errors
        copier = FileCopier(bufferSize: options.bufferSize, bufferCount: options.bufferCount)
        destDir = job.destination
    }

    func run() {
        job.update { $0.startedAt = Date(); $0.phase = .scanning }
        var outcome: FinishState
        do {
            try plan()
            if !ctl.isCancelled { checkSpace() }
            if !ctl.isCancelled {
                job.update { $0.phase = .running }
                transferAll()
            }
            finishDirectories()
            if ctl.isCancelled {
                outcome = .cancelled
            } else {
                outcome = job.update { $0.failedItems } > 0 ? .completedWithIssues : .completed
            }
        } catch {
            outcome = .failed(describe(error))
        }
        copier.releaseBuffers()
        job.update {
            $0.phase = .finished(outcome)
            $0.finishedAt = Date()
            $0.currentPath = ""
            $0.currentIndex = -1
            $0.currentBytes = 0
            $0.verifying = false
        }
    }

    // MARK: Planning

    private func plan() throws {
        guard let dst = statPath(destDir), itemKind(dst) == .directory else {
            throw FerryError("The destination “\(lastComponent(destDir))” isn't an available folder.")
        }
        destDev = dst.st_dev
        let destReal = realPath(destDir)

        for src in job.sources {
            if ctl.isCancelled { return }
            let r = Int32(job.rootCount)
            let name = lastComponent(src)
            job.addRoot(TransferRoot(source: src, destName: name))
            rootOnSameDevice.append(false)

            guard let st = lstatPath(src) else {
                job.addItem(TransferItem(root: r, rel: "", size: 0, kind: .file, status: .failed,
                                         message: POSIXFailure("read it").description))
                continue
            }
            let kind = itemKind(st)
            rootOnSameDevice[Int(r)] = st.st_dev == destDev
            let size = kind == .file ? Int64(st.st_size) : 0

            if kind == .directory {
                let srcReal = realPath(src)
                if destReal == srcReal || destReal.hasPrefix(srcReal + "/") {
                    job.addItem(TransferItem(root: r, rel: "", size: 0, kind: kind, status: .failed,
                                             message: "A folder can't be \(job.kind == .copy ? "copied" : "moved") into itself."))
                    continue
                }
            }

            // Pasting into the folder the item already lives in: Finder makes "Name copy".
            if let parent = statPath(parentPath(src)), parent.st_dev == dst.st_dev, parent.st_ino == dst.st_ino {
                if job.kind == .move {
                    job.addItem(TransferItem(root: r, rel: "", size: size, kind: kind, status: .skipped,
                                             message: "It's already in this folder."))
                    continue
                }
                job.setRootDestName(Int(r), uniqueName(in: destDir, for: name, style: .copy))
            }

            // Same-volume move to a free name: one rename, no need to look inside.
            let target = joinPath(destDir, job.root(Int(r)).destName)
            if job.kind == .move && st.st_dev == destDev && lstatPath(target) == nil && rename(src, target) == 0 {
                job.addItem(TransferItem(root: r, rel: "", size: size, kind: kind, status: .done))
                continue
            }

            if kind == .directory {
                scan(root: r, path: src)
            } else {
                job.addItem(TransferItem(root: r, rel: "", size: size, kind: kind))
            }
        }
    }

    /// Flattens a folder into the item list (pre-order: folders before their contents).
    private func scan(root: Int32, path: String) {
        guard let cPath = strdup(path) else { return }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR, finderOrder) else {
            job.addItem(TransferItem(root: root, rel: "", size: 0, kind: .directory, status: .failed,
                                     message: POSIXFailure("read the folder").description))
            return
        }
        defer { fts_close(fts) }

        let prefixLength = path.utf8.count + (path == "/" ? 0 : 1)
        // File systems without native extended attributes (SMB shares without streams, FAT, exFAT,
        // NFS…) keep each file's metadata in a hidden "._name" companion. Copying "name" already
        // carries that metadata over as real attributes, so, like Finder, skip the companion rather
        // than leave a stray "._" file at the destination.
        let skipAppleDouble = !hasNativeExtendedAttributes(path)
        var batch: [TransferItem] = []
        batch.reserveCapacity(1024)

        while let entry = fts_read(fts) {
            let e = entry.pointee
            let info = Int32(e.fts_info)
            if info == FTS_DP || info == FTS_DC { continue }
            let rel = e.fts_level == 0 ? "" : String(cString: e.fts_path + prefixLength)
            var item = TransferItem(root: root, rel: rel, size: 0, kind: .file)
            switch info {
            case FTS_D:
                item.kind = .directory
            case FTS_F:
                if skipAppleDouble && isAppleDoubleCompanion(entry) { continue }
                item.size = Int64(e.fts_statp.pointee.st_size)
            case FTS_SL, FTS_SLNONE:
                item.kind = .symlink
            case FTS_DNR:
                // Reported after the folder's own FTS_D entry: the folder is created, its contents can't be read.
                item.kind = .special
                item.status = .failed
                item.message = "Couldn't read the folder's contents: " + POSIXFailure("read", code: e.fts_errno).description
            case FTS_ERR, FTS_NS:
                item.status = .failed
                item.message = POSIXFailure("read it", code: e.fts_errno).description
            default:
                item.kind = .special
            }
            batch.append(item)
            if batch.count >= 1024 {
                job.addItems(batch)
                batch.removeAll(keepingCapacity: true)
                if ctl.isCancelled { return }
            }
        }
        job.addItems(batch)
    }

    private func checkSpace() {
        let needed = job.pendingBytes { root in
            // Same-volume moves are renames and same-volume copies are clones: no new space.
            let same = Int(root) < self.rootOnSameDevice.count && self.rootOnSameDevice[Int(root)]
            return !(same && (self.job.kind == .move || self.options.useClones))
        }
        guard needed > 0 else { return }
        let available = availableSpace(at: destDir)
        if needed > available {
            let r = ask(.lowSpace(needed: needed, available: available))
            if r.answer != .proceed { ctl.cancel() }
        }
    }

    // MARK: Transfer

    private func transferAll() {
        var stack: [Frame] = []
        let count = job.itemCount
        for i in 0..<count {
            if ctl.checkpoint() == .cancel { return }
            let it = job.item(i)
            if it.status != .pending { continue }
            let root = job.root(Int(it.root))
            let src = it.rel.isEmpty ? root.source : joinPath(root.source, it.rel)

            let parentDest: String
            let name: String
            if it.rel.isEmpty {
                stack.removeAll()
                parentDest = destDir
                name = root.destName
            } else {
                while let top = stack.last, !(top.root == it.root && it.rel.hasPrefix(top.prefix)) {
                    stack.removeLast()
                }
                guard let top = stack.last else {
                    job.finishItem(i, .failed, "Its folder couldn't be created.")
                    continue
                }
                name = lastComponent(it.rel)
                switch top.mode {
                case .skipped:
                    job.finishItem(i, .skipped, "Its folder was skipped.")
                    if it.kind == .directory { stack.append(Frame(root: it.root, prefix: it.rel + "/", mode: .skipped)) }
                    continue
                case .handled(let dir):
                    let moved = joinPath(dir, name)
                    job.setTarget(i, moved)
                    job.finishItem(i, .done)
                    if it.kind == .directory { stack.append(Frame(root: it.root, prefix: it.rel + "/", mode: .handled(moved))) }
                    continue
                case .normal(let dir):
                    parentDest = dir
                }
            }

            let target = joinPath(parentDest, name)
            if it.kind == .directory {
                let mode = processDirectory(i, src: src, dst: target)
                stack.append(Frame(root: it.root, prefix: it.rel.isEmpty ? "" : it.rel + "/", mode: mode))
            } else {
                processFile(i, item: it, src: src, dst: target)
            }
            if ctl.isCancelled { return }
        }
    }

    private func processDirectory(_ i: Int, src: String, dst: String) -> Subtree {
        job.beginItem(i)
        guard let sst = lstatPath(src) else {
            job.finishItem(i, .failed, POSIXFailure("read the folder").description)
            return .skipped
        }
        var target = dst
        if let existing = lstatPath(dst) {
            if itemKind(existing) == .directory {
                // Merge into the existing folder, like Ultracopier and TeraCopy do.
                if job.kind == .move { sourceDirsToRemove.append(src) }
                job.setTarget(i, dst)
                job.finishItem(i, .done)
                return .normal(dst)
            }
            switch resolveCollision(src: src, srcStat: sst, dst: dst, dstStat: existing) {
            case .skip:
                job.finishItem(i, .skipped, "An item with the same name already exists.")
                return .skipped
            case .cancel:
                job.abandonItem(i)
                return .skipped
            case .rename(let t):
                target = t
            case .replace:
                if unlink(dst) != 0 {
                    job.finishItem(i, .failed, POSIXFailure("replace the existing file").description)
                    return .skipped
                }
            }
        }

        job.setTarget(i, target)
        // Same-volume move: one rename carries the whole subtree.
        if job.kind == .move && sst.st_dev == destDev && rename(src, target) == 0 {
            job.finishItem(i, .done)
            return .handled(target)
        }

        while mkdir(target, 0o700) != 0 {
            let err = errno
            if err == EEXIST, let e = lstatPath(target), itemKind(e) == .directory { break }
            let failure = POSIXFailure("create the folder", code: err)
            switch handleError(path: src, error: failure) {
            case .retry: continue
            case .skip:
                job.finishItem(i, .failed, failure.description)
                return .skipped
            case .cancel:
                job.abandonItem(i)
                return .skipped
            }
        }
        createdDirs.append((src, target, sst))
        if job.kind == .move { sourceDirsToRemove.append(src) }
        job.finishItem(i, .done)
        return .normal(target)
    }

    private func processFile(_ i: Int, item: TransferItem, src: String, dst: String) {
        job.beginItem(i)
        ctl.clearSkip()
        if item.kind == .special {
            job.finishItem(i, .skipped, "Pipes, sockets and device files aren't copied.")
            return
        }

        var sourceStat: stat?
        while sourceStat == nil {
            if let s = lstatPath(src) { sourceStat = s; break }
            let failure = POSIXFailure("read it")
            switch handleError(path: src, error: failure) {
            case .retry: continue
            case .skip: job.finishItem(i, .failed, failure.description); return
            case .cancel: job.abandonItem(i); return
            }
        }
        guard let sst = sourceStat else { return }

        var target = dst
        var replacing = false
        if let existing = lstatPath(dst) {
            if existing.st_dev == sst.st_dev && existing.st_ino == sst.st_ino {
                if job.kind == .move {
                    job.finishItem(i, .skipped, "It's already there.")
                    return
                }
                let dir = parentPath(dst)
                target = joinPath(dir, uniqueName(in: dir, for: lastComponent(dst), style: .copy))
            } else {
                switch resolveCollision(src: src, srcStat: sst, dst: dst, dstStat: existing) {
                case .skip:
                    job.finishItem(i, .skipped, "An item with the same name already exists.")
                    return
                case .cancel:
                    job.abandonItem(i)
                    return
                case .rename(let t):
                    target = t
                case .replace:
                    if itemKind(existing) == .directory {
                        job.finishItem(i, .failed, "A folder with the same name is in the way (folders aren't replaced by files).")
                        return
                    }
                    replacing = true
                }
            }
        }

        job.setTarget(i, target)
        let renamed = lastComponent(target) != lastComponent(dst) ? "Saved as “\(lastComponent(target))”." : nil
        while true {
            do {
                let warning = try transfer(src: src, stat: sst, kind: item.kind, to: target, replacing: replacing)
                job.finishItem(i, warning == nil ? .done : .failed, warning ?? renamed)
                return
            } catch let abort as CopyAborted {
                if abort.flow == .skip {
                    job.finishItem(i, .skipped, "Skipped.")
                } else {
                    job.abandonItem(i)
                }
                return
            } catch {
                job.resetCurrent()
                switch handleError(path: src, error: error) {
                case .retry: continue
                case .skip: job.finishItem(i, .failed, describe(error)); return
                case .cancel: job.abandonItem(i); return
                }
            }
        }
    }

    /// Returns a note when the data arrived but a move couldn't remove the original.
    private func transfer(src: String, stat sst: stat, kind: ItemKind, to target: String, replacing: Bool) throws -> String? {
        let sameDevice = sst.st_dev == destDev
        if job.kind == .move && sameDevice {
            if rename(src, target) == 0 { return nil }
            if errno != EXDEV { throw POSIXFailure("move it") }
        }
        if kind == .symlink {
            try copier.copySymlink(from: src, to: target)
        } else {
            let job = self.job, ctl = self.ctl
            try copier.copyFile(from: src, stat: sst, to: target, replacing: replacing, sameDevice: sameDevice, options: options,
                                progress: { n in
                                    job.progress(n)
                                    return ctl.checkpoint()
                                },
                                verifying: { job.setVerifying() })
        }
        if job.kind == .move && unlink(src) != 0 {
            if sst.st_flags & UInt32(UF_IMMUTABLE) != 0 {
                return "Copied, but the original is locked, so it was left in place."
            }
            return "Copied, but the original couldn't be removed: \(String(cString: strerror(errno)))."
        }
        return nil
    }

    // MARK: Decisions

    private func resolveCollision(src: String, srcStat: stat, dst: String, dstStat: stat) -> Resolution {
        var policy = collision
        if policy == .ask {
            let info = CollisionInfo(
                source: src, destination: dst,
                sourceSize: Int64(srcStat.st_size), destinationSize: Int64(dstStat.st_size),
                sourceDate: date(srcStat.st_mtimespec), destinationDate: date(dstStat.st_mtimespec),
                sourceIsDirectory: itemKind(srcStat) == .directory,
                destinationIsDirectory: itemKind(dstStat) == .directory)
            let r = ask(.collision(info))
            switch r.answer {
            case .replace: policy = .overwrite
            case .replaceIfNewer: policy = .overwriteIfNewer
            case .keepBoth: policy = .keepBoth
            case .cancel:
                ctl.cancel()
                return .cancel
            default: policy = .skip
            }
            if r.applyToAll { collision = policy }
        }
        switch policy {
        case .overwrite:
            return .replace
        case .overwriteIfNewer:
            let s = srcStat.st_mtimespec, d = dstStat.st_mtimespec
            let newer = s.tv_sec > d.tv_sec || (s.tv_sec == d.tv_sec && s.tv_nsec > d.tv_nsec)
            return newer ? .replace : .skip
        case .keepBoth:
            let dir = parentPath(dst)
            return .rename(joinPath(dir, uniqueName(in: dir, for: lastComponent(dst), style: .number)))
        case .skip, .ask:
            return .skip
        }
    }

    private func handleError(path: String, error: Error) -> ErrorChoice {
        if ctl.isCancelled { return .cancel }
        if errorPolicy == .skip { return .skip }
        let r = ask(.error(path: path, message: describe(error)))
        switch r.answer {
        case .retry:
            return .retry
        case .cancel:
            ctl.cancel()
            return .cancel
        default:
            if r.applyToAll { errorPolicy = .skip }
            return .skip
        }
    }

    private func ask(_ prompt: Prompt) -> PromptResponse {
        guard let handler = job.promptHandler else {
            switch prompt {
            case .collision, .error: return PromptResponse(.skip)
            case .lowSpace: return PromptResponse(.proceed)
            }
        }
        job.update { $0.waitingForAnswer = true }
        defer { job.update { $0.waitingForAnswer = false } }
        return handler(prompt)
    }

    // MARK: Wrap-up

    private func finishDirectories() {
        // Deepest first, so writing into a folder never disturbs an already-finished parent.
        for d in createdDirs.reversed() {
            _ = copyfile(d.src, d.dst, nil, copyfile_flags_t(CF.metadata | CF.nofollow))
            setTimes(d.dst, birth: d.st.st_birthtimespec, modified: d.st.st_mtimespec, accessed: d.st.st_atimespec)
        }
        guard job.kind == .move else { return }
        for dir in sourceDirsToRemove.reversed() where rmdir(dir) != 0 && errno == ENOTEMPTY {
            // Finder may have dropped a fresh .DS_Store in while we worked, and "._" metadata files
            // can outlive their (moved) file; neither alone should keep the folder.
            guard let left = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            let leftovers = left.allSatisfy { name in
                name == ".DS_Store"
                    || (name.hasPrefix("._") && lstatPath(joinPath(dir, String(name.dropFirst(2)))) == nil)
            }
            if leftovers {
                left.forEach { _ = unlink(joinPath(dir, $0)) }
                _ = rmdir(dir)
            }
        }
    }

    private func realPath(_ p: String) -> String {
        guard let r = realpath(p, nil) else { return p }
        defer { free(r) }
        return String(cString: r)
    }
}

// MARK: - AppleDouble ("._") companions

/// APFS and HFS+ store extended attributes natively; anything else may use "._" files.
func hasNativeExtendedAttributes(_ path: String) -> Bool {
    var fs = statfs()
    guard statfs(path, &fs) == 0 else { return true }
    let type = withUnsafeBytes(of: fs.f_fstypename) { raw in
        String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
    }
    return type == "apfs" || type == "hfs"
}

/// "._name" sitting next to "name".
private func isAppleDoubleCompanion(_ entry: UnsafeMutablePointer<FTSENT>) -> Bool {
    let e = entry.pointee
    guard e.fts_namelen > 2 else { return false }
    let name = (UnsafeRawPointer(entry) + ftsNameOffset).assumingMemoryBound(to: UInt8.self)
    guard name[0] == UInt8(ascii: "."), name[1] == UInt8(ascii: "_") else { return false }
    let path = String(cString: e.fts_path)
    let companion = joinPath(parentPath(path), String(lastComponent(path).dropFirst(2)))
    return lstatPath(companion) != nil
}

// MARK: - Finder-like ordering for the scan

private let ftsNameOffset = MemoryLayout<FTSENT>.offset(of: \FTSENT.fts_name)!

/// fts comparator: case-insensitive with numbers compared by value ("Lecture 2" before
/// "Lecture 10"), so files are copied, and listed, in the order Finder shows them.
private let finderOrder: @convention(c) (UnsafeMutablePointer<UnsafePointer<FTSENT>?>?,
                                         UnsafeMutablePointer<UnsafePointer<FTSENT>?>?) -> Int32 = { a, b in
    guard let ea = a?.pointee, let eb = b?.pointee else { return 0 }
    let na = (UnsafeRawPointer(ea) + ftsNameOffset).assumingMemoryBound(to: UInt8.self)
    let nb = (UnsafeRawPointer(eb) + ftsNameOffset).assumingMemoryBound(to: UInt8.self)
    return naturalCompare(na, Int(ea.pointee.fts_namelen), nb, Int(eb.pointee.fts_namelen))
}

func naturalCompare(_ a: UnsafePointer<UInt8>, _ la: Int, _ b: UnsafePointer<UInt8>, _ lb: Int) -> Int32 {
    @inline(__always) func digit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
    @inline(__always) func lower(_ c: UInt8) -> UInt8 { c >= 65 && c <= 90 ? c + 32 : c }
    var i = 0, j = 0
    while i < la && j < lb {
        if digit(a[i]) && digit(b[j]) {
            var si = i, sj = j
            while si < la && a[si] == 48 { si += 1 }
            while sj < lb && b[sj] == 48 { sj += 1 }
            var ei = si, ej = sj
            while ei < la && digit(a[ei]) { ei += 1 }
            while ej < lb && digit(b[ej]) { ej += 1 }
            if ei - si != ej - sj { return ei - si < ej - sj ? -1 : 1 }
            for k in 0..<(ei - si) where a[si + k] != b[sj + k] { return a[si + k] < b[sj + k] ? -1 : 1 }
            i = ei
            j = ej
            continue
        }
        let ca = lower(a[i]), cb = lower(b[j])
        if ca != cb { return ca < cb ? -1 : 1 }
        i += 1
        j += 1
    }
    if i < la { return 1 }
    if j < lb { return -1 }
    return 0
}
