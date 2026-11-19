import Darwin
import Foundation

// copyfile(3) constants, spelled out because the composite macros don't all import into Swift.
enum CF {
    static let acl: UInt32 = 1 << 0
    static let stat: UInt32 = 1 << 1
    static let xattr: UInt32 = 1 << 2
    static let data: UInt32 = 1 << 3
    static let metadata: UInt32 = acl | stat | xattr
    static let all: UInt32 = metadata | data
    static let excl: UInt32 = 1 << 17
    static let nofollowSrc: UInt32 = 1 << 18
    static let nofollowDst: UInt32 = 1 << 19
    static let nofollow: UInt32 = nofollowSrc | nofollowDst

    static let stateStatusCB: UInt32 = 6
    static let stateStatusCtx: UInt32 = 7
    static let stateCopied: UInt32 = 8

    static let whatCopyData: Int32 = 4
    static let stageProgress: Int32 = 4
    static let cont: Int32 = 0
    static let quit: Int32 = 2
}

public struct FerryError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

struct POSIXFailure: Error, CustomStringConvertible {
    let code: Int32
    let operation: String

    init(_ operation: String, code: Int32 = errno) {
        self.code = code
        self.operation = operation
    }

    var description: String {
        let reason = String(cString: strerror(code))
        switch code {
        case ENOSPC: return "The destination disk is full."
        case EACCES, EPERM: return "\(reason) (while trying to \(operation))."
        case EFBIG: return "The file is too large for the destination disk's format (FAT32 limits files to 4 GB)."
        case ENAMETOOLONG: return "The name is too long for the destination disk."
        default: return "\(reason) (\(operation))."
        }
    }
}

func describe(_ error: Error) -> String {
    if let e = error as? POSIXFailure { return e.description }
    if let e = error as? FerryError { return e.message }
    return error.localizedDescription
}

@inline(__always)
func lstatPath(_ path: String) -> stat? {
    var st = stat()
    return lstat(path, &st) == 0 ? st : nil
}

@inline(__always)
func statPath(_ path: String) -> stat? {
    var st = stat()
    return stat(path, &st) == 0 ? st : nil
}

func itemKind(_ st: stat) -> ItemKind {
    switch st.st_mode & S_IFMT {
    case S_IFDIR: return .directory
    case S_IFREG: return .file
    case S_IFLNK: return .symlink
    default: return .special
    }
}

@inline(__always)
func joinPath(_ dir: String, _ name: String) -> String {
    dir == "/" ? "/" + name : dir + "/" + name
}

@inline(__always)
func lastComponent(_ path: String) -> String {
    (path as NSString).lastPathComponent
}

@inline(__always)
func parentPath(_ path: String) -> String {
    (path as NSString).deletingLastPathComponent
}

func date(_ ts: timespec) -> Date {
    Date(timeIntervalSince1970: TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1e9)
}

func randomHex(_ bytes: Int) -> String {
    (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
}

/// Name for a temporary file next to `destination`; renamed into place once complete,
/// so a half-written file never appears under the real name.
func temporarySibling(of destination: String) -> String {
    joinPath(parentPath(destination), ".ferry-\(randomHex(6)).part")
}

enum UniqueStyle { case copy, number }

/// Finder-style free name: "Report copy.pdf", "Report copy 2.pdf" or "Report 2.pdf".
func uniqueName(in dir: String, for name: String, style: UniqueStyle) -> String {
    let ns = name as NSString
    let ext = ns.pathExtension
    let base = ext.isEmpty ? name : ns.deletingPathExtension
    var n = 1
    while true {
        let stem: String
        switch style {
        case .copy: stem = n == 1 ? "\(base) copy" : "\(base) copy \(n)"
        case .number: stem = "\(base) \(n + 1)"
        }
        let candidate = ext.isEmpty ? stem : "\(stem).\(ext)"
        if lstatPath(joinPath(dir, candidate)) == nil { return candidate }
        n += 1
    }
}

/// Sets creation, modification and access times (setattrlist, no symlink follow).
func setTimes(_ path: String, birth: timespec?, modified: timespec?, accessed: timespec?) {
    var list = attrlist()
    list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    var values: [timespec] = []
    // Buffer order must follow attribute bit order: crtime, modtime, acctime.
    if let b = birth { list.commonattr |= attrgroup_t(ATTR_CMN_CRTIME); values.append(b) }
    if let m = modified { list.commonattr |= attrgroup_t(ATTR_CMN_MODTIME); values.append(m) }
    if let a = accessed { list.commonattr |= attrgroup_t(ATTR_CMN_ACCTIME); values.append(a) }
    guard !values.isEmpty else { return }
    values.withUnsafeMutableBytes { buf in
        _ = setattrlist(path, &list, buf.baseAddress, buf.count, UInt32(FSOPT_NOFOLLOW))
    }
}

/// Free space on the volume holding `path`, preferring the figure Finder shows (includes purgeable space).
func availableSpace(at path: String) -> Int64 {
    var best: Int64 = 0
    let url = URL(fileURLWithPath: path)
    if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
       let important = v.volumeAvailableCapacityForImportantUsage {
        best = important
    }
    var fs = statfs()
    if statfs(path, &fs) == 0 {
        best = max(best, Int64(fs.f_bavail) * Int64(fs.f_bsize))
    }
    return best
}
