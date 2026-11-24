import Foundation

/// Storage Reconciliation ("硬盘对账法") & macOS Eight Storage Black Holes detector.
///
/// Instead of only checking a small list of caches, reconciles real APFS volume usage against visible directories
/// and actively hunts the 8 biggest hidden space hogs on macOS:
/// 1. Spotlight / CoreSpotlight runaway index bloat (30–170 GB)
/// 2. Runaway / looping application log files (> 100 MB per log or app log folder)
/// 3. Downloaded 4K Aerial Wallpaper videos (5–25 GB, never auto-deleted)
/// 4. APFS Time Machine local snapshots (10–100 GB locked in System Data)
/// 5. Mail Downloads attachments
/// 6. Stale local AI models untouched > 45 days (Ollama / Hugging Face / LM Studio / Whisper)
/// 7. Stale synced iCloud local copies untouched > 30 days (safe evict, cloud kept)
/// 8. Orphaned LaunchAgents whose target binary no longer exists
struct StorageReconciler: Sendable {
    enum BlackHoleKind: String, Codable, Sendable {
        case spotlightIndex
        case coreSpotlight
        case runawayLogs
        case aerialWallpapers
        case localSnapshots
        case mailDownloads
        case staleModels
        case staleCloudFiles
        case orphanLaunchAgents
        case trashBloat
        case unaccountedGap
    }

    enum RepairAction: Equatable, Sendable {
        case trashURLs([URL])
        case rebuildSpotlight
        case cleanAerialWallpapers
        case thinSnapshots(Set<String>, targetBytes: Int64)
        case evictCloudFiles([URL])
        case emptyTrash
        case probeAdmin
    }

    struct Finding: Identifiable, Equatable, Sendable {
        let id: String
        let kind: BlackHoleKind
        let title: String
        let subtitle: String
        let bytes: Int64
        let symbol: String
        let actionLabel: String
        let action: RepairAction
        let requiresAdmin: Bool
    }

    struct Report: Equatable, Sendable {
        let scannedAt: Date
        let findings: [Finding]
        let adminProbed: Bool
        let systemSpotlightBytes: Int64?
        let systemLogsBytes: Int64?
        let systemCachesBytes: Int64?

        var totalBytes: Int64 {
            findings.reduce(0) { sum, item in
                let add = sum.addingReportingOverflow(item.bytes)
                return add.overflow ? Int64.max : add.partialValue
            }
        }
    }

    let home: URL
    let policy: SafetyPolicy
    /// Threshold for flagging a single log file or app log folder as runaway bloat.
    let runawayLogMinBytes: Int64
    /// Age threshold (days) for stale AI models.
    let staleModelDays: Int
    /// Age threshold (days) for stale synced iCloud local files.
    let staleCloudDays: Int
    /// Size threshold for stale iCloud local files.
    let staleCloudMinBytes: Int64

    init(policy: SafetyPolicy = SafetyPolicy(),
         runawayLogMinBytes: Int64 = 100_000_000,
         staleModelDays: Int = 45,
         staleCloudDays: Int = 30,
         staleCloudMinBytes: Int64 = 50_000_000) {
        self.home = policy.home
        self.policy = policy
        self.runawayLogMinBytes = runawayLogMinBytes
        self.staleModelDays = staleModelDays
        self.staleCloudDays = staleCloudDays
        self.staleCloudMinBytes = staleCloudMinBytes
    }

    /// Fast, zero-password scan of all user-accessible storage black holes.
    func scanUserBlackHoles(includeSystemAerial: Bool = true, includeSnapshots: Bool = true, includeTrash: Bool = true) -> Report {
        var findings: [Finding] = []
        findings.append(contentsOf: detectCoreSpotlight())
        findings.append(contentsOf: detectRunawayLogs())
        if includeSystemAerial && !AppHome.isDemo {
            findings.append(contentsOf: detectAerialWallpapers())
        }
        if includeSnapshots && !AppHome.isDemo {
            findings.append(contentsOf: detectLocalSnapshots())
        }
        findings.append(contentsOf: detectMailDownloads())
        findings.append(contentsOf: detectStaleModels())
        findings.append(contentsOf: detectStaleCloudFiles())
        findings.append(contentsOf: detectOrphanLaunchAgents())
        if includeTrash && !AppHome.isDemo {
            findings.append(contentsOf: detectTrashBloat())
        }
        findings.sort { $0.bytes > $1.bytes }
        return Report(scannedAt: Date(), findings: findings, adminProbed: false,
                      systemSpotlightBytes: nil, systemLogsBytes: nil, systemCachesBytes: nil)
    }

