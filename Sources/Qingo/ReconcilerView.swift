import AppKit
import SwiftUI

@MainActor
final class ReconcilerStore: ObservableObject {
    @Published var isPresented = false
    @Published private(set) var report: StorageReconciler.Report?
    @Published private(set) var isScanning = false
    @Published private(set) var isProbingAdmin = false
    @Published private(set) var activeTaskLabel: String?
    @Published private(set) var activeFindingID: String?
    @Published private(set) var message: String?
    @Published var pendingFinding: StorageReconciler.Finding?

    func clearMessage() {
        message = nil
    }

    let policy: SafetyPolicy
    private let onChanged: () -> Void

    init(policy: SafetyPolicy, onChanged: @escaping () -> Void = {}) {
        self.policy = policy
        self.onChanged = onChanged
    }

    var findingCount: Int { report?.findings.count ?? 0 }
    var totalFindingBytes: Int64 { report?.totalBytes ?? 0 }

    /// Only findings large enough (≥ 500 MB) or local snapshots deserve an overview banner.
    /// Tiny leftovers (e.g., 4 KB dead plists) stay quiet inside the detail sheet without alarming the user.
    var majorFindings: [StorageReconciler.Finding] {
        (report?.findings ?? []).filter { $0.bytes >= 500_000_000 || $0.kind == .localSnapshots }
    }
    var majorFindingBytes: Int64 {
        majorFindings.reduce(0) { $0 + $1.bytes }
    }

    func open() {
        isPresented = true
        if report == nil && !isScanning {
            refreshUserBlackHoles()
        }
    }

    private struct CachedAdminProbe: Codable {
        let probedAt: Date
        let spotlightBytes: Int64
        let systemLogsBytes: Int64
        let systemCachesBytes: Int64
    }

    private static let cachedAdminProbeKey = "qingo.reconciler.cachedAdminProbe"
    private static let cachedAdminProbeTTL: TimeInterval = 7 * 86_400

    private static func loadCachedAdminProbe(now: Date = Date()) -> CachedAdminProbe? {
        guard let data = UserDefaults.standard.data(forKey: cachedAdminProbeKey),
              let cached = try? JSONDecoder().decode(CachedAdminProbe.self, from: data),
              now.timeIntervalSince(cached.probedAt) < cachedAdminProbeTTL else {
            return nil
        }
        return cached
    }

    private static func saveCachedAdminProbe(_ probe: SpotlightRepairService.AdminProbeSizes, now: Date = Date()) {
        let cached = CachedAdminProbe(
            probedAt: now,
            spotlightBytes: probe.spotlightBytes,
            systemLogsBytes: probe.systemLogsBytes,
            systemCachesBytes: probe.systemCachesBytes
        )
        if let data = try? JSONEncoder().encode(cached) {
            UserDefaults.standard.set(data, forKey: cachedAdminProbeKey)
        }
    }

    func applyScannedReport(_ scanned: StorageReconciler.Report) {
        let aerial = scanned.findings.first(where: { $0.kind == .aerialWallpapers })?.bytes ?? 0
        let reconciler = StorageReconciler(policy: policy)
        if let prev = report, prev.adminProbed,
           let sp = prev.systemSpotlightBytes, let lg = prev.systemLogsBytes, let cc = prev.systemCachesBytes {
            let probe = SpotlightRepairService.AdminProbeSizes(
                spotlightBytes: sp, systemLogsBytes: lg, systemCachesBytes: cc, aerialWallpapersBytes: aerial
            )
            report = reconciler.mergeAdminProbe(probe, into: scanned)
        } else if let cached = Self.loadCachedAdminProbe() {
            let probe = SpotlightRepairService.AdminProbeSizes(
                spotlightBytes: cached.spotlightBytes,
                systemLogsBytes: cached.systemLogsBytes,
                systemCachesBytes: cached.systemCachesBytes,
                aerialWallpapersBytes: aerial
            )
            report = reconciler.mergeAdminProbe(probe, into: scanned)
        } else {
            report = scanned
        }
    }

