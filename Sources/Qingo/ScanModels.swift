import Foundation

enum ScanKind: String, Codable, Sendable {
    // rawValue is persisted in saved results; change `label` for wording, not the cases.
    case cache = "可再生缓存"
    case project = "项目或资源库"
    case largeFile = "大文件"
    case review = "在原软件处理"
    case folder = "文件夹"

    var label: String {
        switch self {
        case .cache: "可重新生成的缓存"
        case .project: "项目或资源库"
        case .largeFile: "大文件"
        case .review: "需在原软件中处理"
        case .folder: "文件夹"
        }
    }
}

enum ScanRisk: String, Codable, Sendable {
    case a = "A · 可再生缓存"
    case b = "B · 应用缓存"
    case c = "C · 人工判断"
}

struct ScanItem: Identifiable, Codable, Sendable {
    let id: URL
    let url: URL
    let kind: ScanKind
    let risk: ScanRisk
    let bytes: Int64
    let note: String
    let canTrash: Bool
    let identity: FileIdentity
    /// Last change of the item itself, shown as "N 个月没动过" on rows the user decides about. Absent in older saved results.
    var modified: Date? = nil

    var name: String { url.lastPathComponent }
}

struct FileIdentity: Equatable, Codable, Sendable {
    let device: UInt64
    let inode: UInt64
}

struct ScanResult: Codable, Sendable {
    let root: URL
    let isQuickScan: Bool
    let items: [ScanItem]
    let totalBytes: Int64
    let volumeTotalBytes: Int64?
    let volumeFreeBytes: Int64?
    let skippedCount: Int
    let scannedCount: Int
    let scannedAt: Date
    /// WeChat / WeCom data size, measured read-only and never offered for cleanup.
    var chatApps: [ChatAppUsage] = []
}

struct ChatAppUsage: Codable, Sendable, Identifiable {
    let id: String
    let name: String
    /// nil when macOS denied reading the app's data (needs Full Disk Access).
    let bytes: Int64?
    /// Where the space goes, estimated from the app's own folder layout; nil in older results or when unreadable.
    var parts: [ChatPart]? = nil
}

/// One share of a chat app's data. Estimated from folder names inside the app's container, so shown as "大约".
struct ChatPart: Codable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        /// Cleaned by the app's own "清理缓存", without touching chats.
        case cache
        /// Pictures, videos and files sent in chats: only the user can pick what goes.
        case media
        /// The chat history database.
        case records
        /// WeCom's WeDrive: the user's own synced files.
        case drive
        case other
    }

    let kind: Kind
    let bytes: Int64
    var id: String { kind.rawValue }
}

struct CleanupReport: Sendable {
    struct Failure: Sendable, Identifiable {
        let id: URL
        let name: String
        let reason: String
    }

    let movedCount: Int
    let movedBytes: Int64
    let failures: [Failure]
}

struct ScanProgress: Sendable {
    let scannedCount: Int
    let currentFolder: String
}

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        if bytes == 0 { return "0 B" }
        if bytes < 1_000 { return "< 1 KB" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