    func detectTrashBloat(minBytes: Int64 = 200_000_000) -> [Finding] {
        let bytes = TrashService.trashOccupancyBytes(home: home)
        guard bytes >= minBytes else { return [] }
        return [Finding(
            id: "trash-bloat",
            kind: .trashBloat,
            title: "废纸篓中仍有已删除文件未清空",
            subtitle: "移到废纸篓的文件仍占用物理磁盘空间。确认不需要后清空即可立即释放。",
            bytes: bytes,
            symbol: "trash.fill",
            actionLabel: "清空废纸篓",
            action: .emptyTrash,
            requiresAdmin: false
        )]
    }

    /// Compares actual APFS volume usage against visible accounted folders to flag large hidden system hogs (≥ 25 GB).
    static func apfsUnaccountedGapFinding(spaceMap: SpaceMap, cleanableBytes: Int64, adminProbed: Bool) -> Finding? {
        guard !adminProbed else { return nil }
        let gap = spaceMap.remainder(cleanable: cleanableBytes)
        guard gap >= 25_000_000_000 else { return nil }
        return Finding(
            id: "apfs-unaccounted-gap",
            kind: .unaccountedGap,
            title: "存在系统隐藏空间偏大（约 \(ByteFormat.string(gap))）",
            subtitle: "整盘已用空间比可见目录多出约 \(ByteFormat.string(gap))，常见原因为系统搜索索引、日志或本地快照（只需输入一次管理员密码即可核查，7 天内免重复授权）。",
            bytes: gap,
            symbol: "lock.shield.fill",
            actionLabel: "授权核查",
            action: .probeAdmin,
            requiresAdmin: true
        )
    }

    /// Merges results from DaisyDisk-style single-prompt admin probe into an existing report.
    func mergeAdminProbe(_ probe: SpotlightRepairService.AdminProbeSizes, into report: Report) -> Report {
        var findings = report.findings.filter { $0.kind != .spotlightIndex }
        // Flag Spotlight index if > 3 GB (normal index on a 500GB–1TB Mac is typically 0.3–2 GB).
        if probe.spotlightBytes >= 3_000_000_000 {
            findings.append(Finding(
                id: "spotlight-v100",
                kind: .spotlightIndex,
                title: "聚焦搜索（Spotlight）索引异常膨胀",
                subtitle: "系统隐藏索引已占用 \(ByteFormat.string(probe.spotlightBytes))，通常由高频小文件导致损坏膨胀。重建后可恢复正常体积。",
                bytes: probe.spotlightBytes,
                symbol: "magnifyingglass.circle.fill",
                actionLabel: "安全重建索引",
                action: .rebuildSpotlight,
                requiresAdmin: true
            ))
        }
        // If aerial wallpapers weren't readable without admin, surface from admin probe.
        if !findings.contains(where: { $0.kind == .aerialWallpapers }), probe.aerialWallpapersBytes >= 200_000_000 {
            findings.append(Finding(
                id: "aerial-wallpapers",
                kind: .aerialWallpapers,
                title: "系统 4K 航拍动态壁纸缓存",
                subtitle: "切换壁纸后旧的 4K 视频不会自动删除，清理后如需使用系统会自动重新下载。",
                bytes: probe.aerialWallpapersBytes,
                symbol: "photo.tv",
                actionLabel: "清理壁纸缓存",
                action: .cleanAerialWallpapers,
                requiresAdmin: true
            ))
        }
        findings.sort { $0.bytes > $1.bytes }
        return Report(
            scannedAt: Date(),
            findings: findings,
            adminProbed: true,
            systemSpotlightBytes: probe.spotlightBytes,
            systemLogsBytes: probe.systemLogsBytes,
            systemCachesBytes: probe.systemCachesBytes
        )
    }

