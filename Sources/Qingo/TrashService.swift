import AppKit
import Darwin

struct TrashService {
    let policy: SafetyPolicy

    init(policy: SafetyPolicy = SafetyPolicy()) { self.policy = policy }

    /// Shared pre-deletion verification for both `moveToTrash` and `directPurge`.
    private func validateDeletionTarget(_ item: ScanItem, allowDecided: Bool, validate: () throws -> Void = {}) throws -> URL {
        let versions = ToolVersions(home: policy.home)
        let tool = item.kind == .cache && item.canTrash ? versions.tool(for: item.url) : nil
        let url = item.url
        guard !policy.isProtected(url), !policy.hasProtectedDescendant(url) else { throw TrashError.notEligible }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw errno == ENOENT ? TrashError.gone : TrashError.changed }
        guard CanonicalPath.isDirect(url) else { throw TrashError.changed }
        let decided = policy.decisionNote(for: item) != nil
        if decided && !allowDecided { throw TrashError.notEligible }
        let diagnostic = item.kind == .cache && item.canTrash && DiagnosticJunk.recognizes(url, home: policy.home)
        if !decided && tool == nil && !diagnostic {
            guard item.kind == .cache, item.canTrash, policy.cacheDescription(for: url, isDirectory: true) != nil else { throw TrashError.notEligible }
        }
        // Old CLI binaries and confirmed large files can be regular files.
        let isDirectory = item.kind != .largeFile && !diagnostic && (tool == nil || tool?.executable != nil)
        let expectedType = isDirectory ? mode_t(S_IFDIR) : mode_t(S_IFREG)
        let current = FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
        // A cache the app rebuilt since the scan is a new folder at the same cache path: the policy above
        // re-approved the path, so it goes too. What the user decided about must be the very file they saw.
        guard current == item.identity || (!decided && tool == nil && !diagnostic), (info.st_mode & mode_t(S_IFMT)) == expectedType else { throw TrashError.changed }
        if let browser = BrowserCaches.owner(of: CanonicalPath.url(url), home: policy.home) {
            guard NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID).isEmpty else {
                throw TrashError.browserRunning(browser.name)
            }
        }
        if decided || tool != nil { try Self.ensureUnused(url, isDirectory: isDirectory) }
        if diagnostic, !DiagnosticJunk.eligible(url, home: policy.home) { throw TrashError.changed }
        if let tool, !versions.candidates(for: tool).contains(where: { $0.path == url.path }) { throw TrashError.notEligible }
        try validate()
        guard !policy.hasProtectedDescendant(url) else { throw TrashError.notEligible }
        // The usage check can take time; revalidate identity immediately before removing.
        guard CanonicalPath.isDirect(url), lstat(url.path, &info) == 0,
              FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino)) == current,
              (info.st_mode & mode_t(S_IFMT)) == expectedType else { throw TrashError.changed }
        return url
    }

    /// Moves a regenerable cache, or an item the user confirmed (`SafetyPolicy.decisionNote`). Everything else is refused.
    func moveToTrash(_ item: ScanItem, validate: () throws -> Void = {}) throws -> URL {
        let url = try validateDeletionTarget(item, allowDecided: true, validate: validate)
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        return resultingURL as URL? ?? url
    }

    /// Directly removes a 100% regenerable pure cache without passing through Trash, immediately freeing APFS space.
    /// Refuses anything that requires user confirmation (`SafetyPolicy.decisionNote`), project-name build artifacts, or changed identity.
    func directPurge(_ item: ScanItem) throws {
        guard policy.isDirectPurgeEligible(item) else { throw TrashError.notEligible }
        let url = try validateDeletionTarget(item, allowDecided: false) {
            guard Self.currentIdentity(item.url) == item.identity else { throw TrashError.changed }
        }
        try FileManager.default.removeItem(at: url)
    }

    /// Moves items one at a time; anything changed, protected or (for large files) in use is reported, not moved.
    /// Items already gone (cleaned elsewhere since the scan) are neither: they are only dropped from the list.
    /// Call off the main actor.
    static func moveAll(_ items: [ScanItem], policy: SafetyPolicy,
                        onCurrentItem: @Sendable (String) async -> Void = { _ in },
                        progress: @Sendable (Int) async -> Void = { _ in }) async -> CleanupOutcome {
        await runBatch(items, policy: policy, directPurge: false, onCurrentItem: onCurrentItem, progress: progress)
    }

    /// Directly purges pure regenerable caches so APFS free space increases immediately.
    /// Never accepts decided items (large files, backups, dependencies). Call off the main actor.
    static func purgeAll(_ items: [ScanItem], policy: SafetyPolicy,
                         onCurrentItem: @Sendable (String) async -> Void = { _ in },
                         progress: @Sendable (Int) async -> Void = { _ in }) async -> CleanupOutcome {
        await runBatch(items, policy: policy, directPurge: true, onCurrentItem: onCurrentItem, progress: progress)
    }

    private static func runBatch(_ items: [ScanItem], policy: SafetyPolicy, directPurge: Bool,
                                 onCurrentItem: @Sendable (String) async -> Void,
                                 progress: @Sendable (Int) async -> Void) async -> CleanupOutcome {
        var outcome = CleanupOutcome()
        outcome.openApps = await MainActor.run { ItemPresentation.runningOwners(for: items, home: policy.home) }
        let readings = CleanupVolumeReading.captureBefore(items)
        let service = TrashService(policy: policy)
        for item in items {
            await onCurrentItem(item.name)
            do {
                // A rebuilt cache is a different size than the scan saw: report what actually clears.
                let current = currentIdentity(item.url)
                let clearing = current == nil || current == item.identity ? item
                    : ScanItem(id: item.id, url: item.url, kind: item.kind, risk: item.risk, bytes: AppUninstaller.size(of: item.url),
                               note: item.note, canTrash: item.canTrash, identity: current!, modified: item.modified)
                if directPurge {
                    try service.directPurge(item)
                    outcome.purgedIDs.append(item.id)
                    outcome.purgedEntries.append((clearing.url, clearing.cleanupBytes))
                    outcome.purgedCount += 1
                    let add = outcome.purgedBytes.addingReportingOverflow(clearing.cleanupBytes)
                    outcome.purgedBytes = add.overflow ? Int64.max : add.partialValue
                } else {
                    let trashed = try service.moveToTrash(item)
                    outcome.moved.append(TrashedItem(item: clearing, trashed: trashed))
                    let addition = outcome.bytes.addingReportingOverflow(clearing.cleanupBytes)
                    outcome.bytes = addition.overflow ? Int64.max : addition.partialValue
                }
            } catch TrashError.gone {
                outcome.gone.append(item.id)
            } catch {
                let reasonText = directPurge && error as? TrashError == nil
                    ? "无法直接清理"
                    : reason(for: error)
                outcome.failures.append(CleanupReport.Failure(id: item.id, name: item.name, reason: reasonText))
            }
            await progress(outcome.moved.count + outcome.purgedCount + outcome.failures.count + outcome.gone.count)
        }
        let purgedItems = items.filter { outcome.purgedIDs.contains($0.id) }
        outcome.volumes = CleanupVolumeReading.captureAfter(readings, moved: outcome.moved, purgedIDs: purgedItems)
        outcome.recreatedCount = (outcome.moved.map(\.item) + purgedItems).count { entry in
            guard entry.kind == .cache, let identity = currentIdentity(entry.url) else { return false }
            return identity != entry.identity
        }
        return outcome
    }

    /// Measures current user Trash allocated bytes safely.
    static func trashOccupancyBytes(home: URL = AppHome.url) -> Int64 {
        let trash = home.appending(path: ".Trash")
        guard CanonicalPath.isDirect(trash), FileManager.default.fileExists(atPath: trash.path) else { return 0 }
        return FastSizeCalculator.allocatedBytes(of: trash)
    }

    /// Empties `~/.Trash` children directly after explicit user confirmation.
    static func emptyUserTrash(home: URL = AppHome.url) -> PurgeOutcome {
        var outcome = PurgeOutcome()
        let rawTrash = home.appending(path: ".Trash")
        guard CanonicalPath.isDirect(rawTrash) else { return outcome }
        let trash = CanonicalPath.url(rawTrash)
        let manager = FileManager.default
        guard let children = try? manager.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil, options: []) else {
            return outcome
        }
        for child in children {
            let canonical = CanonicalPath.url(child)
            guard canonical.path.hasPrefix(trash.path + "/"), CanonicalPath.isDirect(child) else {
                outcome.skippedOutsideTrash += 1
                continue
            }
            let size = FastSizeCalculator.allocatedBytes(of: child)
            do {
                try manager.removeItem(at: child)
                outcome.purgedCount += 1
                let add = outcome.purgedBytes.addingReportingOverflow(size)
                outcome.purgedBytes = add.overflow ? Int64.max : add.partialValue
            } catch {
                outcome.failedCount += 1
            }
        }
        return outcome
    }

    static func currentIdentity(_ url: URL) -> FileIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
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

    struct PurgeOutcome: Equatable, Sendable {
        var purgedCount: Int = 0
        var purgedBytes: Int64 = 0
        var failedCount: Int = 0
        var skippedOutsideTrash: Int = 0
        var purgedIDs: [URL] = []
    }

    /// Permanently removes ONLY the specific items that Qingo just moved into the Trash.
    /// Never empties the whole Trash and refuses any path outside the user's Trash directory or with changed file identity.
    static func purgeTrashed(_ entries: [TrashedItem], trashDirectory: URL? = nil) -> PurgeOutcome {
        var outcome = PurgeOutcome()
        let manager = FileManager.default
        let rawTrash = trashDirectory ?? ((try? manager.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
                                          ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash"))
        guard CanonicalPath.isDirect(rawTrash) else { return outcome }
        let resolvedTrash = CanonicalPath.url(rawTrash)
        let trashPrefix = resolvedTrash.path + "/"
        for entry in entries {
            let target = entry.trashed
            let canonical = CanonicalPath.url(target)
            guard canonical.path.hasPrefix(trashPrefix), CanonicalPath.isDirect(target) else {
                outcome.skippedOutsideTrash += 1
                continue
            }
            guard manager.fileExists(atPath: target.path) else {
                outcome.purgedIDs.append(entry.item.id)
                continue
            }
            // Verify the item in Trash still has the exact same inode/device identity we moved.
            guard let idNow = currentIdentity(target), idNow == entry.item.identity else {
                outcome.failedCount += 1
                continue
            }
            do {
                try manager.removeItem(at: target)
                outcome.purgedCount += 1
                outcome.purgedIDs.append(entry.item.id)
                let addition = outcome.purgedBytes.addingReportingOverflow(entry.item.cleanupBytes)
                outcome.purgedBytes = addition.overflow ? Int64.max : addition.partialValue
            } catch {
                outcome.failedCount += 1
            }
        }
        return outcome
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
    var purgedIDs: [URL] = []
    var purgedEntries: [(URL, Int64)] = []
    var purgedCount: Int = 0
    var purgedBytes: Int64 = 0
    var failures: [CleanupReport.Failure] = []
    /// Selected items that no longer exist; not a failure.
    var gone: [URL] = []
    var bytes: Int64 = 0
    var openApps: [String] = []
    var recreatedCount = 0
    var volumes: [CleanupVolumeReading] = []

    var report: CleanupReport {
        CleanupReport(movedCount: moved.count, movedBytes: bytes, failures: failures, openApps: openApps,
                      recreatedCount: recreatedCount, alreadyGoneCount: gone.count,
                      purgedCount: purgedCount, purgedBytes: purgedBytes)
    }
}

enum TrashError: LocalizedError, Equatable {
    case notEligible
    case changed
    case inUse
    case browserRunning(String)
    case usageUnknown
    case gone

    var errorDescription: String? {
        switch self {
        case .notEligible: "不在清理范围内"
        case .changed: "扫描后已发生变化，请重新扫描"
        case .inUse: "正在被其他程序使用"
        case .browserRunning(let name): "请退出 \(name) 后重试"
        case .usageUnknown: "无法确认是否在使用，已跳过"
        case .gone: "文件已不存在"
        }
    }
}
