import Foundation
import Darwin

struct DiskScanner: Sendable {
    let policy: SafetyPolicy
    let largeFileThreshold: Int64
    /// Projects and app data below this are noise in "大文件与工程" (config dirs, tiny .xcodeproj).
    let minProjectBytes: Int64 = 200_000_000
    /// "需要判断" items below this are not worth a decision.
    let minReviewBytes: Int64 = 50_000_000
    /// A recognized tool's read-only data below this is not worth a row.
    let minToolDataBytes: Int64 = 1_000_000
    /// Called for every item as it is found, so the scanning screen can show live discoveries.
    var onFound: (@Sendable (ScanItem) -> Void)?

    init(policy: SafetyPolicy = SafetyPolicy(), largeFileThreshold: Int64 = 1_000_000_000) {
        self.policy = policy
        self.largeFileThreshold = largeFileThreshold
    }

    func scan(_ input: URL, onProgress: @Sendable (ScanProgress) -> Void = { _ in }) throws -> ScanResult {
        let root = CanonicalPath.url(input)
        guard root.isFileURL else { throw ScanError.invalidRoot }
        let values = try root.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw ScanError.invalidRoot }
        var items: [ScanItem] = []
        var skipped = 0
        var scanned = 0
        let rootDevice = try identity(root).device
        onProgress(ScanProgress(scannedCount: 0, currentFolder: root.path))
        var total = try walk(root, root: root, rootDevice: rootDevice, depth: 0, insideProject: false, items: &items, skipped: &skipped, scanned: &scanned, onProgress: onProgress).logical
        if root == policy.home {
            total = addLeftovers(&items, total: total)
            addToolVersions(&items)
            addOldDiagnostics(&items)
        }
        items.sort { $0.bytes > $1.bytes }
        let filesystem = try? FileManager.default.attributesOfFileSystem(forPath: root.path)
        let volumeTotal = (filesystem?[.systemSize] as? NSNumber)?.int64Value
        let volumeFree = (filesystem?[.systemFreeSize] as? NSNumber)?.int64Value
        let result = ScanResult(root: root, isQuickScan: false, items: items, totalBytes: total, volumeTotalBytes: volumeTotal, volumeFreeBytes: volumeFree, skippedCount: skipped, scannedCount: scanned, scannedAt: Date())
        return result
    }

    func scanKnownCaches(onProgress: @Sendable (ScanProgress) -> Void = { _ in }) throws -> ScanResult {
        let root = policy.home
        let rootDevice = try identity(root).device
        var items: [ScanItem] = []
        var skipped = 0
        var scanned = 0
        var total: Int64 = 0
        onProgress(ScanProgress(scannedCount: 0, currentFolder: root.path))
        for location in policy.quickScanLocations {
            try Task<Never, Never>.checkCancellation()
            onProgress(ScanProgress(scannedCount: scanned, currentFolder: location.path))
            let bytes: MeasuredSize
            if let note = policy.ownerManagedNote(for: location),
               !policy.isProtected(location), !policy.hasProtectedDescendant(location) {
                bytes = try measureKnownTree(location, device: rootDevice, skipped: &skipped, scanned: &scanned,
                                             onProgress: onProgress)
                if bytes.logical > 0, let meta = try? metadata(location) {
                    emit(&items, item(location, kind: .review, bytes: bytes.logical, note: note, canTrash: false,
                                      identity: meta.identity, modified: meta.modified))
                }
            } else if let note = policy.cacheDescription(for: location, isDirectory: true),
                      policy.reviewDescription(for: location, isDirectory: true) == nil,
                      !policy.hasProtectedDescendant(location), CanonicalPath.isDirect(location),
                      let meta = try? metadata(location), meta.identity.device == rootDevice, isMovable(location) {
                let skippedBefore = skipped
                bytes = try measureKnownTree(location, device: rootDevice, skipped: &skipped, scanned: &scanned,
                                             onProgress: onProgress)
                if bytes.logical > 0 && skipped == skippedBefore {
                    emit(&items, item(location, kind: .cache, bytes: bytes.logical, note: note, canTrash: true,
                                      identity: meta.identity, modified: meta.modified, allocated: bytes.allocated))
                }
            } else {
                bytes = try walk(location, root: root, rootDevice: rootDevice, depth: 1, insideProject: false,
                                 items: &items, skipped: &skipped, scanned: &scanned, onProgress: onProgress)
            }
            let addition = total.addingReportingOverflow(bytes.logical)
            total = addition.overflow ? Int64.max : addition.partialValue
        }
        total = addLeftovers(&items, total: total)
        for extra in [addToolVersions(&items), addOldDiagnostics(&items)] {
            let addition = total.addingReportingOverflow(extra)
            total = addition.overflow ? Int64.max : addition.partialValue
        }
        items.sort { $0.bytes > $1.bytes }
        let filesystem = try? FileManager.default.attributesOfFileSystem(forPath: root.path)
        let result = ScanResult(root: root, isQuickScan: true, items: items, totalBytes: total,
                                volumeTotalBytes: (filesystem?[.systemSize] as? NSNumber)?.int64Value,
                                volumeFreeBytes: (filesystem?[.systemFreeSize] as? NSNumber)?.int64Value,
                                skippedCount: skipped, scannedCount: scanned, scannedAt: Date())
        return result
    }

    /// True 3-stage Full-Home Deep Scan:
    /// 1) Collects all known system, browser, AI & dev tool caches + leftovers/diagnostics;
    /// 2) Walks the full user Home tree (coding workspaces, Downloads/Desktop/Documents/Movies/Music/Pictures,
    ///    and MobileSync backups) to surface project build caches (`.build`/`target`/`.next/cache`/`__pycache__`),
    ///    installers, and ≥100 MB large files;
    /// 3) Consolidates deduplicated items and finalizes storage totals.
    func scanOverview(onProgress: @Sendable (ScanProgress) -> Void = { _ in }) throws -> ScanResult {
        let stage1Title = "阶段 1/3 · 正在扫描系统、浏览器与 AI 缓存"
        let stage2Title = "阶段 2/3 · 正在全盘深扫个人目录、工程构建与大文件"
        let stage3Title = "阶段 3/3 · 正在整理诊断日志与空间报告"

        let quick = try scanKnownCaches { progress in
            onProgress(ScanProgress(scannedCount: progress.scannedCount, currentFolder: progress.currentFolder, stage: stage1Title))
        }
        let full = try scanFullHomeAdditions(after: quick) { progress in
            onProgress(ScanProgress(scannedCount: progress.scannedCount, currentFolder: progress.currentFolder, stage: stage2Title))
        }
        onProgress(ScanProgress(scannedCount: full.scannedCount, currentFolder: policy.home.path, stage: stage3Title))
        return full
    }

    func scanFullHomeAdditions(after quick: ScanResult, onProgress: @Sendable (ScanProgress) -> Void = { _ in }) throws -> ScanResult {
        let root = policy.home
        let rootDevice = try identity(root).device
        var items = quick.items
        var existingPaths = Set(items.map(\.url.path))
        let existingCachePaths = items.filter { $0.kind == .cache }.map(\.url.path)
        var total = quick.totalBytes
        var skipped = quick.skippedCount
        var scanned = quick.scannedCount

        var overviewLargeScanner = DiskScanner(policy: policy, largeFileThreshold: min(largeFileThreshold, 100_000_000))
        overviewLargeScanner.onFound = onFound

        let libraryPath = root.appending(path: "Library").path
        let homeChildren = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [])) ?? []
        var scanTargets = homeChildren.filter { child in
            let path = CanonicalPath.url(child).path
            return path != libraryPath && CanonicalPath.isDirect(child) && !policy.isProtected(child)
        }
        let mobileBackup = root.appending(path: "Library/Application Support/MobileSync/Backup")
        if CanonicalPath.isDirect(mobileBackup) && FileManager.default.fileExists(atPath: mobileBackup.path) {
            scanTargets.append(mobileBackup)
        }

        for target in scanTargets.sorted(by: { $0.path < $1.path }) {
            try Task<Never, Never>.checkCancellation()
            onProgress(ScanProgress(scannedCount: scanned, currentFolder: target.path))
            var found: [ScanItem] = []
            let measured = try overviewLargeScanner.walk(target, root: root, rootDevice: rootDevice, depth: 1,
                                                         insideProject: false, items: &found, skipped: &skipped,
                                                         scanned: &scanned, onProgress: onProgress)
            let addition = total.addingReportingOverflow(measured.logical)
            total = addition.overflow ? Int64.max : addition.partialValue
            for entry in found {
                let p = entry.url.path
                let overlapsExistingCache = existingCachePaths.contains { $0 == p || p.hasPrefix($0 + "/") || $0.hasPrefix(p + "/") }
                if !overlapsExistingCache && existingPaths.insert(p).inserted {
                    emit(&items, entry)
                }
            }
        }

        items.sort { $0.bytes > $1.bytes }
        return ScanResult(root: root, isQuickScan: false, items: items, totalBytes: total,
                          volumeTotalBytes: quick.volumeTotalBytes, volumeFreeBytes: quick.volumeFreeBytes,
                          skippedCount: skipped, scannedCount: scanned, scannedAt: Date(),
                          chatApps: quick.chatApps)
    }

    /// 个人文件夹外的残留（浏览器旧版签名副本、Clang 编译缓存），见 `Leftovers`
    private func addLeftovers(_ items: inout [ScanItem], total: Int64) -> Int64 {
        var sum = total
        // 系统临时目录属于当前用户：只在扫这个用户自己的个人文件夹时带上（测试、演示用的是别的文件夹）
        guard policy.home == CanonicalPath.url(FileManager.default.homeDirectoryForCurrentUser) else { return sum }
        for found in Leftovers.find() where !items.contains(where: { $0.url == found.url }) {
            guard CanonicalPath.isDirect(found.url), !policy.hasProtectedDescendant(found.url),
                  let meta = try? metadata(found.url) else { continue }
            emit(&items, item(found.url, kind: .cache, bytes: found.bytes, note: found.note, canTrash: true, identity: meta.identity, modified: meta.modified))
            let addition = sum.addingReportingOverflow(found.bytes)
            sum = addition.overflow ? Int64.max : addition.partialValue
        }
        return sum
    }

    @discardableResult
    private func addToolVersions(_ items: inout [ScanItem]) -> Int64 {
        var total: Int64 = 0
        for found in ToolVersions(home: policy.home).find()
        where !policy.isProtected(found.url) && !items.contains(where: { $0.url.path == found.url.path && $0.kind == .cache }) {
            guard CanonicalPath.isDirect(found.url), !policy.hasProtectedDescendant(found.url),
                  let meta = try? metadata(found.url) else { continue }
            items.removeAll { $0.url.path == found.url.path || $0.url.path.hasPrefix(found.url.path + "/") }
            emit(&items, item(found.url, kind: .cache, bytes: found.bytes, note: found.note, canTrash: true, identity: meta.identity, modified: meta.modified))
            total += found.bytes
        }
        return total
    }

    @discardableResult
    private func addOldDiagnostics(_ items: inout [ScanItem]) -> Int64 {
        var total: Int64 = 0
        for url in DiagnosticJunk.find(home: policy.home) where !policy.isProtected(url) {
            guard let meta = try? metadata(url) else { continue }
            items.removeAll { $0.url.path == url.path }
            emit(&items, item(url, kind: .cache, bytes: meta.size, note: DiagnosticJunk.note, canTrash: true,
                              identity: meta.identity, modified: meta.modified, allocated: meta.allocated))
            total += meta.size
        }
        return total
    }

    private struct MeasuredSize {
        var logical: Int64 = 0
        var allocated: Int64 = 0

        mutating func add(_ other: MeasuredSize) {
            let logicalSum = logical.addingReportingOverflow(other.logical)
            let allocatedSum = allocated.addingReportingOverflow(other.allocated)
            logical = logicalSum.overflow ? Int64.max : logicalSum.partialValue
            allocated = allocatedSum.overflow ? Int64.max : allocatedSum.partialValue
        }
    }

    /// Exact cache/store roots use batched `getattrlistbulk` via `FastSizeCalculator` for 3–5x faster scans.
    private func measureKnownTree(_ url: URL, device: UInt64, skipped: inout Int, scanned: inout Int,
                                  onProgress: @Sendable (ScanProgress) -> Void) throws -> MeasuredSize {
        try Task.checkCancellation()
        guard let root = try? metadata(url), root.identity.device == device, root.isDirectory, !root.isLink else {
            skipped += 1
            return .init()
        }
        onProgress(ScanProgress(scannedCount: scanned, currentFolder: url.path))
        let summary = FastSizeCalculator.measure(url, conservativeHardLinks: true)
        scanned += max(1, summary.itemCount + 1)
        skipped += summary.unreadableCount
        onProgress(ScanProgress(scannedCount: scanned, currentFolder: url.path))
        return MeasuredSize(logical: summary.logical, allocated: summary.allocated)
    }

    private func walk(_ url: URL, root: URL, rootDevice: UInt64, depth: Int, insideProject: Bool, items: inout [ScanItem], skipped: inout Int, scanned: inout Int, onProgress: @Sendable (ScanProgress) -> Void) throws -> MeasuredSize {
        try Task<Never, Never>.checkCancellation()
        scanned += 1
        if scanned.isMultiple(of: 200) {
            onProgress(ScanProgress(scannedCount: scanned, currentFolder: url.deletingLastPathComponent().path))
        }
        guard let metadata = try? metadata(url) else { skipped += 1; return .init() }
        if metadata.identity.device != rootDevice || metadata.isLink { skipped += 1; return .init() }
        let allowedProtectedChildren = policy.allowedChildren(ofProtectedRoot: url)
        if policy.isProtected(url), allowedProtectedChildren == nil {
            skipped += 1
            return .init()
        }

        if !metadata.isDirectory {
            if policy.isProject(url), !insideProject, url != root, metadata.size >= minProjectBytes {
                emit(&items, item(url, kind: .project, bytes: metadata.size, note: "项目文件，仅显示大小。", canTrash: false, identity: metadata.identity, modified: metadata.modified))
            } else if !insideProject, url != root,
                      metadata.size >= largeFileThreshold || (metadata.size >= 100_000_000 && ["dmg", "pkg", "ipsw"].contains(url.pathExtension.lowercased())) {
                let installer = ["dmg", "pkg", "ipsw"].contains(url.pathExtension.lowercased())
                let installed = installer ? InstallerMatch.installedApp(for: url) : nil
                let note = installed.map { "已安装「\($0)」，安装包删除后不影响使用。" }
                    ?? (installer ? "安装包，删除前请确认不再需要。" : "大文件，删除前请确认不再需要。")
                emit(&items, item(url, kind: .largeFile, bytes: metadata.size, note: note, canTrash: false, identity: metadata.identity, modified: metadata.modified))
            }
            return MeasuredSize(logical: metadata.size, allocated: metadata.allocated)
        }

        let reviewNote = policy.reviewDescription(for: url, isDirectory: true)
        let project = reviewNote == nil && policy.isProject(url)
        // Skip caches we could not move anyway (root-owned or system-protected), so they never reach the cleanup list.
        // A recognized tool's own caches stay cleanable inside its otherwise read-only folder.
        let toolCache = !policy.isProtected(url) && CreativeApp.cacheNote(url, home: policy.home) != nil
        let cacheNote = (!insideProject || toolCache) ? policy.cacheDescription(for: url, isDirectory: true) : nil

        // Fast bulk measurement for deep non-cache subtrees inside recognized AI/creative dot-folders
        // (e.g. ~/.workbuddy/connectors-marketplace-skills) without missing any real caches or profiles.
        if insideProject, depth >= 2, reviewNote == nil, cacheNote == nil, !project,
           allowedProtectedChildren == nil,
           let app = CreativeApp.dataOwner(url, home: policy.home),
           app.group != .localModel,
           !Self.canContainToolCache(url, app: app, home: policy.home) {
            return try measureKnownTree(url, device: rootDevice, skipped: &skipped, scanned: &scanned, onProgress: onProgress)
        }
        let children: [URL]
        if let allowedProtectedChildren {
            children = allowedProtectedChildren.filter { FileManager.default.fileExists(atPath: $0.path) }
            skipped += 1
        } else {
            do {
                children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
            } catch {
                skipped += 1
                return .init()
            }
        }
        var measured = MeasuredSize()
        for child in children {
            let value = try walk(child, root: root, rootDevice: rootDevice, depth: depth + 1, insideProject: insideProject || project || reviewNote != nil, items: &items, skipped: &skipped, scanned: &scanned, onProgress: onProgress)
            measured.add(value)
        }
        let sum = measured.logical
        if url != root {
            if project, sum < minProjectBytes {
                // Too small to be worth listing; still counted in the parent total.
            } else if project {
                let note = url.lastPathComponent == "Figma" ? "Figma 的本地数据，可能包含未同步的离线改动。仅显示大小，请在 Figma 中处理。" : "项目或应用数据，仅显示大小。"
                emit(&items, item(url, kind: .project, bytes: sum, note: note, canTrash: false, identity: metadata.identity, modified: metadata.modified))
            } else if let reviewNote {
                if url.path == policy.home.appending(path: "Library/Application Support/Shandianshuo/recordings").path {
                    let old = oldRecordingSummary(at: url)
                    if old.count > 0 {
                        emit(&items, item(url, kind: .review, bytes: old.bytes, note: "超过 15 天的录音 \(old.count) 条。\(reviewNote)", canTrash: false, identity: metadata.identity, modified: metadata.modified))
                    }
                } else {
                    // Caches and single models found inside are listed on their own; the read-only row counts the rest.
                    let prefix = url.path + "/"
                    let ownRow = { (found: ScanItem) in found.kind == .cache || policy.isOwnRowInToolData(found.url) }
                    let cached = items.filter { ownRow($0) && $0.url.path.hasPrefix(prefix) }.reduce(Int64(0)) { $0 + $1.bytes }
                    let remaining = max(sum - cached, 0)
                    let tool = CreativeApp.dataOwner(url, home: policy.home) != nil
                    if remaining >= (tool ? minToolDataBytes : minReviewBytes) || CreativeApp.isReviewCache(url) ||
                        (remaining > 0 && policy.ownerManagedNote(for: url) != nil) {
                        items.removeAll { !ownRow($0) && $0.url.path.hasPrefix(prefix) }
                        emit(&items, item(url, kind: .review, bytes: remaining, note: reviewNote, canTrash: false, identity: metadata.identity, modified: metadata.modified))
                    }
                }
            } else if let cacheNote, sum > 0, isMovable(url), CanonicalPath.isDirect(url), !policy.hasProtectedDescendant(url) {
                // Hide descendants of a suggested cache to avoid overlapping actions.
                items.removeAll { $0.url.path.hasPrefix(url.path + "/") }
                emit(&items, item(url, kind: .cache, bytes: sum, note: cacheNote, canTrash: true,
                                  identity: metadata.identity, modified: metadata.modified, allocated: measured.allocated))
            }
        }
        return measured
    }

    private static func canContainToolCache(_ url: URL, app: CreativeApp, home: URL) -> Bool {
        let path = url.standardizedFileURL.path
        for rel in app.caches {
            let target = home.appending(path: rel).standardizedFileURL.path
            if path == target || target.hasPrefix(path + "/") { return true }
        }
        let lower = url.lastPathComponent.lowercased()
        let cacheContainers: Set<String> = [
            "app", "session", "partitions", "logs", "log", "crashpad",
            "cache", "code cache", "gpucache", "dawncache", "dawngraphitecache",
            "dawnwebgpucache", "grshadercache", "shadercache", "cacheddata",
            "cachedextensionvsixs", "cachedprofilesdata"
        ]
        if cacheContainers.contains(lower) { return true }
        if url.deletingLastPathComponent().lastPathComponent.lowercased() == "partitions" { return true }
        if FileManager.default.fileExists(atPath: url.appending(path: "Preferences").path)
            || FileManager.default.fileExists(atPath: url.appending(path: "Local State").path) {
            return true
        }
        return false
    }

    private func item(_ url: URL, kind: ScanKind, bytes: Int64, note: String, canTrash: Bool, identity: FileIdentity, modified: Date, allocated: Int64? = nil) -> ScanItem {
        ScanItem(id: url, url: url, kind: kind, risk: policy.risk(for: url, kind: kind), bytes: bytes, note: note, canTrash: canTrash,
                 identity: identity, modified: modified, allocatedBytes: allocated)
    }

    private func oldRecordingSummary(at root: URL) -> (count: Int, bytes: Int64) {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]) else { return (0, 0) }
        let cutoff = Date().addingTimeInterval(-15 * 24 * 60 * 60)
        var count = 0
        var bytes: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                  values.isRegularFile == true, let date = values.contentModificationDate, date < cutoff else { continue }
            count += 1
            let addition = bytes.addingReportingOverflow(Int64(values.fileSize ?? 0))
            bytes = addition.overflow ? Int64.max : addition.partialValue
        }
        return (count, bytes)
    }

    private func metadata(_ url: URL) throws -> (identity: FileIdentity, isDirectory: Bool, isLink: Bool, size: Int64, allocated: Int64, modified: Date) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw ScanError.unreadable(url) }
        let type = info.st_mode & mode_t(S_IFMT)
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        // A hard link may still exist outside the selected cache. Sparse regions have no blocks to release.
        let allocated = type == S_IFREG && info.st_nlink == 1 ? max(0, Int64(info.st_blocks) * 512) : 0
        return (FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino)), type == mode_t(S_IFDIR),
                type == mode_t(S_IFLNK), max(0, info.st_size), allocated, modified)
    }

    private func identity(_ url: URL) throws -> FileIdentity { try metadata(url).identity }

    private func emit(_ items: inout [ScanItem], _ item: ScanItem) {
        items.append(item)
        onFound?(item)
    }

    /// Read-only size of the chat apps' data. These folders stay protected; this only measures them.
    func chatAppUsage() -> [ChatAppUsage] {
        let home = policy.home
        let groupRoot = home.appending(path: "Library/Group Containers")
        let groups = (try? FileManager.default.contentsOfDirectory(atPath: groupRoot.path)) ?? []
        // Show apps with local data, including leftovers after an uninstall.
        return ChatCache.apps.compactMap { app in
            guard !Task.isCancelled else { return nil }
            var roots = [ChatCache.root(of: app, home: home)]
            if app.isSandboxed {
                roots += groups.filter { $0.hasSuffix(".\(app.bundleID)") }.map { groupRoot.appending(path: $0) }
            }
            roots = roots.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !roots.isEmpty else { return nil }
            var total: Int64 = 0
            for root in roots {
                // A protected container lists as unreadable without Full Disk Access.
                guard (try? FileManager.default.contentsOfDirectory(atPath: root.path)) != nil else {
                    return ChatAppUsage(id: app.bundleID, name: app.name, bytes: nil)
                }
                total += allocatedSize(of: root)
            }
            return ChatAppUsage(id: app.bundleID, name: app.name, bytes: total, parts: chatParts(app, total: total))
        }
    }

    /// Splits a chat app's data by what its folders hold (WeChat 4 / WeCom / Feishu layouts, measured 2026-10-31).
    /// Folders that are not there count as zero; whatever is not matched is "other".
    private func chatParts(_ app: ChatCache.App, total: Int64) -> [ChatPart] {
        let root = ChatCache.dataRoot(of: app, home: policy.home)
        let documents = root.appending(path: "Documents")
        func size(_ urls: [URL]) -> Int64 { urls.reduce(0) { $0 + allocatedSize(of: $1) } }
        func children(_ url: URL, _ name: String) -> [URL] {
            ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []).map { $0.appending(path: name) }
        }
        var parts: [ChatPart] = []
        if app.bundleID == "com.tencent.xinWeChat" {
            let accounts = documents.appending(path: "xwechat_files")
            parts = [ChatPart(kind: .media, bytes: size(children(accounts, "msg"))),
                     ChatPart(kind: .records, bytes: size(children(accounts, "db_storage"))),
                     // `app_data` is the account's own data, not a cache — but it is small next to the
                     // messages, and counting it here says "this is what the app owns", not "this is cleanable".
                     ChatPart(kind: .cache, bytes: size([documents.appending(path: "app_data"), root.appending(path: ".wxapplet"),
                                                         root.appending(path: "Library/Caches")]))]
        } else if app.bundleID == "com.electron.lark" {
            // Count known folders for display; local messages and received files remain protected.
            let sdk = root.appending(path: "sdk_storage")
            parts = [ChatPart(kind: .media, bytes: size(children(sdk, "resources"))),
                     ChatPart(kind: .cache, bytes: size([sdk.appending(path: "log"), root.appending(path: "CodeCache"),
                                                         root.appending(path: "GrShaderCache"), root.appending(path: "GraphiteDawnCache"),
                                                         root.appending(path: "ShaderCache")]))]
        } else {
            let profiles = documents.appending(path: "Profiles")
            parts = [ChatPart(kind: .media, bytes: size(children(profiles, "Caches"))),
                     // Only what 小清 cleans. The resource packs (Publishsys) come back by downloading them again,
                     // so they are not counted here and stay under 其他.
                     ChatPart(kind: .cache, bytes: size([root.appending(path: "Library/Caches"), root.appending(path: "Library/WebKit"),
                                                         documents.appending(path: "cefcache"), documents.appending(path: "GYLog"),
                                                         documents.appending(path: "GYOssLog"),
                                                         root.appending(path: "Library/Application Support/WXWork/Log")])),
                     ChatPart(kind: .drive, bytes: size([root.appending(path: "WeDrive")]))]
        }
        let known = parts.reduce(Int64(0)) { $0 + $1.bytes }
        parts.append(ChatPart(kind: .other, bytes: max(total - known, 0)))
        return parts.filter { $0.bytes > 0 }
    }

    private func allocatedSize(of root: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard !Task.isCancelled else { break }
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    private func isMovable(_ url: URL) -> Bool {
        access(url.path, W_OK) == 0 && access(url.deletingLastPathComponent().path, W_OK) == 0
    }
}