    // MARK: - Individual Black Hole Detectors

    func detectCoreSpotlight() -> [Finding] {
        let dir = home.appending(path: "Library/Metadata/CoreSpotlight")
        guard CanonicalPath.isDirect(dir), FileManager.default.fileExists(atPath: dir.path) else { return [] }
        let bytes = FastSizeCalculator.allocatedBytes(of: dir)
        guard bytes >= 200_000_000 else { return [] }
        let children = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { CanonicalPath.isDirect($0) }
        guard !children.isEmpty else { return [] }
        return [Finding(
            id: "core-spotlight",
            kind: .coreSpotlight,
            title: "应用搜索元数据索引过大",
            subtitle: "CoreSpotlight 索引缓存，移到废纸篓后系统会在后台自动重新建立干净索引。",
            bytes: bytes,
            symbol: "magnifyingglass",
            actionLabel: "清理索引缓存",
            action: .trashURLs(children),
            requiresAdmin: false
        )]
    }

    func detectRunawayLogs() -> [Finding] {
        let logsRoot = home.appending(path: "Library/Logs")
        guard CanonicalPath.isDirect(logsRoot),
              let entries = try? FileManager.default.contentsOfDirectory(at: logsRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }
        var results: [Finding] = []
        for entry in entries where CanonicalPath.isDirect(entry) && !policy.isProtected(entry) {
            let name = entry.lastPathComponent
            // Skip DiagnosticReports (already handled individually by DiagnosticJunk for >30d) unless truly huge (>500MB).
            let bytes = FastSizeCalculator.allocatedBytes(of: entry)
            let threshold: Int64 = name == "DiagnosticReports" ? 500_000_000 : runawayLogMinBytes
            guard bytes >= threshold else { continue }
            results.append(Finding(
                id: "runaway-log-\(entry.path)",
                kind: .runawayLogs,
                title: "异常暴涨日志：\(name)",
                subtitle: "单个应用日志超过 \(ByteFormat.string(threshold))，可能存在后台反复报错或日志未自动轮转，可安全移到废纸篓。",
                bytes: bytes,
                symbol: "doc.text.magnifyingglass",
                actionLabel: "清理日志",
                action: .trashURLs([entry]),
                requiresAdmin: false
            ))
        }
        return results
    }