    func refreshUserBlackHoles() {
        guard !isScanning else { return }
        isScanning = true
        message = nil
        let reconciler = StorageReconciler(policy: policy)
        Task.detached(priority: .utility) { [weak self] in
            let scanned = reconciler.scanUserBlackHoles()
            await MainActor.run {
                guard let self else { return }
                self.isScanning = false
                let aerial = scanned.findings.first(where: { $0.kind == .aerialWallpapers })?.bytes ?? 0
                // Preserve prior admin probe results from this session OR persisted 7-day cache so we never nag for password.
                if let prev = self.report, prev.adminProbed,
                   let sp = prev.systemSpotlightBytes, let lg = prev.systemLogsBytes, let cc = prev.systemCachesBytes {
                    let probe = SpotlightRepairService.AdminProbeSizes(
                        spotlightBytes: sp, systemLogsBytes: lg, systemCachesBytes: cc, aerialWallpapersBytes: aerial
                    )
                    self.report = reconciler.mergeAdminProbe(probe, into: scanned)
                } else if let cached = Self.loadCachedAdminProbe() {
                    let probe = SpotlightRepairService.AdminProbeSizes(
                        spotlightBytes: cached.spotlightBytes,
                        systemLogsBytes: cached.systemLogsBytes,
                        systemCachesBytes: cached.systemCachesBytes,
                        aerialWallpapersBytes: aerial
                    )
                    self.report = reconciler.mergeAdminProbe(probe, into: scanned)
                } else {
                    self.report = scanned
                }
            }
        }
    }