/// 安装包对应的 App 已经装好了吗：按文件名的词和已装 App 的名字比（WeChatMac_4.0.dmg → WeChat，
/// notion-calendar.dmg 不算 Notion）。只用来写说明，删不删仍由用户确认
enum InstallerMatch {
    private static let noise: Set<String> = ["mac", "macos", "osx", "darwin", "installer", "install", "setup", "universal",
                                             "arm64", "aarch64", "x64", "x86", "amd64", "intel", "applesilicon", "latest", "release", "dmg", "pkg"]

    private static let installed: [String: String] = {
        var names: [String: String] = [:]
        let roots = ["/Applications", NSHomeDirectory() + "/Applications"].map { URL(fileURLWithPath: $0) }
        for root in roots {
            for entry in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                let apps = entry.pathExtension == "app" ? [entry]
                    : ((try? FileManager.default.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "app" }
                for app in apps {
                    let name = app.deletingPathExtension().lastPathComponent
                    let key = normalize(name)
                    if key.count >= 3 { names[key] = name }
                }
            }
        }
        return names
    }()

    static func installedApp(for file: URL) -> String? {
        let words = words(file.deletingPathExtension().lastPathComponent)
        guard !words.isEmpty else { return nil }
        // 去掉末尾的 "mac" 一类（WeChatMac）后也比一次
        let joined = words.joined()
        let trimmed = noise.sorted { $0.count > $1.count }.first { joined.hasSuffix($0) && joined.count > $0.count + 2 }
            .map { String(joined.dropLast($0.count)) }
        return installed[joined] ?? trimmed.flatMap { installed[$0] }
    }

    /// 字母开头的词，遇到版本号停；去掉 mac、arm64 这类
    private static func words(_ stem: String) -> [String] {
        var out: [String] = []
        for part in stem.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            if part.first?.isNumber == true { break }
            let word = String(part)
            if !noise.contains(word) { out.append(word) }
        }
        return out
    }

    private static func normalize(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

enum ScanError: LocalizedError {
    case invalidRoot
    case unreadable(URL)

    var errorDescription: String? {
        switch self {
        case .invalidRoot: "请选择一个本地文件夹。"
        case .unreadable(let url): "无法读取：\(url.path)"
        }
    }
}