    func detectAerialWallpapers(root: URL = URL(fileURLWithPath: "/Library/Application Support/com.apple.idleassetsd/Customer")) -> [Finding] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let bytes = FastSizeCalculator.allocatedBytes(of: root)
        guard bytes >= 200_000_000 else { return [] }
        return [Finding(
            id: "aerial-wallpapers",
            kind: .aerialWallpapers,
            title: "系统 4K 航拍动态壁纸缓存",
            subtitle: "macOS 下载的高清动态壁纸视频，切换回静态壁纸后不会自动删除，可安全清理。",
            bytes: bytes,
            symbol: "photo.tv",
            actionLabel: "清理壁纸缓存",
            action: .cleanAerialWallpapers,
            requiresAdmin: true
        )]
    }

    func detectLocalSnapshots() -> [Finding] {
        guard let snapshots = try? TimeMachineSnapshots().list(), !snapshots.isEmpty else { return [] }
        return [Finding(
            id: "tm-local-snapshots",
            kind: .localSnapshots,
            title: "时间机器本地快照（\(snapshots.count) 份）",
            subtitle: "隐藏在「系统数据」中的本地快照，可能会锁住已删除大文件的磁盘空间。释放不影响外接备份盘。",
            bytes: 0,
            symbol: "clock.arrow.circlepath",
            actionLabel: "释放快照空间",
            action: .thinSnapshots(snapshots, targetBytes: 50_000_000_000),
            requiresAdmin: false
        )]
    }

    func detectMailDownloads() -> [Finding] {
        let dir = home.appending(path: "Library/Containers/com.apple.mail/Data/Library/Mail Downloads")
        guard CanonicalPath.isDirect(dir), FileManager.default.fileExists(atPath: dir.path) else { return [] }
        let bytes = FastSizeCalculator.allocatedBytes(of: dir)
        guard bytes >= 50_000_000 else { return [] }
        let children = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { CanonicalPath.isDirect($0) }
        guard !children.isEmpty else { return [] }
        return [Finding(
            id: "mail-downloads",
            kind: .mailDownloads,
            title: "邮件附件本地副本",
            subtitle: "在苹果「邮件」中打开过的附件缓存，清理后仍可从邮件服务器重新下载。",
            bytes: bytes,
            symbol: "paperclip",
            actionLabel: "清理附件副本",
            action: .trashURLs(children),
            requiresAdmin: false
        )]
    }

    func detectStaleModels(now: Date = Date()) -> [Finding] {
        let cutoff = now.addingTimeInterval(-Double(staleModelDays) * 86_400)
        var candidates: [(name: String, url: URL, bytes: Int64, daysOld: Int)] = []

        // 1. Hugging Face Hub models
        let hfHub = home.appending(path: ".cache/huggingface/hub")
        if let entries = try? FileManager.default.contentsOfDirectory(at: hfHub, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for entry in entries where entry.lastPathComponent.hasPrefix("models--") && CanonicalPath.isDirect(entry) {
                if let item = checkStaleModelDir(entry, displayName: entry.lastPathComponent.dropFirst("models--".count).replacingOccurrences(of: "--", with: "/"), cutoff: cutoff, now: now) {
                    candidates.append(item)
                }
            }
        }

        // 2. LM Studio models (two levels deep: org/model)
        for rel in [".lmstudio/models", ".cache/lm-studio/models"] {
            let root = home.appending(path: rel)
            for org in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
                for model in (try? FileManager.default.contentsOfDirectory(at: org, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
                where CanonicalPath.isDirect(model) {
                    if let item = checkStaleModelDir(model, displayName: "\(org.lastPathComponent)/\(model.lastPathComponent)", cutoff: cutoff, now: now) {
                        candidates.append(item)
                    }
                }
            }
        }

        // 3. Whisper cache files
        let whisper = home.appending(path: ".cache/whisper")
        for file in (try? FileManager.default.contentsOfDirectory(at: whisper, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        where CanonicalPath.isDirect(file) {
            if let item = checkStaleModelDir(file, displayName: "Whisper · \(file.lastPathComponent)", cutoff: cutoff, now: now) {
                candidates.append(item)
            }
        }

        guard !candidates.isEmpty else { return [] }
        let total = candidates.reduce(Int64(0)) { $0 + $1.bytes }
        let previewNames = candidates.sorted { $0.bytes > $1.bytes }.prefix(3).map(\.name).joined(separator: "、")
        let suffix = candidates.count > 3 ? " 等" : ""
        return [Finding(
            id: "stale-ai-models",
            kind: .staleModels,
            title: "长期未使用的本地 AI 模型（\(candidates.count) 个）",
            subtitle: "\(previewNames)\(suffix) 均超过 \(staleModelDays) 天未改动。移到废纸篓后如需使用可重新下载。",
            bytes: total,
            symbol: "cpu",
            actionLabel: "移到废纸篓",
            action: .trashURLs(candidates.map(\.url)),
            requiresAdmin: false
        )]
    }

    private func checkStaleModelDir(_ url: URL, displayName: String, cutoff: Date, now: Date) -> (name: String, url: URL, bytes: Int64, daysOld: Int)? {
        guard let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .contentAccessDateKey]) else { return nil }
        let latest = max(vals.contentModificationDate ?? .distantPast, vals.contentAccessDate ?? .distantPast)
        guard latest < cutoff else { return nil }
        let bytes = FastSizeCalculator.allocatedBytes(of: url)
        guard bytes >= 500_000_000 else { return nil }
        let days = max(staleModelDays, Int(now.timeIntervalSince(latest) / 86_400))
        return (displayName, url, bytes, days)
    }

    func detectStaleCloudFiles(now: Date = Date()) -> [Finding] {
        let root = home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs")
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let cutoff = now.addingTimeInterval(-Double(staleCloudDays) * 86_400)
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey, .ubiquitousItemHasUnresolvedConflictsKey,
            .ubiquitousItemIsDownloadingKey, .ubiquitousItemUploadingErrorKey, .ubiquitousItemDownloadingErrorKey,
            .totalFileAllocatedSizeKey, .contentModificationDateKey, .contentAccessDateKey
        ]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }) else {
            return []
        }
        var stale: [(url: URL, bytes: Int64)] = []
        var visited = 0
        for case let file as URL in enumerator {
            visited += 1
            if visited > 15_000 { break }
            guard let vals = try? file.resourceValues(forKeys: Set(keys)), CloudDownloads.canEvict(vals) else { continue }
            let size = Int64(vals.totalFileAllocatedSize ?? 0)
            guard size >= staleCloudMinBytes else { continue }
            let latest = max(vals.contentModificationDate ?? .distantPast, vals.contentAccessDate ?? .distantPast)
            guard latest < cutoff else { continue }
            stale.append((file, size))
        }
        guard !stale.isEmpty else { return [] }
        let total = stale.reduce(Int64(0)) { $0 + $1.bytes }
        return [Finding(
            id: "stale-icloud-files",
            kind: .staleCloudFiles,
            title: "iCloud 长期未访问的本机大文件（\(stale.count) 个）",
            subtitle: "均已同步到云端且超过 \(staleCloudDays) 天未使用。仅移除本机占用，云端文件完整保留。",
            bytes: total,
            symbol: "icloud.and.arrow.down",
            actionLabel: "释放本机空间",
            action: .evictCloudFiles(stale.map(\.url)),
            requiresAdmin: false
        )]
    }

    func detectOrphanLaunchAgents() -> [Finding] {
        let dir = home.appending(path: "Library/LaunchAgents")
        guard CanonicalPath.isDirect(dir),
              let plists = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }
        var orphans: [(label: String, url: URL, bytes: Int64)] = []
        for url in plists where url.pathExtension == "plist" && CanonicalPath.isDirect(url) {
            guard let dict = NSDictionary(contentsOf: url) as? [String: Any],
                  let label = dict["Label"] as? String else { continue }
            if label.hasPrefix("com.apple.") || label.hasPrefix("io.github.chenmozhe008.qingo") { continue }
            let executablePath: String?
            if let prog = dict["Program"] as? String {
                executablePath = prog
            } else if let args = dict["ProgramArguments"] as? [String], let first = args.first {
                executablePath = first
            } else {
                executablePath = nil
            }
            guard let exec = executablePath, exec.hasPrefix("/") else { continue }
            // Only flag as orphan when the target program path clearly no longer exists on disk.
            if !FileManager.default.fileExists(atPath: exec) {
                let bytes = FastSizeCalculator.allocatedBytes(of: url)
                orphans.append((label, url, bytes))
            }
        }
        guard !orphans.isEmpty else { return [] }
        let names = orphans.prefix(3).map(\.label).joined(separator: "、")
        let suffix = orphans.count > 3 ? " 等" : ""
        return [Finding(
            id: "orphan-launch-agents",
            kind: .orphanLaunchAgents,
            title: "已卸载应用的孤立后台启动项（\(orphans.count) 项）",
            subtitle: "\(names)\(suffix) 指向的程序已不存在，但登录启动配置仍在后台反复尝试拉起。",
            bytes: max(orphans.reduce(0) { $0 + $1.bytes }, 4096),
            symbol: "bolt.slash.circle",
            actionLabel: "清理孤立启动项",
            action: .trashURLs(orphans.map(\.url)),
            requiresAdmin: false
        )]
    }
}