    /// DaisyDisk-style on-demand single-prompt administrator probe of root-protected black holes.
    func probeAdminHiddenSpace() {
        guard !isProbingAdmin, activeTaskLabel == nil else { return }
        isProbingAdmin = true
        message = nil
        let reconciler = StorageReconciler(policy: policy)
        let base = report ?? reconciler.scanUserBlackHoles()
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let probe = try SpotlightRepairService().probeSystemBlackHoles()
                let merged = reconciler.mergeAdminProbe(probe, into: base)
                await MainActor.run {
                    guard let self else { return }
                    self.isProbingAdmin = false
                    self.report = merged
                    Self.saveCachedAdminProbe(probe)
                    self.message = "已完成系统隐藏空间核查（7 天内免重复授权）：聚焦搜索索引 \(ByteFormat.string(probe.spotlightBytes))，系统日志 \(ByteFormat.string(probe.systemLogsBytes))，系统缓存 \(ByteFormat.string(probe.systemCachesBytes))。"
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isProbingAdmin = false
                    self.message = (error as? LocalizedError)?.errorDescription ?? "未获得管理员授权，已取消系统隐藏占用核查。"
                }
            }
        }
    }

    func runQuickMaintenance() {
        guard activeTaskLabel == nil else { return }
        activeTaskLabel = "正在执行系统维护…"
        message = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            let summary = SpotlightRepairService.runQuickSystemMaintenance()
            await MainActor.run {
                guard let self else { return }
                self.activeTaskLabel = nil
                self.message = summary
            }
        }
    }

    func executeConfirmed(_ finding: StorageReconciler.Finding) {
        pendingFinding = nil
        if case .probeAdmin = finding.action {
            probeAdminHiddenSpace()
            return
        }
        guard activeTaskLabel == nil else { return }
        activeFindingID = finding.id
        switch finding.action {
        case .emptyTrash: activeTaskLabel = "正在清空废纸篓…"
        case .rebuildSpotlight: activeTaskLabel = "正在重建聚焦搜索索引…"
        case .cleanAerialWallpapers: activeTaskLabel = "正在清理 4K 动态壁纸缓存…"
        case .thinSnapshots: activeTaskLabel = "正在释放时间机器本地快照…"
        case .evictCloudFiles: activeTaskLabel = "正在释放 iCloud 本机副本…"
        case .trashURLs: activeTaskLabel = "正在将项目移到废纸篓…"
        case .probeAdmin: activeTaskLabel = "正在核查深层系统目录…"
        }
        message = nil
        let reconciler = StorageReconciler(policy: policy)
        let home = policy.home
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcomeMessage: String
            switch finding.action {
            case .trashURLs(let urls):
                var moved = 0
                var failed = 0
                var movedLog: [(URL, Int64)] = []
                for url in urls {
                    guard CanonicalPath.isDirect(url), FileManager.default.fileExists(atPath: url.path) else { continue }
                    let size = FastSizeCalculator.allocatedBytes(of: url)
                    var resulting: NSURL?
                    do {
                        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                        moved += 1
                        movedLog.append((url, size))
                    } catch {
                        failed += 1
                    }
                }
                if !movedLog.isEmpty {
                    CleanupLog.record("存储黑洞清理", moved: movedLog, failedCount: failed)
                }
                outcomeMessage = failed == 0
                    ? "已将 \(moved) 项移到废纸篓（可在访达清空废纸篓释放空间）。"
                    : "已移到废纸篓 \(moved) 项，\(failed) 项未能移动。"

            case .rebuildSpotlight:
                do {
                    try SpotlightRepairService().rebuildSpotlightIndex()
                    outcomeMessage = "已触发 macOS 聚焦搜索索引安全重建。旧的损坏索引已清除，系统将在后台自动重建干净索引。"
                } catch {
                    outcomeMessage = (error as? LocalizedError)?.errorDescription ?? "重建聚焦搜索索引已取消或失败。"
                }

            case .cleanAerialWallpapers:
                do {
                    try SpotlightRepairService().cleanAerialWallpaperCache()
                    outcomeMessage = "已清理系统 4K 航拍动态壁纸缓存视频。"
                } catch {
                    outcomeMessage = (error as? LocalizedError)?.errorDescription ?? "清理航拍壁纸缓存已取消或失败。"
                }

            case .thinSnapshots(let confirmed, let targetBytes):
                do {
                    let result = try TimeMachineSnapshots().thin(confirmed: confirmed, targetBytes: targetBytes)
                    outcomeMessage = result.removed > 0
                        ? "已释放 \(result.removed) 份时间机器本地快照。"
                        : "系统未移除本地快照，可能当前空间已被系统回收或暂不可释放。"
                } catch {
                    outcomeMessage = (error as? LocalizedError)?.errorDescription ?? "释放本地快照失败。"
                }

            case .evictCloudFiles(let urls):
                var evicted = 0
                var pending = 0
                var failed = 0
                for url in urls {
                    do {
                        let identity = try CloudDownloads.candidate(url)
                        if try CloudDownloads.evict(url, identity: identity) {
                            evicted += 1
                        } else {
                            pending += 1
                        }
                    } catch {
                        failed += 1
                    }
                }
                if failed == 0 && pending == 0 {
                    outcomeMessage = "已移除 \(evicted) 个 iCloud 文件的本机副本（云端完整保留）。"
                } else {
                    var parts: [String] = []
                    if evicted > 0 { parts.append("已释放 \(evicted) 个") }
                    if pending > 0 { parts.append("系统后台处理中 \(pending) 个") }
                    if failed > 0 { parts.append("跳过 \(failed) 个") }
                    outcomeMessage = "iCloud 本机副本：" + parts.joined(separator: "，") + "。"
                }

            case .emptyTrash:
                let purge = TrashService.emptyUserTrash(home: home)
                if purge.purgedCount > 0 {
                    CleanupLog.record("清空废纸篓", moved: [], failedCount: purge.failedCount,
                                      disposition: .emptiedTrash, summaryCount: purge.purgedCount, summaryBytes: purge.purgedBytes)
                    outcomeMessage = "已清空废纸篓，释放约 \(ByteFormat.string(purge.purgedBytes)) 空间。"
                } else {
                    outcomeMessage = purge.failedCount > 0 ? "部分废纸篓项目未能清除（可能正被占用）。" : "废纸篓已为空。"
                }

            case .probeAdmin:
                outcomeMessage = ""
            }

            let refreshed = reconciler.scanUserBlackHoles()
            await MainActor.run {
                guard let self else { return }
                self.activeTaskLabel = nil
                self.activeFindingID = nil
                let aerial = refreshed.findings.first(where: { $0.kind == .aerialWallpapers })?.bytes ?? 0
                if let cached = Self.loadCachedAdminProbe() {
                    let probe = SpotlightRepairService.AdminProbeSizes(
                        spotlightBytes: cached.spotlightBytes,
                        systemLogsBytes: cached.systemLogsBytes,
                        systemCachesBytes: cached.systemCachesBytes,
                        aerialWallpapersBytes: aerial
                    )
                    self.report = reconciler.mergeAdminProbe(probe, into: refreshed)
                } else {
                    self.report = refreshed
                }
                self.message = outcomeMessage
                self.onChanged()
            }
        }
    }

    static func confirmDetail(for finding: StorageReconciler.Finding) -> String {
        switch finding.action {
        case .rebuildSpotlight:
            return "将通过 macOS 官方命令清除当前聚焦搜索（Spotlight）索引并重新建立。重建期间搜索结果会短暂不全，完成后可彻底收回异常膨胀的空间。"
        case .cleanAerialWallpapers:
            return "将删除系统下载的 4K 航拍动态壁纸缓存视频（约 \(ByteFormat.string(finding.bytes))）。如需使用动态壁纸，macOS 会按需重新下载。"
        case .thinSnapshots(_, let target):
            return "将请求 macOS 释放最多 \(ByteFormat.string(target)) 的时间机器本地快照。不影响外接备份硬盘。"
        case .evictCloudFiles(let urls):
            return "将移除 \(urls.count) 个已同步 iCloud 文件的本机副本（约 \(ByteFormat.string(finding.bytes))），云端文件完整保留，下次打开时自动下载。"
        case .trashURLs(let urls):
            return "将把这 \(urls.count) 项（约 \(ByteFormat.string(finding.bytes))）移到废纸篓，可随时恢复。"
        case .emptyTrash:
            return "将永久清空废纸篓中的所有项目（约 \(ByteFormat.string(finding.bytes))），操作不可恢复，请确认其中没有需要保留的文件。"
        case .probeAdmin:
            return "将请求一次管理员密码，以只读方式核查聚焦搜索索引（.Spotlight-V100）、系统日志与系统缓存目录。"
        }
    }
}

