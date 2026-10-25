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
        let total = try walk(root, root: root, rootDevice: rootDevice, depth: 0, insideProject: false, items: &items, skipped: &skipped, scanned: &scanned, onProgress: onProgress)
        items.sort { $0.bytes > $1.bytes }
        let filesystem = try? FileManager.default.attributesOfFileSystem(forPath: root.path)
        let volumeTotal = (filesystem?[.systemSize] as? NSNumber)?.int64Value
        let volumeFree = (filesystem?[.systemFreeSize] as? NSNumber)?.int64Value
        return ScanResult(root: root, isQuickScan: false, items: items, totalBytes: total, volumeTotalBytes: volumeTotal, volumeFreeBytes: volumeFree, skippedCount: skipped, scannedCount: scanned, scannedAt: Date())
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
            let bytes = try walk(location, root: root, rootDevice: rootDevice, depth: 1, insideProject: false, items: &items, skipped: &skipped, scanned: &scanned, onProgress: onProgress)
            let addition = total.addingReportingOverflow(bytes)
            total = addition.overflow ? Int64.max : addition.partialValue
        }
        items.sort { $0.bytes > $1.bytes }
        let filesystem = try? FileManager.default.attributesOfFileSystem(forPath: root.path)
        return ScanResult(root: root, isQuickScan: true, items: items, totalBytes: total,
                          volumeTotalBytes: (filesystem?[.systemSize] as? NSNumber)?.int64Value,
                          volumeFreeBytes: (filesystem?[.systemFreeSize] as? NSNumber)?.int64Value,
                          skippedCount: skipped, scannedCount: scanned, scannedAt: Date())
    }

    private func walk(_ url: URL, root: URL, rootDevice: UInt64, depth: Int, insideProject: Bool, items: inout [ScanItem], skipped: inout Int, scanned: inout Int, onProgress: @Sendable (ScanProgress) -> Void) throws -> Int64 {
        try Task<Never, Never>.checkCancellation()
        scanned += 1
        if scanned.isMultiple(of: 200) {
            onProgress(ScanProgress(scannedCount: scanned, currentFolder: url.deletingLastPathComponent().path))
        }
        guard let metadata = try? metadata(url) else { skipped += 1; return 0 }
        if metadata.identity.device != rootDevice || metadata.isLink { skipped += 1; return 0 }
        let allowedProtectedChildren = policy.allowedChildren(ofProtectedRoot: url)
        if policy.isProtected(url), allowedProtectedChildren == nil {
            skipped += 1
            return 0
        }

        if !metadata.isDirectory {
            if policy.isProject(url), !insideProject, url != root, metadata.size >= minProjectBytes {
                emit(&items, item(url, kind: .project, bytes: metadata.size, note: "项目文件，仅显示大小。", canTrash: false, identity: metadata.identity, modified: metadata.modified))
            } else if !insideProject, url != root,
                      metadata.size >= largeFileThreshold || (metadata.size >= 100_000_000 && ["dmg", "pkg"].contains(url.pathExtension.lowercased())) {
                let installer = ["dmg", "pkg"].contains(url.pathExtension.lowercased())
                let note = installer ? "安装包，删除前请确认不再需要。" : "大文件，删除前请确认不再需要。"
                emit(&items, item(url, kind: .largeFile, bytes: metadata.size, note: note, canTrash: false, identity: metadata.identity, modified: metadata.modified))
            }
            return metadata.size
        }

        let reviewNote = policy.reviewDescription(for: url, isDirectory: true)
        let project = reviewNote == nil && policy.isProject(url)
        // Skip caches we could not move anyway (root-owned or system-protected), so they never reach the cleanup list.
        // A recognized tool's own caches stay cleanable inside its otherwise read-only folder.
        let toolCache = !policy.isProtected(url) && CreativeApp.cacheNote(url, home: policy.home) != nil
        let cacheNote = (!insideProject || toolCache) && isMovable(url) ? policy.cacheDescription(for: url, isDirectory: true) : nil
        let children: [URL]
        if let allowedProtectedChildren {
            children = allowedProtectedChildren.filter { FileManager.default.fileExists(atPath: $0.path) }
            skipped += 1
        } else {
            do {
                children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
            } catch {
                skipped += 1
                return 0
            }
        }
        var sum: Int64 = 0
        for child in children {
            let value = try walk(child, root: root, rootDevice: rootDevice, depth: depth + 1, insideProject: insideProject || project || reviewNote != nil, items: &items, skipped: &skipped, scanned: &scanned, onProgress: onProgress)
            let addition = sum.addingReportingOverflow(value)
            sum = addition.overflow ? Int64.max : addition.partialValue
        }
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
                    if remaining >= (tool ? minToolDataBytes : minReviewBytes) || CreativeApp.isReviewCache(url) {
                        items.removeAll { !ownRow($0) && $0.url.path.hasPrefix(prefix) }
                        emit(&items, item(url, kind: .review, bytes: remaining, note: reviewNote, canTrash: false, identity: metadata.identity, modified: metadata.modified))
                    }
                }
            } else if let cacheNote, sum > 0 {
                // Hide descendants of a suggested cache to avoid overlapping actions.
                items.removeAll { $0.url.path.hasPrefix(url.path + "/") }
                emit(&items, item(url, kind: .cache, bytes: sum, note: cacheNote, canTrash: true, identity: metadata.identity, modified: metadata.modified))
            }
        }
        return sum
    }

    private func item(_ url: URL, kind: ScanKind, bytes: Int64, note: String, canTrash: Bool, identity: FileIdentity, modified: Date) -> ScanItem {
        ScanItem(id: url, url: url, kind: kind, risk: policy.risk(for: url, kind: kind), bytes: bytes, note: note, canTrash: canTrash,
                 identity: identity, modified: modified)
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

    private func metadata(_ url: URL) throws -> (identity: FileIdentity, isDirectory: Bool, isLink: Bool, size: Int64, modified: Date) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw ScanError.unreadable(url) }
        let type = info.st_mode & mode_t(S_IFMT)
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        return (FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino)), type == mode_t(S_IFDIR), type == mode_t(S_IFLNK), max(0, info.st_size), modified)
    }

    private func identity(_ url: URL) throws -> FileIdentity { try metadata(url).identity }

    private func emit(_ items: inout [ScanItem], _ item: ScanItem) {
        items.append(item)
        onFound?(item)
    }

    /// Read-only size of chat apps' data. These folders stay protected; this only measures them.
    func chatAppUsage() -> [ChatAppUsage] {
        let apps = [("com.tencent.xinWeChat", "微信"), ("com.tencent.WeWorkMac", "企业微信")]
        let home = policy.home
        let groupRoot = home.appending(path: "Library/Group Containers")
        let groups = (try? FileManager.default.contentsOfDirectory(atPath: groupRoot.path)) ?? []
        return apps.compactMap { bundleID, name in
            var roots = [home.appending(path: "Library/Containers/\(bundleID)")]
            roots += groups.filter { $0.hasSuffix(".\(bundleID)") }.map { groupRoot.appending(path: $0) }
            roots = roots.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !roots.isEmpty else { return nil }
            var total: Int64 = 0
            for root in roots {
                // A protected container lists as unreadable without Full Disk Access.
                guard (try? FileManager.default.contentsOfDirectory(atPath: root.path)) != nil else {
                    return ChatAppUsage(id: bundleID, name: name, bytes: nil)
                }
                total += allocatedSize(of: root)
            }
            return ChatAppUsage(id: bundleID, name: name, bytes: total, parts: chatParts(bundleID, total: total))
        }
    }

    /// Splits a chat app's data by what its folders hold (WeChat 4 / WeCom layouts, measured 2026-10-25).
    /// Folders that are not there count as zero; whatever is not matched is "other".
    private func chatParts(_ bundleID: String, total: Int64) -> [ChatPart] {
        let data = policy.home.appending(path: "Library/Containers/\(bundleID)/Data")
        let documents = data.appending(path: "Documents")
        func size(_ urls: [URL]) -> Int64 { urls.reduce(0) { $0 + allocatedSize(of: $1) } }
        func children(_ url: URL, _ name: String) -> [URL] {
            ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []).map { $0.appending(path: name) }
        }
        var parts: [ChatPart] = []
        if bundleID == "com.tencent.xinWeChat" {
            let accounts = documents.appending(path: "xwechat_files")
            parts = [ChatPart(kind: .media, bytes: size(children(accounts, "msg"))),
                     ChatPart(kind: .records, bytes: size(children(accounts, "db_storage"))),
                     ChatPart(kind: .cache, bytes: size([documents.appending(path: "app_data"), data.appending(path: ".wxapplet"),
                                                         data.appending(path: "Library/Caches")]))]
        } else {
            let profiles = documents.appending(path: "Profiles")
            parts = [ChatPart(kind: .media, bytes: size(children(profiles, "Caches"))),
                     ChatPart(kind: .cache, bytes: size([documents.appending(path: "cefcache"), data.appending(path: "Library/Caches"),
                                                         data.appending(path: "Library/Application Support/WXWork/Log")] + children(profiles, "Publishsys"))),
                     ChatPart(kind: .drive, bytes: size([data.appending(path: "WeDrive")]))]
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
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    private func isMovable(_ url: URL) -> Bool {
        access(url.path, W_OK) == 0 && access(url.deletingLastPathComponent().path, W_OK) == 0
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
