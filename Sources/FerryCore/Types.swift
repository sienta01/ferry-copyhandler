import Foundation

public enum TransferKind: String, Codable, Sendable {
    case copy, move

    public var verb: String { self == .copy ? "Copy" : "Move" }
    public var progressive: String { self == .copy ? "Copying" : "Moving" }
    public var past: String { self == .copy ? "Copied" : "Moved" }
}

/// What to do when the destination already has an item with the same name.
public enum CollisionPolicy: String, CaseIterable, Identifiable, Codable, Sendable {
    case ask, overwrite, overwriteIfNewer, skip, keepBoth

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .ask: return "Ask me"
        case .overwrite: return "Replace"
        case .overwriteIfNewer: return "Replace if newer"
        case .skip: return "Skip"
        case .keepBoth: return "Keep both"
        }
    }
}

public enum ErrorPolicy: String, CaseIterable, Identifiable, Codable, Sendable {
    case ask, skip

    public var id: String { rawValue }
    public var title: String { self == .ask ? "Ask me" : "Skip the file and log it" }
}

public struct TransferOptions: Sendable {
    public var collision: CollisionPolicy = .ask
    public var errors: ErrorPolicy = .ask
    /// Re-read every copied file and compare SHA-256 digests (TeraCopy-style verify).
    public var verify = false
    /// Use APFS clones when source and destination are on the same volume.
    public var useClones = true
    /// Pipelined copy buffers. Only allocated while a job is running.
    public var bufferSize = 4 << 20
    public var bufferCount = 3

    public init() {}
}

public enum ItemKind: UInt8, Sendable { case file, directory, symlink, special }
public enum ItemStatus: UInt8, Sendable { case pending, active, done, skipped, failed }

/// One entry of a job's flattened file list. Kept small: a job can hold millions.
public struct TransferItem: Sendable {
    public var root: Int32
    /// Path relative to the root source ("" for the root itself).
    public var rel: String
    public var size: Int64
    public var kind: ItemKind
    public var status: ItemStatus = .pending
    public var message: String?
    /// Where the item actually went, when that differs from the plain mirror of the source
    /// (a "Keep both" rename, or inside a renamed folder). nil for the common case to save memory.
    public var destinationOverride: String?
}

/// A top-level item the user asked to transfer.
public struct TransferRoot: Sendable {
    public let source: String
    /// Name the root gets inside the destination folder (differs for "copy" duplicates).
    public var destName: String
}

// MARK: - Prompts

public struct CollisionInfo: Sendable {
    public let source: String
    public let destination: String
    public let sourceSize: Int64
    public let destinationSize: Int64
    public let sourceDate: Date
    public let destinationDate: Date
    public let sourceIsDirectory: Bool
    public let destinationIsDirectory: Bool
}

public enum Prompt: Sendable {
    case collision(CollisionInfo)
    case error(path: String, message: String)
    case lowSpace(needed: Int64, available: Int64)
}

public enum PromptAnswer: Sendable {
    case replace, replaceIfNewer, skip, keepBoth, retry, proceed, cancel
}

public struct PromptResponse: Sendable {
    public var answer: PromptAnswer
    public var applyToAll: Bool

    public init(_ answer: PromptAnswer, applyToAll: Bool = false) {
        self.answer = answer
        self.applyToAll = applyToAll
    }
}

// MARK: - Formatting

public enum Fmt {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    private static let countFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private static let durationFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        f.allowedUnits = [.hour, .minute, .second]
        return f
    }()

    public static func bytes(_ b: Int64) -> String { byteFormatter.string(fromByteCount: b) }
    public static func speed(_ bytesPerSecond: Double) -> String {
        bytes(Int64(max(0, bytesPerSecond))) + "/s"
    }
    public static func count(_ n: Int) -> String { countFormatter.string(from: NSNumber(value: n)) ?? "\(n)" }
    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        if seconds < 1 { return "<1s" }
        return durationFormatter.string(from: seconds.rounded()) ?? "—"
    }
}
