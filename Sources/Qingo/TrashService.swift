import Foundation
import Darwin

struct TrashService {
    let policy: SafetyPolicy

    init(policy: SafetyPolicy = SafetyPolicy()) { self.policy = policy }

    /// Moves a regenerable cache, or an item the user confirmed (`SafetyPolicy.decisionNote`). Everything else is refused.
    func moveToTrash(_ item: ScanItem) throws -> URL {
        let url = item.url.standardizedFileURL
        guard !policy.isProtected(url) else { throw TrashError.notEligible }
        let decided = policy.decisionNote(for: item) != nil
        if !decided {
            guard item.kind == .cache, item.canTrash, policy.cacheDescription(for: url, isDirectory: true) != nil else { throw TrashError.notEligible }
        }
        // Caches and decided folders are directories; only a decided large file may be a regular file.
        let isDirectory = item.kind != .largeFile
        let expectedType = isDirectory ? mode_t(S_IFDIR) : mode_t(S_IFREG)
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw TrashError.changed }
        let current = FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
        guard current == item.identity, (info.st_mode & mode_t(S_IFMT)) == expectedType else { throw TrashError.changed }
        // A regenerable cache may go while its app is open: the app just builds a new one, nothing is lost
        // (the user cleans in one click; asking them to quit apps first was the wrong trade-off).
        // Anything the user decides about (a large file) must not be in use.
        if decided { try Self.ensureUnused(url, isDirectory: isDirectory) }
        // The usage check can take time; revalidate identity immediately before moving.
        guard lstat(url.path, &info) == 0,
              FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino)) == item.identity,
              (info.st_mode & mode_t(S_IFMT)) == expectedType else { throw TrashError.changed }
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        return resultingURL as URL? ?? url
    }

    /// Moves items one at a time; anything changed, protected or (for large files) in use is reported, not moved.
    /// Call off the main actor.
    static func moveAll(_ items: [ScanItem], policy: SafetyPolicy, progress: @Sendable (Int) async -> Void = { _ in }) async -> CleanupOutcome {
        var outcome = CleanupOutcome()
        let service = TrashService(policy: policy)
        for item in items {
            do {
                let owner = await MainActor.run { ItemPresentation.runningOwner(of: item) }
                let trashed = try service.moveToTrash(item)
                if let owner, !outcome.openApps.contains(owner) { outcome.openApps.append(owner) }
                outcome.moved.append(TrashedItem(item: item, trashed: trashed))
                let addition = outcome.bytes.addingReportingOverflow(item.bytes)
                outcome.bytes = addition.overflow ? Int64.max : addition.partialValue
            } catch {
                outcome.failures.append(CleanupReport.Failure(id: item.id, name: item.name, reason: reason(for: error)))
            }
            await progress(outcome.moved.count + outcome.failures.count)
        }
        return outcome
    }

    /// Moves trashed items back. Skips any whose original place is taken again or that left the Trash.
    /// Returns, per entry, whether it went back.
    static func putBack(_ entries: [(original: URL, trashed: URL)]) -> [Bool] {
        entries.map { entry in
            let manager = FileManager.default
            guard !manager.fileExists(atPath: entry.original.path), manager.fileExists(atPath: entry.trashed.path) else { return false }
            return (try? manager.moveItem(at: entry.trashed, to: entry.original)) != nil
        }
    }

    /// Fail closed when the OS cannot establish that no process has files open here.
    static func ensureUnused(_ url: URL, isDirectory: Bool = true) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-n", "-P", "-t"] + (isDirectory ? ["+D", url.path] : [url.path])
        let output = Pipe()
        process.standardOutput = output
        let errors = Pipe()
        process.standardError = errors
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { throw TrashError.usageUnknown }
        guard finished.wait(timeout: .now() + 8) == .success else {
            process.terminate()
            throw TrashError.usageUnknown
        }
        let openFiles = output.fileHandleForReading.readDataToEndOfFile()
        let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
        // lsof may return 1 while still reporting matching PIDs on macOS.
        if !openFiles.isEmpty || process.terminationStatus == 0 { throw TrashError.inUse }
        guard process.terminationStatus == 1, diagnostics.isEmpty else { throw TrashError.usageUnknown }
    }

    /// Short Chinese reason for the cleanup report; raw Foundation messages are long and English.
    static func reason(for error: Error) -> String {
        if let trashError = error as? TrashError { return trashError.errorDescription ?? "未处理" }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: return "没有权限移动"
            case NSFileNoSuchFileError: return "文件已不存在"
            default: break
            }
        }
        if nsError.domain == NSPOSIXErrorDomain, [Int(EPERM), Int(EACCES)].contains(nsError.code) {
            return "没有权限移动"
        }
        return "移到废纸篓失败"
    }
}

struct CleanupOutcome: Sendable {
    var moved: [TrashedItem] = []
    var failures: [CleanupReport.Failure] = []
    var bytes: Int64 = 0
    var openApps: [String] = []

    var report: CleanupReport { CleanupReport(movedCount: moved.count, movedBytes: bytes, failures: failures, openApps: openApps) }
}

enum TrashError: LocalizedError {
    case notEligible
    case changed
    case inUse
    case usageUnknown

    var errorDescription: String? {
        switch self {
        case .notEligible: "不在清理范围内"
        case .changed: "扫描后已发生变化，请重新扫描"
        case .inUse: "正在被其他程序使用"
        case .usageUnknown: "无法确认是否在使用，已跳过"
        }
    }
}