struct ReconcilerSummaryBar: View {
    @ObservedObject var reconciler: ReconcilerStore
    let lowFreeSpace: Bool
    let onOpen: () -> Void

    var body: some View {
        let major = reconciler.majorFindings
        let bytes = reconciler.majorFindingBytes
        if !major.isEmpty || lowFreeSpace {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    IconTile(symbol: !major.isEmpty ? "exclamationmark.triangle.fill" : "magnifyingglass",
                             tint: !major.isEmpty ? Theme.amber : Theme.blue, size: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        if !major.isEmpty {
                            let sizePart = bytes > 0 ? "（约 \(ByteFormat.string(bytes))）" : ""
                            Text("发现 \(major.count) 项系统隐藏占用\(sizePart)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                            Text("聚焦搜索索引、异常日志、动态壁纸、本地快照或闲置模型")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.ink2)
                                .lineLimit(1)
                        } else {
                            Text("排查系统隐藏占用")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                            Text("检查聚焦搜索索引、系统日志、动态壁纸与本地快照")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.ink2)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.ink3)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .glass(radius: 12)
            }
            .buttonStyle(.plain)
        }
    }
}

/// Inline hidden-space reconciliation section embedded inside 「空间 › 系统释放」 (zero modal sheet!).
struct ReconcilerInlineSection: View {
    @ObservedObject var store: ReconcilerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconTile(symbol: "lock.shield.fill", tint: Theme.blue, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    if let report = store.report, report.adminProbed {
                        Text("已完成系统深层占用核查")
                            .font(.system(size: 13.5, weight: .semibold))
                        Text("聚焦搜索索引：\(ByteFormat.string(report.systemSpotlightBytes ?? 0))   系统日志：\(ByteFormat.string(report.systemLogsBytes ?? 0))   系统缓存：\(ByteFormat.string(report.systemCachesBytes ?? 0))")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ink2)
                            .monospacedDigit()
                    } else {
                        Text("系统深层占用（聚焦搜索索引、系统日志与动态壁纸）")
                            .font(.system(size: 13.5, weight: .semibold))
                        Text("需要输入一次管理员密码。发现异常膨胀后可当场安全修复，不影响个人文件。")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ink2)
                    }
                }
                Spacer(minLength: 10)
                Button(store.isProbingAdmin ? "正在核查…" : (store.report?.adminProbed == true ? "重新核查" : "授权核查")) {
                    store.probeAdminHiddenSpace()
                }
                .buttonStyle(ToolbarButtonStyle(tinted: true))
                .disabled(store.isProbingAdmin || store.activeTaskLabel != nil)
            }

            if store.isScanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在排查隐藏占用…").font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                }
                .padding(.vertical, 6)
            } else if let findings = store.report?.findings, !findings.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(findings) { item in
                        HStack(spacing: 12) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 15))
                                .foregroundStyle(item.bytes >= 100_000_000 ? Theme.amber : Theme.blue)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 8) {
                                    Text(item.title).font(.system(size: 13.5, weight: .semibold))
                                    if item.bytes > 0 {
                                        Text(ByteFormat.string(item.bytes))
                                            .font(.system(size: 12.5, weight: .bold))
                                            .foregroundStyle(item.bytes >= 100_000_000 ? Theme.amber : Theme.ink2)
                                            .monospacedDigit()
                                    }
                                }
                                Text(item.subtitle)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.ink2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 10)
                            Button(item.actionLabel) {
                                store.pendingFinding = item
                            }
                            .buttonStyle(ToolbarButtonStyle(tinted: true))
                            .disabled(store.activeTaskLabel != nil || store.isProbingAdmin)
                        }
                        .padding(11)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fill(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
                    }
                }
            } else {
                Text("当前用户目录未发现明显的异常日志、动态壁纸或闲置模型。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.ink2)
            }

            HStack(spacing: 10) {
                Button("刷新检测", action: store.refreshUserBlackHoles)
                    .buttonStyle(ToolbarButtonStyle(tinted: false))
                    .disabled(store.isScanning || store.activeTaskLabel != nil)
                Button("系统轻维护（缩略图 / DNS / 打开方式）", action: store.runQuickMaintenance)
                    .buttonStyle(ToolbarButtonStyle(tinted: false))
                    .disabled(store.activeTaskLabel != nil || store.isProbingAdmin)
                Spacer()
                if let label = store.activeTaskLabel {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(label).font(.system(size: 12)).foregroundStyle(Theme.ink2)
                    }
                }
            }

            if let message = store.message {
                Text(message).font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
            }
        }
        .padding(16)
        .glass(radius: 14)
        .alert(store.pendingFinding?.actionLabel ?? "", isPresented: Binding(
            get: { store.pendingFinding != nil },
            set: { if !$0 { store.pendingFinding = nil } }
        ), presenting: store.pendingFinding) { finding in
            Button("取消", role: .cancel) {}
            Button(finding.actionLabel, role: .destructive) { store.executeConfirmed(finding) }
        } message: { finding in
            Text(ReconcilerStore.confirmDetail(for: finding))
        }
    }
}

struct ReconcilerSheet: View {
    @ObservedObject var store: ReconcilerStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                IconTile(symbol: "magnifyingglass", tint: Theme.blue, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("系统隐藏占用").font(.system(size: 19, weight: .bold))
                    Text("排查聚焦搜索索引、异常日志、动态壁纸、本地快照与闲置模型。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Button("完成") {
                    store.isPresented = false
                    dismiss()
                }
                .buttonStyle(ToolbarButtonStyle(tinted: true))
                .disabled(store.activeTaskLabel != nil || store.isProbingAdmin)
            }

            // Single-prompt Administrator Deep Check Card
            HStack(spacing: 12) {
                IconTile(symbol: "lock.shield.fill", tint: Theme.blue, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    if let report = store.report, report.adminProbed {
                        Text("已完成系统深层占用核查")
                            .font(.system(size: 13, weight: .semibold))
                        Text("聚焦搜索索引：\(ByteFormat.string(report.systemSpotlightBytes ?? 0))   系统日志：\(ByteFormat.string(report.systemLogsBytes ?? 0))   系统缓存：\(ByteFormat.string(report.systemCachesBytes ?? 0))")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ink2)
                            .monospacedDigit()
                    } else {
                        Text("核查系统深层占用（聚焦搜索索引、系统日志与动态壁纸）")
                            .font(.system(size: 13, weight: .semibold))
                        Text("需要输入一次管理员密码。发现异常占用后可当场清理，不影响个人文件。")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ink2)
                    }
                }
                Spacer()
                Button(store.isProbingAdmin ? "正在核查…" : (store.report?.adminProbed == true ? "重新核查" : "授权核查")) {
                    store.probeAdminHiddenSpace()
                }
                .buttonStyle(ToolbarButtonStyle(tinted: true))
                .disabled(store.isProbingAdmin || store.activeTaskLabel != nil)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.fill(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.line))

            // Findings List
            if store.isScanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在排查隐藏占用…").foregroundStyle(Theme.ink2)
                }
                .frame(maxWidth: .infinity, minHeight: 200, alignment: .center)
            } else if let findings = store.report?.findings, !findings.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(findings) { item in
                            HStack(spacing: 12) {
                                Image(systemName: item.symbol)
                                    .font(.system(size: 15))
                                    .foregroundStyle(item.kind == .spotlightIndex || item.kind == .runawayLogs ? Theme.amber : Theme.blue)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 8) {
                                        Text(item.title).font(.system(size: 13.5, weight: .semibold))
                                        if item.bytes > 0 {
                                            Text(ByteFormat.string(item.bytes))
                                                .font(.system(size: 12.5, weight: .bold))
                                                .foregroundStyle(item.bytes >= 100_000_000 ? Theme.amber : Theme.ink2)
                                                .monospacedDigit()
                                        }
                                    }
                                    Text(item.subtitle)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.ink2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                Button(item.actionLabel) {
                                    store.pendingFinding = item
                                }
                                .buttonStyle(ToolbarButtonStyle(tinted: true))
                                .disabled(store.activeTaskLabel != nil || store.isProbingAdmin)
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fill(0.05)))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
                        }
                    }
                }
                .frame(height: 240)
            } else {
                VStack(spacing: 6) {
                    Text("当前用户目录未发现明显的隐藏占用。")
                        .font(.system(size: 13.5, weight: .medium))
                    Text("如果可用空间仍然紧张，可点击上方「授权核查」检查聚焦搜索索引和系统日志。")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ink2)
                }
                .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
            }

            // Bottom Quick Actions
            HStack(spacing: 10) {
                Button("刷新扫描", action: store.refreshUserBlackHoles)
                    .buttonStyle(ToolbarButtonStyle(tinted: true))
                    .disabled(store.isScanning || store.activeTaskLabel != nil)
                Button("系统维护（缩略图 / DNS / 打开方式）", action: store.runQuickMaintenance)
                    .buttonStyle(ToolbarButtonStyle(tinted: false))
                    .disabled(store.activeTaskLabel != nil || store.isProbingAdmin)
                Spacer()
                if let label = store.activeTaskLabel {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(label).font(.system(size: 12)).foregroundStyle(Theme.ink2)
                    }
                }
            }

            if let message = store.message {
                Text(message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(width: 740)
        .interactiveDismissDisabled(store.activeTaskLabel != nil || store.isProbingAdmin)
        .alert(store.pendingFinding?.actionLabel ?? "", isPresented: Binding(
            get: { store.pendingFinding != nil },
            set: { if !$0 { store.pendingFinding = nil } }
        ), presenting: store.pendingFinding) { finding in
            Button("取消", role: .cancel) {}
            Button(finding.actionLabel, role: .destructive) { store.executeConfirmed(finding) }
        } message: { finding in
            Text(ReconcilerStore.confirmDetail(for: finding))
        }
    }
}
