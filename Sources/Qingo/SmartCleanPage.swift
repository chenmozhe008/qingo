import AppKit
import SwiftUI

/// Page 1: Spacious, focused 「智能清理」 primary stage.
/// Features a prominent scan/release hero beside the live SpaceRing and at most 3 single-line ≥100 MB findings below.
struct SmartCleanPage: View {
    @ObservedObject var store: ScanStore

    var body: some View {
        if store.isScanning {
            SmartScanningView(store: store)
        } else if store.isCleaning {
            SmartCleaningView(store: store)
        } else if store.showingSmartCleanDetail, let result = store.result {
            UnifiedCleanListView(store: store, result: result)
        } else if let result = store.result {
            SmartCleanHomeView(store: store, result: result)
        } else {
            SmartCleanEmptyView(store: store)
        }
    }
}

// MARK: - 1. Scanning View (Dual-Column Ring + Live Discovery Feed)

struct SmartScanningView: View {
    @ObservedObject var store: ScanStore

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 740
            let cacheBytes = store.liveCacheBytes
            let creativeBytes = store.liveCreativeBytes
            let largeBytes = store.liveLargeBytes
            let totalLive = cacheBytes + creativeBytes + largeBytes
            let ringSize: CGFloat = compact ? 208 : 268

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Label(store.progress.stage ?? store.scanningTitle, systemImage: "sparkles")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Theme.blue)
                        Spacer()
                        Text(calmPlaceLabel(store.progress.currentFolder))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ink3)
                            .lineLimit(1)
                    }

                    if compact {
                        VStack(spacing: 22) {
                            scanningLeft(ringSize: ringSize, totalLive: totalLive)
                            scanningRight
                        }
                    } else {
                        HStack(alignment: .center, spacing: 36) {
                            scanningLeft(ringSize: ringSize, totalLive: totalLive)
                                .frame(width: 320)
                            scanningRight
                                .frame(maxWidth: .infinity)
                        }
                        .frame(maxWidth: 1020)
                    }
                }
                .frame(maxWidth: 1020)
                .padding(.horizontal, compact ? 24 : 38)
                .padding(.top, 24)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
    }

    private func scanningLeft(ringSize: CGFloat, totalLive: Int64) -> some View {
        VStack(spacing: 0) {
            ZStack {
                ScanningRing()
                    .frame(width: ringSize, height: ringSize)
                VStack(spacing: 4) {
                    if totalLive > 0 {
                        Text("已发现可释放空间")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Theme.blue)
                        Text(ByteFormat.string(totalLive))
                            .font(.system(size: ringSize < 220 ? 26 : 33, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("已检查 \(store.progress.scannedCount.formatted()) 项")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ink2)
                            .monospacedDigit()
                    } else {
                        Text(store.progress.scannedCount.formatted())
                            .font(.system(size: ringSize < 220 ? 26 : 33, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("已检查项目")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.ink2)
                    }
                }
            }

            Text(store.scanningTitle)
                .font(.system(size: 18, weight: .bold))
                .padding(.top, 16)

            Text("扫描过程不会修改任何文件")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink2)
                .padding(.top, 6)

            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                ScanProgressBar(fraction: store.estimatedProgress, fill: Theme.accent, glow: Theme.cyan)
                    .frame(width: 260, height: 6)
            }
            .padding(.top, 14)

            Button { store.cancelScan() } label: {
                Label("停止扫描", systemImage: "stop.circle.fill")
            }
            .buttonStyle(ToolbarButtonStyle(tinted: true))
            .keyboardShortcut(.cancelAction)
            .padding(.top, 20)
        }
    }

    private var scanningRight: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Card 1: Multi-module live checklist (always structured and full!)
            VStack(alignment: .leading, spacing: 8) {
                Text("体检模块实时进度")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.ink2)
                    .padding(.horizontal, 4)

                VStack(spacing: 0) {
                    ForEach(Array(store.scanModules.enumerated()), id: \.element.id) { idx, module in
                        if idx > 0 { InsetHairlineDivider(leading: 48) }
                        moduleRow(module)
                    }
                }
                .appleGroupedCard(radius: 16)
            }

            // Card 2: Compact recent discoveries (no oversized empty void)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("实时发现的大项（≥ 5 MB）")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.ink2)
                    Spacer()
                    if store.liveNotableCount > 0 {
                        Text("已命中 \(store.liveNotableCount) 项")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.ink3)
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 4)

                VStack(spacing: 0) {
                    if store.liveRecentItems.isEmpty {
                        HStack(spacing: 10) {
                            Image(systemName: "sparkle.magnifyingglass")
                                .font(.system(size: 18))
                                .foregroundStyle(Theme.ink3)
                            Text("正在检索大体积缓存、工程构建与安装包…")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.ink2)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 58)
                    } else {
                        ForEach(Array(store.liveRecentItems.prefix(4).enumerated()), id: \.element.id) { index, item in
                            if index > 0 { InsetHairlineDivider(leading: 52) }
                            liveFeedRow(item)
                        }
                    }
                }
                .appleGroupedCard(radius: 14)
            }
        }
    }

    private func moduleRow(_ module: ScanModuleProgress) -> some View {
        HStack(spacing: 12) {
            Group {
                switch module.status {
                case .waiting:
                    Image(systemName: "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.ink3.opacity(0.6))
                case .running:
                    ProgressView().controlSize(.small)
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.green)
                }
            }
            .frame(width: 20, height: 20)

            IconTile(symbol: module.symbol, tint: moduleTint(module), size: 24)

            Text(module.title)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(isWaiting(module.status) ? Theme.ink2 : Theme.ink)
                .lineLimit(1)

            Spacer(minLength: 10)

            switch module.status {
            case .waiting:
                Text("等待检查")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink3)
            case .running(let detail):
                Text(detail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.blue)
                    .lineLimit(1)
            case .done(let summary, let accent):
                Text(summary)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent ? Theme.blue : Theme.ink2)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func isWaiting(_ status: ScanModuleProgress.Status) -> Bool {
        if case .waiting = status { return true }
        return false
    }

    private func moduleTint(_ module: ScanModuleProgress) -> Color {
        switch module.status {
        case .waiting: Theme.slate
        case .running: Theme.blue
        case .done(_, let accent): accent ? Theme.blue : Theme.green
        }
    }

    private func liveFeedRow(_ item: ScanItem) -> some View {
        let info = ItemPresentation.info(for: item)
        let tag: (String, Color) = switch item.kind {
        case .cache: ("应用缓存", Theme.blue)
        case .review: ("创作 / AI", Theme.indigo)
        case .largeFile, .project, .folder: ("大文件", Theme.amber)
        }
        return HStack(spacing: 12) {
            if let icon = info.icon {
                Image(nsImage: icon).resizable().frame(width: 28, height: 28)
            } else {
                IconTile(symbol: info.symbol, tint: tag.1, size: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(info.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                Text(item.note).font(.system(size: 11.5)).foregroundStyle(Theme.ink3).lineLimit(1)
            }
            Spacer(minLength: 8)
            ToolTag(text: tag.0, tint: tag.1)
            Text(ByteFormat.string(item.bytes))
                .font(.system(size: 13.5, weight: .bold))
                .monospacedDigit()
                .frame(minWidth: 68, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func liveSummaryTile(title: String, bytes: Int64, color: Color, placeholder: String = "扫描中…") -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).font(.system(size: 12)).foregroundStyle(Theme.ink2).lineLimit(1)
            }
            Text(bytes > 0 ? ByteFormat.string(bytes) : placeholder)
                .font(.system(size: bytes > 0 ? 18 : 15, weight: bytes > 0 ? .bold : .medium, design: .rounded))
                .foregroundStyle(bytes > 0 ? color : Theme.ink3)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glass(radius: 14)
    }

    private func calmPlaceLabel(_ rawPath: String) -> String {
        guard !rawPath.isEmpty else { return "准备就绪" }
        let short = ToolText.short(URL(fileURLWithPath: rawPath))
        let parts = short.split(separator: "/").prefix(3)
        return parts.isEmpty ? short : parts.joined(separator: "/")
    }
}

// MARK: - 1.5 Cleaning Progress View (Animated Live Cleanup Feedback)

struct SmartCleaningView: View {
    @ObservedObject var store: ScanStore

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 740
            let total = max(store.cleaningTotalCount, 1)
            let done = min(store.cleanedCount, total)
            let fraction = store.cleaningTotalCount > 0 ? max(0.06, Double(done) / Double(total)) : 0.15
            let percent = Int((Double(done) / Double(total)) * 100)
            let ringSize: CGFloat = compact ? 204 : 256

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    if compact {
                        VStack(spacing: 22) {
                            cleaningRing(ringSize: ringSize, percent: percent, done: done, total: total)
                            cleaningCard(fraction: fraction, done: done, total: total)
                        }
                    } else {
                        HStack(alignment: .center, spacing: 36) {
                            cleaningRing(ringSize: ringSize, percent: percent, done: done, total: total)
                                .frame(width: 300)
                            cleaningCard(fraction: fraction, done: done, total: total)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(maxWidth: 980)
                .padding(.horizontal, compact ? 24 : 38)
                .padding(.top, 24)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
    }

    private func cleaningRing(ringSize: CGFloat, percent: Int, done: Int, total: Int) -> some View {
        ZStack {
            ScanningRing()
                .frame(width: ringSize, height: ringSize)
            VStack(spacing: 4) {
                Text("\(percent)%")
                    .font(.system(size: ringSize < 220 ? 28 : 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("\(done) / \(total) 项已处理")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.ink2)
                    .monospacedDigit()
            }
        }
    }

    private func cleaningCard(fraction: Double, done: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                IconTile(symbol: "sparkles", tint: Theme.blue, size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text("正在清理所选项目")
                        .font(.system(size: 17, weight: .bold))
                    Text("请稍候，完成后将自动刷新磁盘可用空间")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.ink2)
                }
                Spacer(minLength: 8)
                Text("\(done)/\(total)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.blue)
                    .monospacedDigit()
            }

            GlowBar(fraction: fraction, fill: Theme.accent, glow: Theme.cyan)
                .frame(height: 8)

            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在处理：\(store.cleaningCurrentItem.isEmpty ? "准备清理队列…" : store.cleaningCurrentItem)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fill(0.05)))

            Text("纯缓存直接释放磁盘空间；构建缓存与软件残留移到废纸篓，需要时可随时恢复。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .appleGroupedCard(radius: 16)
    }
}

// MARK: - 2. Welcome Empty Launch State (Restored Brand Presence + Disk Cards)

struct SmartCleanEmptyView: View {
    @ObservedObject var store: ScanStore

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                Spacer(minLength: 34)
                SidebarBrandMark(size: 128)
                    .shadow(color: Theme.blue.opacity(0.35), radius: 24, y: 12)
                Text("查看并释放你的 Mac 空间")
                    .font(.system(size: 30, weight: .bold))
                    .padding(.top, 20)
                Text("先快速体检可安全重建的应用与 AI 缓存，再决定是否清理个人大文件与闲置工程。扫描过程不修改任何文件。")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                    .padding(.top, 8)

                HStack(spacing: 14) {
                    Button { store.scanKnownCaches() } label: {
                        Label("快速扫描（3–5 秒）", systemImage: "bolt.fill")
                    }
                    .buttonStyle(HeroButtonStyle())
                    .keyboardShortcut(.defaultAction)

                    Button { store.scanOverview() } label: {
                        Label("全盘深度体检", systemImage: "magnifyingglass.circle.fill")
                    }
                    .buttonStyle(ToolbarButtonStyle(tinted: false))
                }
                .padding(.top, 24)

                Spacer(minLength: 28)

                let volumes = [store.policy.home] + store.externalVolumes
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: 14) {
                    ForEach(volumes, id: \.self) { vol in
                        welcomeDiskCard(vol)
                    }
                }
                .frame(maxWidth: 860)
                .padding(.horizontal, 34)
                .padding(.bottom, 26)
            }
            .frame(maxWidth: .infinity, minHeight: 580)
        }
    }

    @ViewBuilder
    private func welcomeDiskCard(_ url: URL) -> some View {
        let isHome = url.path == store.policy.home.path
        let cap = store.volumeCapacity(for: url)
        let total = max(cap?.total ?? 0, 1)
        let free = cap?.free ?? 0
        let low = free < MainView.lowSpaceBytes
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label(isHome ? "Mac 内置盘" : url.lastPathComponent, systemImage: isHome ? "laptopcomputer" : "externaldrive.fill")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.ink2)
                if let cap, cap.total > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ByteFormat.string(free))
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(low ? Theme.amber : Theme.ink)
                            .monospacedDigit()
                        Text("可用 / 共 \(ByteFormat.string(total))")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ink3)
                    }
                    GlowBar(fraction: Double(total - free) / Double(total),
                            fill: low ? Theme.warning : Theme.accent, glow: low ? Theme.orange : Theme.cyan)
                        .frame(height: 6)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            Button(isHome ? "扫描" : "透视") {
                if isHome { store.scanOverview() }
                else {
                    store.spaceLens.showCategoryMap = false
                    store.navigate(to: .spaceLens)
                    store.spaceLens.navigate(to: url)
                }
            }
            .buttonStyle(ToolbarButtonStyle(tinted: isHome))
        }
        .padding(16)
        .glass(radius: 16)
    }
}

// MARK: - 3. Spacious Hero Home Stage

struct SmartCleanHomeView: View {
    @ObservedObject var store: ScanStore
    @ObservedObject private var reconciler: ReconcilerStore
    @ObservedObject private var storageTools: StorageToolsStore
    @ObservedObject private var dev: DevStore
    let result: ScanResult

    init(store: ScanStore, result: ScanResult) {
        self.store = store
        self.reconciler = store.reconciler
        self.storageTools = store.storageTools
        self.dev = store.dev
        self.result = result
    }

    private enum FindingAction {
        case reconciler(StorageReconciler.Finding)
        case cliTools
        case devIdle
        case orphans
        case reveal(URL)
        case trashScanItem(ScanItem)
        case openClutter
    }

    private struct CompactFinding: Identifiable {
        let id: String
        let title: String
        let bytes: Int64
        let symbol: String
        let tint: Color
        let actionLabel: String
        let prominentPill: Bool
        let action: FindingAction
    }

    var body: some View {
        GeometryReader { proxy in
            let narrow = proxy.size.width < 660
            let compact = proxy.size.width < 760
            let margin: CGFloat = compact ? 24 : 36
            let safe = store.eligibleItems

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    // Consistent Page Header (aligned flush with Hero Card, Zone 1 & Zone 2)
                    HStack(alignment: .center, spacing: 12) {
                        IconTile(symbol: "sparkles", tint: Theme.blue, size: 38)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text("智能体检")
                                    .font(.system(size: 21, weight: .bold))
                                Text(result.isQuickScan ? "快速扫描" : "全盘深度体检")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(result.isQuickScan ? Theme.blue : Theme.indigo)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2.5)
                                    .background(Capsule().fill((result.isQuickScan ? Theme.blue : Theme.indigo).opacity(0.12)))
                            }
                            Text("上次扫描：\(MainView.ago(result.scannedAt))，已检查 \(result.scannedCount.formatted()) 项")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.ink2)
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                        }
                        Spacer(minLength: 8)
                        Button { store.scanKnownCaches() } label: {
                            Label("快速扫描", systemImage: "bolt.fill")
                        }
                        .buttonStyle(ToolbarButtonStyle(tinted: !result.isQuickScan))
                        .disabled(store.isCleaning)
                        .help("仅扫描日常应用、浏览器与 AI 缓存（约 1–3 秒）")
                        Button { store.scanOverview() } label: {
                            Label("全盘深度体检", systemImage: "magnifyingglass.circle.fill")
                        }
                        .buttonStyle(ToolbarButtonStyle(prominent: result.isQuickScan, tinted: !result.isQuickScan))
                        .disabled(store.isCleaning)
                        .help("一次性深扫缓存、微信/创作、代码工程、全盘大文件、重复文件、卸载残留与系统快照")
                        if store.spaceGrowth != nil {
                            Button { store.showGrowth() } label: {
                                Label("空间变化", systemImage: "chart.line.uptrend.xyaxis")
                            }
                            .buttonStyle(ToolbarButtonStyle(tinted: false))
                        }
                        UpdateButton(checker: store.updates, busy: store.isCleaning)
                    }

                    statusBanners

                    // Hero Summary Card: Full-width balanced card flush with Zone 1 & Zone 2
                    let ringSize: CGFloat = compact ? 172 : 198
                    Group {
                        if narrow {
                            VStack(alignment: .leading, spacing: 20) {
                                heroRing(size: ringSize)
                                heroRight(compact: compact, safe: safe)
                            }
                        } else {
                            HStack(alignment: .center, spacing: compact ? 24 : 36) {
                                heroRing(size: ringSize)
                                heroRight(compact: compact, safe: safe)
                            }
                        }
                    }
                    .padding(compact ? 20 : 26)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .appleGroupedCard(radius: 18)

                    // Zone 1: One-Click Safe Junk Cleanup Checklist (inline categories + orphans)
                    if !safe.isEmpty || !store.safeOrphanGroups.isEmpty {
                        zoneOneSafeCleanup(safe: safe)
                    }

                    // Zone 2: Deep Health Check Discretionary Findings (Trash / Large+Dup / CLI+Snapshots / Chat+Models)
                    zoneTwoDeepRelease

                    // Quiet 1-line permission / deep-probe footer
                    overviewFooter
                }
                .frame(maxWidth: 980)
                .padding(.horizontal, margin)
                .padding(.top, 20)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            if store.reconciler.report == nil && !store.reconciler.isScanning {
                store.reconciler.refreshUserBlackHoles()
            }
            if store.storageTools.snapshots == nil { store.storageTools.refreshSnapshots() }
            if store.storageTools.cliProbes.isEmpty { store.storageTools.refreshCLIAdapters() }
        }
        // Attach each alert to its own background host so SwiftUI macOS never drops sibling alerts.
        .background {
            Color.clear
                .alert(reconciler.pendingFinding?.actionLabel ?? "", isPresented: Binding(
                    get: { reconciler.pendingFinding != nil },
                    set: { if !$0 { reconciler.pendingFinding = nil } }
                ), presenting: reconciler.pendingFinding) { finding in
                    Button("取消", role: .cancel) {}
                    Button(finding.actionLabel, role: .destructive) { reconciler.executeConfirmed(finding) }
                } message: { finding in
                    Text(ReconcilerStore.confirmDetail(for: finding))
                }
        }
        .background {
            Color.clear
                .alert(storageTools.confirmation?.action ?? "", isPresented: Binding(
                    get: { storageTools.confirmation != nil },
                    set: { if !$0 { storageTools.confirmation = nil } }
                ), presenting: storageTools.confirmation) { operation in
                    Button("取消", role: .cancel) {}
                    Button(operation.action, role: .destructive) { storageTools.confirm(operation) }
                } message: { operation in
                    Text(operation.detail)
                }
        }
        .background {
            Color.clear
                .alert("清理闲置开发构建缓存", isPresented: $store.confirmDevIdle) {
                    Button("取消", role: .cancel) {}
                    Button("移到废纸篓", role: .destructive) {
                        dev.purgeIdleArtifacts(olderThanDays: 14) {
                            store.refreshDisplayVolumes()
                        }
                    }
                } message: {
                    let projects = dev.idleProjects(olderThanDays: 14)
                    Text("将把 \(projects.count) 个超过 14 天未修改项目的构建产物（约 \(ByteFormat.string(dev.idleArtifactsBytes))）移到废纸篓，源代码保持不动。")
                }
        }
    }

    private func heroRing(size: CGFloat) -> some View {
        Button { store.navigate(to: .spaceLens) } label: {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                let live = store.volumeCapacity(for: result.root)
                let free = live?.free ?? result.volumeFreeBytes ?? 0
                let total = live?.total ?? result.volumeTotalBytes ?? 0
                SpaceRing(total: total, free: free, low: free < MainView.lowSpaceBytes)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("点击查看空间透视")
    }

    // MARK: Hero Right Column

    private func heroRight(compact: Bool, safe: [ScanItem]) -> some View {
        let selected = store.smartCleanTotalSelectedBytes
        let orphanGroups = store.safeOrphanGroups
        let hasAnythingSafe = !safe.isEmpty || !orphanGroups.isEmpty
        let liveFree = store.volumeCapacity(for: result.root)?.free ?? result.volumeFreeBytes ?? 0
        let lowSpace = liveFree > 0 && liveFree < MainView.lowSpaceBytes
        let cliBytes = storageTools.cliProbes.compactMap(\.estimatedBytes).reduce(Int64(0), +)
        let discretionaryBytes = (store.largeFileSummary?.bytes ?? 0) + cliBytes + (reconciler.report?.totalBytes ?? 0)

        return VStack(alignment: .leading, spacing: 0) {
            if !hasAnythingSafe {
                HStack(spacing: 6) {
                    Image(systemName: lowSpace ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                        .font(.system(size: 12))
                    Text(lowSpace ? "磁盘剩余空间较少" : "常规缓存已清理")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(lowSpace ? Theme.amber : Theme.green)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill((lowSpace ? Theme.amber : Theme.green).opacity(0.12)))

                Text(discretionaryBytes > 0
                     ? "另有 \(ByteFormat.string(discretionaryBytes)) 专项空间可按需释放"
                     : "当前没有可自动清理的缓存")
                    .font(.system(size: compact ? 20 : 23, weight: .bold))
                    .padding(.top, 10)

                Text("个人大文件、安装包、开发工具缓存与聊天记录不会自动删除，可在下方逐项处理。")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink2)
                    .padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)

                if !store.deferredBrowsers.isEmpty {
                    browserNoticeRow.padding(.top, 10)
                }

                HStack(spacing: 12) {
                    if result.isQuickScan {
                        Button { store.scanOverview() } label: {
                            Label("执行全盘深度体检", systemImage: "magnifyingglass.circle.fill")
                        }
                        .buttonStyle(HeroButtonStyle())
                        .disabled(store.isCleaning)

                        Button("查看空间透视") { store.navigate(to: .spaceLens) }
                            .buttonStyle(ToolbarButtonStyle(large: true, tinted: true))
                    } else if let large = store.largeFileSummary, large.bytes > 0 {
                        Button("整理大文件与安装包（\(ByteFormat.string(large.bytes))）") {
                            store.navigate(to: .clutter)
                        }
                        .buttonStyle(HeroButtonStyle())

                        Button("查看空间透视") { store.navigate(to: .spaceLens) }
                            .buttonStyle(ToolbarButtonStyle(large: true, tinted: true))
                    } else {
                        Button("查看空间透视") { store.navigate(to: .spaceLens) }
                            .buttonStyle(HeroButtonStyle())

                        Button("应用与系统维护") { store.navigate(to: .apps) }
                            .buttonStyle(ToolbarButtonStyle(large: true, tinted: true))
                    }
                }
                .padding(.top, 16)
            } else {
                Text("可安全清理")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.blue)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(Theme.blue.opacity(0.12)))

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    BigBytes(bytes: selected, size: compact ? 40 : 48)
                    if selected > 0 {
                        let countSummary = !orphanGroups.isEmpty && store.includeOrphansInSmartClean
                            ? "\(store.selectedCacheItems.count) 项缓存与 \(orphanGroups.count) 款残留"
                            : "\(store.selectedCacheItems.count) 项垃圾缓存"
                        Text(countSummary)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.ink2)
                            .monospacedDigit()
                    }
                }
                .padding(.top, 8)

                Text(selected > 0
                     ? "应用与浏览器缓存直接释放空间，项目构建缓存与卸载残留移到废纸篓可随时恢复。"
                     : "在下方勾选需要清理的分类，即可一键清理。")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink2)
                    .padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)

                if !store.deferredBrowsers.isEmpty {
                    browserNoticeRow.padding(.top, 10)
                }

                HStack(spacing: 12) {
                    Button { store.triggerSmartClean() } label: {
                        Text(selected > 0 ? "立即一键清理 \(ByteFormat.string(selected))" : "立即一键清理")
                    }
                    .buttonStyle(HeroButtonStyle())
                    .disabled(selected == 0 || store.isCleaning || store.uninstaller.isWorking)
                    .keyboardShortcut(.defaultAction)

                    Button("查看分类明细 ›") {
                        withAnimation(.easeOut(duration: 0.15)) { store.showingSmartCleanDetail = true }
                    }
                    .buttonStyle(ToolbarButtonStyle(large: true, tinted: true))
                }
                .padding(.top, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Zone 1 — Inline Safe Cleanup Categories

    private func zoneOneSafeCleanup(safe: [ScanItem]) -> some View {
        let grouped = JunkCategory.allCases.compactMap { category -> (category: JunkCategory, items: [ScanItem])? in
            let items = safe.filter { JunkCategory.classify($0, home: store.policy.home) == category }
            return items.isEmpty ? nil : (category, items)
        }
        let orphans = store.safeOrphanGroups
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("一键安全清理项（可在下方勾选或展开明细）")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink2)
                Spacer()
                Button("查看全部子项 ›") {
                    withAnimation(.easeOut(duration: 0.15)) { store.showingSmartCleanDetail = true }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.blue)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(grouped.enumerated()), id: \.element.category.id) { index, group in
                    if index > 0 { InsetHairlineDivider(leading: 54) }
                    let pickedItems = group.items.filter { store.isPicked($0.id) }
                    let allOn = pickedItems.count == group.items.count
                    let bytes = ScanStore.cleanupSum(group.items)
                    HStack(spacing: 12) {
                        ToolCheckbox(on: allOn)
                            .onTapGesture {
                                guard !store.isCleaning else { return }
                                let next = !allOn
                                for item in group.items {
                                    store.setCleanupSelected(item, selected: next)
                                }
                            }
                        IconTile(symbol: group.category.symbol, tint: group.category.tint, size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(group.category.title)
                                    .font(.system(size: 13.5, weight: .semibold))
                                Text("\(group.items.count) 项")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Theme.ink3)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Theme.fill(0.06)))
                            }
                            Text(group.category.plainSubtitle)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.ink2)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 10)
                        Text(ByteFormat.string(bytes))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(pickedItems.isEmpty ? Theme.ink3 : Theme.ink)
                            .monospacedDigit()
                        Button("明细 ›") {
                            store.expandedJunkCategories.insert(group.category.id)
                            withAnimation(.easeOut(duration: 0.15)) { store.showingSmartCleanDetail = true }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.blue)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }

                if !orphans.isEmpty {
                    if !grouped.isEmpty { InsetHairlineDivider(leading: 54) }
                    let orphanBytes = store.safeOrphanBytes
                    HStack(spacing: 12) {
                        ToolCheckbox(on: store.includeOrphansInSmartClean)
                            .onTapGesture {
                                guard !store.isCleaning else { return }
                                store.includeOrphansInSmartClean.toggle()
                            }
                        IconTile(symbol: "archivebox.fill", tint: Theme.orange, size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("已卸载应用遗留文件")
                                    .font(.system(size: 13.5, weight: .semibold))
                                Text("\(orphans.count) 款")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Theme.ink3)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Theme.fill(0.06)))
                            }
                            Text("对应软件已从「应用程序」删掉，这些资源库残留移到废纸篓后仍可恢复")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.ink2)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 10)
                        Text(ByteFormat.string(orphanBytes))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(store.includeOrphansInSmartClean ? Theme.ink : Theme.ink3)
                            .monospacedDigit()
                        Button("查看 ›") {
                            store.navigate(to: .apps)
                            store.appsSystemTab = .leftovers
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.blue)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }
            }
            .appleGroupedCard(radius: 14)
        }
    }

    // MARK: Zone 2 — Deep Health Check Discretionary Spaces

    private var zoneTwoDeepRelease: some View {
        let largeBytes = store.largeFileSummary?.bytes ?? 0
        let largeCount = store.largeFileSummary?.count ?? 0
        let dupGroups = store.storageTools.results?.groups.count ?? 0
        let cliProbes = store.storageTools.cliProbes
        let cliBytes = cliProbes.compactMap(\.estimatedBytes).reduce(Int64(0), +)
        let snapCount = store.storageTools.snapshots?.count ?? 0
        let chatBytes = result.chatApps.compactMap(\.bytes).reduce(0, +)
        let readOnlyAIBytes = store.shownItems.filter { item in
            guard item.kind == .review, !store.isDecidable(item), !CreativeApp.isReviewCache(item.url) else { return false }
            guard let app = CreativeApp.of(item) else { return false }
            return [.aiCode, .aiChat, .aiCreate, .localModel].contains(app.group)
        }.reduce(Int64(0)) { $0 + $1.bytes }

        let findings = reconcilerFindingsList
        let showLarge = largeCount > 0 || dupGroups > 0 || !result.isQuickScan
        let showCLIOrSnap = !cliProbes.isEmpty || snapCount > 0
        let showChatOrAI = chatBytes > 0 || readOnlyAIBytes > 0 || !result.chatApps.isEmpty

        return VStack(alignment: .leading, spacing: 8) {
            Text("深度体检专项释放（大文件、废纸篓、包管理器、本地快照与社交软件）")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.ink2)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                // 1) System / Reconciler Findings (Trash bloat, Spotlight index bloat, APFS gap)
                ForEach(Array(findings.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { InsetHairlineDivider(leading: 54) }
                    compactFindingRow(row)
                }

                // 2) Large files, Installers & Duplicates
                if showLarge {
                    let subtitle = [
                        largeCount > 0 ? "\(largeCount) 个大文件与安装包" : nil,
                        dupGroups > 0 ? "\(dupGroups) 组重复文件" : nil
                    ].compactMap { $0 }.joined(separator: "，")
                    zoneTwoNavigationRow(
                        leadingDivider: !findings.isEmpty,
                        symbol: "doc.on.doc.fill",
                        tint: Theme.violet,
                        title: "大文件、安装包与重复文件",
                        subtitle: subtitle.isEmpty ? "检查 100 MB 以上大文件、旧安装包与重复副本" : subtitle,
                        value: largeBytes > 0 ? ByteFormat.string(largeBytes) : "查看整理",
                        buttonTitle: "去勾选清理 ›"
                    ) {
                        store.navigate(to: .clutter)
                    }
                }

                // 3) CLI Package Managers & Time Machine Snapshots
                if showCLIOrSnap {
                    let sub = [
                        cliProbes.isEmpty ? nil : "检测到 \(cliProbes.count) 个开发工具（Homebrew / pnpm 等）",
                        snapCount > 0 ? "\(snapCount) 份时间机器本地快照" : nil
                    ].compactMap { $0 }.joined(separator: "，")
                    zoneTwoNavigationRow(
                        leadingDivider: !findings.isEmpty || showLarge,
                        symbol: "terminal.fill",
                        tint: Theme.amber,
                        title: "开发包管理器与系统本地快照",
                        subtitle: sub,
                        value: cliBytes > 0 ? ByteFormat.string(cliBytes) : (snapCount > 0 ? "\(snapCount) 份快照" : "可释放"),
                        buttonTitle: "前往释放 ›"
                    ) {
                        if !cliProbes.isEmpty {
                            store.navigate(to: .devMaintenance)
                            store.devMaintenanceTab = .cli
                        } else {
                            store.navigate(to: .apps)
                            store.appsSystemTab = .system
                        }
                    }
                }

                // 4) Chat Apps & Local LLM Models (Protected, Guide-Based)
                if showChatOrAI {
                    let total = chatBytes + readOnlyAIBytes
                    let subParts = [
                        chatBytes > 0 ? "微信/企微/飞书 \(ByteFormat.string(chatBytes))" : nil,
                        readOnlyAIBytes > 0 ? "AI 工具与本地模型 \(ByteFormat.string(readOnlyAIBytes))" : nil
                    ].compactMap { $0 }.joined(separator: "，")
                    zoneTwoNavigationRow(
                        leadingDivider: !findings.isEmpty || showLarge || showCLIOrSnap,
                        symbol: "message.fill",
                        tint: Theme.green,
                        title: "社交聊天记录与 AI 本地模型（只读）",
                        subtitle: subParts.isEmpty ? "查看微信、企业微信、飞书官方瘦身步骤与本地模型盘点" : subParts,
                        value: total > 0 ? ByteFormat.string(total) : "查看指引",
                        buttonTitle: chatBytes > 0 ? "查看指引 ›" : "去盘点 ›"
                    ) {
                        if chatBytes > 0 {
                            store.navigate(to: .chatAI)
                        } else {
                            store.navigate(to: .devMaintenance)
                            store.devMaintenanceTab = .ai
                        }
                    }
                }
            }
            .appleGroupedCard(radius: 14)
        }
    }

    private func zoneTwoNavigationRow(
        leadingDivider: Bool,
        symbol: String,
        tint: Color,
        title: String,
        subtitle: String,
        value: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 0) {
            if leadingDivider { InsetHairlineDivider(leading: 54) }
            HStack(spacing: 12) {
                IconTile(symbol: symbol, tint: tint, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Theme.ink2).lineLimit(1)
                }
                Spacer(minLength: 10)
                Text(value)
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .monospacedDigit()
                Button(buttonTitle, action: action)
                    .buttonStyle(ToolbarButtonStyle(tinted: false))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }

    private var reconcilerFindingsList: [CompactFinding] {
        var rows: [CompactFinding] = []
        let minShowBytes: Int64 = 200_000_000
        var findings = store.reconciler.report?.findings ?? []
        if let map = store.spaceMap,
           let gap = StorageReconciler.apfsUnaccountedGapFinding(
                spaceMap: map,
                cleanableBytes: ScanStore.cleanupSum(store.eligibleItems),
                adminProbed: store.reconciler.report?.adminProbed ?? false
           ) {
            findings.append(gap)
        }
        for item in findings where item.bytes >= minShowBytes || item.kind == .localSnapshots {
            let shortTitle: String
            switch item.kind {
            case .unaccountedGap: shortTitle = "系统隐藏空间偏大（搜索索引或系统日志）"
            case .spotlightIndex: shortTitle = "系统搜索索引（Spotlight）占用过大"
            case .trashBloat: shortTitle = "废纸篓尚有已删除文件未清空"
            default: shortTitle = item.title
            }
            rows.append(CompactFinding(
                id: "rec-\(item.id)",
                title: shortTitle,
                bytes: item.bytes,
                symbol: item.symbol,
                tint: item.kind == .unaccountedGap || item.kind == .spotlightIndex ? Theme.amber : Theme.green,
                actionLabel: item.actionLabel,
                prominentPill: item.kind == .unaccountedGap || item.kind == .spotlightIndex || item.kind == .trashBloat,
                action: .reconciler(item)
            ))
        }
        return rows.sorted { $0.bytes > $1.bytes }
    }

    private var overviewFooter: some View {
        HStack(spacing: 12) {
            Spacer()
            if !store.hasFullDiskAccess {
                Button {
                    store.openFullDiskAccessSettings()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "lock.fill").font(.system(size: 10.5))
                        Text("未开启完全磁盘访问权限，点击前往授权以解锁微信与 Safari 扫描 ›")
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink3)
            } else {
                let alreadyProbed = reconciler.report?.adminProbed == true
                Button(reconciler.isProbingAdmin
                       ? "正在核查深层系统目录…"
                       : (alreadyProbed ? "已完成深层系统核查（7 天内免重复授权），重新核查…" : "核查 /Library 深层系统目录（需管理员密码，7 天内仅需一次）…")) {
                    reconciler.probeAdminHiddenSpace()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink3)
                .disabled(reconciler.isProbingAdmin || reconciler.activeTaskLabel != nil)
            }
            Spacer()
        }
        .padding(.top, 4)
    }

    private var browserNoticeRow: some View {
        HStack(spacing: 10) {
            Text("退出运行中的浏览器可额外清理 \(ByteFormat.string(store.deferredBrowserBytes))")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.amber)
            Button(store.isQuittingBrowsers ? "正在退出…" : "退出并清理") {
                store.quitBlockedBrowsersAndClean()
            }
            .buttonStyle(ResultActionButtonStyle())
            .disabled(store.isQuittingBrowsers || store.isCleaning)
        }
    }

    // MARK: Status Banners (Shown Only During Active Events)

    @ViewBuilder
    private var statusBanners: some View {
        if let activeTask = reconciler.activeTaskLabel ?? (reconciler.isProbingAdmin ? "正在核查深层系统目录…" : nil) ?? storageTools.activity {
            HStack(spacing: 12) {
                IconTile(symbol: "arrow.triangle.2.circlepath", tint: Theme.blue, size: 24)
                Text(activeTask)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 10)
                ScanProgressBar(fraction: nil, fill: Theme.accent, glow: Theme.cyan)
                    .frame(width: 120, height: 5)
                ToolTag(text: "处理中", tint: Theme.blue)
            }
            .padding(12)
            .appleGroupedCard(radius: 12)
        } else if let alert = store.sentinelAlert {
            HStack(spacing: 10) {
                IconTile(symbol: "trash.fill", tint: Theme.amber, size: 22)
                Text("检测到「\(alert.appName)」已移到废纸篓，还有 \(alert.traceCount) 项残留（约 \(ByteFormat.string(alert.traceBytes))）。")
                    .font(.system(size: 12.5, weight: .medium))
                Spacer()
                Button("清理残留") { store.openSentinelOrphans() }
                    .buttonStyle(ResultActionButtonStyle())
                Button { store.sentinelAlert = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.ink3)
            }
            .padding(11)
            .appleGroupedCard(radius: 12)
        } else if let report = store.cleanupReport {
            HStack(spacing: 10) {
                let ok = report.totalClearedCount > 0
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(ok ? Theme.green : Theme.amber)
                if report.purgedCount > 0 && report.movedCount > 0 {
                    Text("已直接释放 \(ByteFormat.string(report.purgedBytes)) 缓存，并将 \(report.movedCount) 项（约 \(ByteFormat.string(report.movedBytes))）移到废纸篓")
                        .font(.system(size: 13, weight: .semibold))
                } else if report.purgedCount > 0 {
                    Text("已直接清理 \(report.purgedCount) 项缓存，立即释放 \(ByteFormat.string(report.purgedBytes)) 磁盘空间")
                        .font(.system(size: 13, weight: .semibold))
                } else if report.movedCount > 0 {
                    Text("已移到废纸篓 \(report.movedCount) 项（约 \(ByteFormat.string(report.movedBytes))）")
                        .font(.system(size: 13, weight: .semibold))
                } else {
                    Text("未能清理所选项目").font(.system(size: 13, weight: .semibold))
                }
                Spacer()
                if !store.undoable.isEmpty {
                    Button(store.isPurging ? "正在删除…" : "永久删除本次项目") { store.purgeLastTrashed() }
                        .buttonStyle(ResultActionButtonStyle())
                        .disabled(store.isRestoring || store.isPurging)
                    Button(store.isRestoring ? "正在恢复…" : "撤销") { store.undoLastCleanup() }
                        .buttonStyle(ToolbarButtonStyle(tinted: false))
                        .disabled(store.isRestoring || store.isPurging)
                }
                Button { store.cleanupReport = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.ink3)
            }
            .padding(11)
            .appleGroupedCard(radius: 12)
        } else if let msg = reconciler.message ?? storageTools.message ?? store.message {
            let isWarning = msg.contains("失败") || msg.contains("未能") || msg.contains("取消") || msg.contains("未获得")
            HStack(spacing: 10) {
                Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isWarning ? Theme.amber : Theme.green)
                Text(msg)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Button {
                    reconciler.clearMessage()
                    store.message = nil
                } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.ink3)
            }
            .padding(11)
            .appleGroupedCard(radius: 12)
        }
    }

    // MARK: Compact Row Builder

    private func compactFindingRow(_ row: CompactFinding) -> some View {
        HStack(spacing: 12) {
            IconTile(symbol: row.symbol, tint: row.tint, size: 24)
            Text(row.title)
                .font(.system(size: 13.5, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 10)
            if row.bytes > 0 {
                Text(ByteFormat.string(row.bytes))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(row.bytes >= 10_000_000_000 ? Theme.amber : Theme.ink)
                    .monospacedDigit()
            }
            if row.actionLabel == "整理 ›" {
                Button(row.actionLabel) { trigger(row.action) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.blue)
            } else {
                let rowBusy = row.id == "rec-\(reconciler.activeFindingID ?? "")"
                Button {
                    trigger(row.action)
                } label: {
                    if rowBusy {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("处理中…")
                        }
                    } else {
                        Text(row.actionLabel)
                    }
                }
                .buttonStyle(ToolbarButtonStyle(tinted: row.prominentPill))
                .disabled(reconciler.activeTaskLabel != nil || storageTools.activity != nil || store.isCleaning)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var cliToolsDrawer: some View {
        let probes = store.storageTools.cliProbes
        let ordered = probes.map(\.id).filter { store.storageTools.selectedCLIAdapters.contains($0) }
        return VStack(alignment: .leading, spacing: 6) {
            InsetHairlineDivider(leading: 48)
            ForEach(probes) { probe in
                let picked = store.storageTools.selectedCLIAdapters.contains(probe.id)
                HStack(spacing: 8) {
                    Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(picked ? Theme.blue : Theme.ink3)
                        .font(.system(size: 13.5))
                    Text(probe.id.title).font(.system(size: 12.5, weight: .medium))
                    Text(probe.summary).font(.system(size: 11.5)).foregroundStyle(Theme.ink2).lineLimit(1)
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { store.storageTools.toggleCLIAdapter(probe.id) }
            }
            HStack {
                Spacer()
                Button("执行清理（\(ordered.count) 项）") {
                    store.storageTools.confirmation = .cliBatch(ordered)
                }
                .buttonStyle(ToolbarButtonStyle(tinted: true))
                .disabled(ordered.isEmpty || store.storageTools.activity != nil)
            }
            .padding(.top, 2)
        }
        .padding(.leading, 48)
        .padding(.trailing, 14)
        .padding(.bottom, 10)
    }

    private func trigger(_ action: FindingAction) {
        switch action {
        case .reconciler(let finding):
            if case .probeAdmin = finding.action {
                store.reconciler.probeAdminHiddenSpace()
            } else {
                store.reconciler.pendingFinding = finding
            }
        case .cliTools:
            withAnimation(.easeOut(duration: 0.16)) { store.expandCLITools.toggle() }
        case .devIdle:
            store.openTool(.dev)
        case .orphans:
            store.navigate(to: .apps)
            store.uninstaller.selectOrphans()
        case .reveal(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .trashScanItem(let item):
            store.setCleanupSelected(item, selected: true)
            store.reviewCleanup(only: [item.id])
        case .openClutter:
            store.navigate(to: .clutter)
        }
    }
}

// MARK: - 4. Categorized Junk Cleanup Workbench

enum JunkCategory: String, CaseIterable, Identifiable {
    case appCache
    case browserCache
    case aiCreative
    case devBuild
    case logsLeftovers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appCache: "应用与系统缓存"
        case .browserCache: "浏览器网页缓存"
        case .aiCreative: "AI 与创作软件缓存"
        case .devBuild: "开发编译与工具缓存"
        case .logsLeftovers: "诊断日志与旧版残留"
        }
    }

    var plainSubtitle: String {
        switch self {
        case .appCache: "常用软件运行产生的临时缓存与系统升级包，下次打开会自动重建"
        case .browserCache: "Chrome、Edge、Safari 等浏览器网页与图片缓存，不删除书签和账号"
        case .aiCreative: "剪映、Adobe、Cursor、Codex 等 AI 与创作软件的外围缓存"
        case .devBuild: "Xcode、Swift、Rust、Node、Python 等编译构建与包下载缓存"
        case .logsLeftovers: "30 天前的软件崩溃日志及旧版本工具遗留文件"
        }
    }

    var symbol: String {
        switch self {
        case .appCache: "sparkles"
        case .browserCache: "globe"
        case .aiCreative: "wand.and.stars"
        case .devBuild: "hammer.fill"
        case .logsLeftovers: "doc.text.fill"
        }
    }

    var tint: Color {
        switch self {
        case .appCache: Theme.blue
        case .browserCache: Theme.cyan
        case .aiCreative: Theme.pink
        case .devBuild: Theme.indigo
        case .logsLeftovers: Theme.amber
        }
    }

    static func classify(_ item: ScanItem, home: URL) -> JunkCategory {
        if DiagnosticJunk.recognizes(item.url, home: home)
            || ToolVersions(home: home).tool(for: item.url) != nil
            || Leftovers.note(for: item.url) != nil
            || item.url.path.hasSuffix("/CoreSimulator/Logs") {
            return .logsLeftovers
        }
        if BrowserCaches.owner(of: item.url, home: home) != nil {
            return .browserCache
        }
        if CreativeApp.of(item) != nil
            || item.url.path.contains("/Application Support/Codex/")
            || item.url.path.contains("/Application Support/Notion/") {
            return .aiCreative
        }
        let name = item.url.lastPathComponent
        if DeveloperCaches.match(for: item.url, home: home) != nil
            || [".build", "target", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".gradle"].contains(name)
            || SafetyPolicy.frontEndCaches[name] != nil
            || (name == "cache" && item.url.deletingLastPathComponent().lastPathComponent == ".next")
            || item.url.path.contains("/Library/Developer/")
            || item.url.path.hasSuffix("/.cache/pip")
            || item.url.path.hasSuffix("/.npm/_cacache")
            || item.url.path.hasSuffix("/Library/Caches/Homebrew") {
            return .devBuild
        }
        return .appCache
    }

    static func breakdown(for items: [ScanItem], home: URL) -> [(category: JunkCategory, bytes: Int64)] {
        var totals: [JunkCategory: Int64] = [:]
        for item in items {
            let cat = classify(item, home: home)
            totals[cat, default: 0] += item.cleanupBytes
        }
        return Self.allCases.compactMap { cat in
            guard let bytes = totals[cat], bytes > 0 else { return nil }
            return (cat, bytes)
        }
        .sorted { $0.bytes > $1.bytes }
    }
}

struct UnifiedCleanListView: View {
    @ObservedObject var store: ScanStore
    let result: ScanResult

    private var allCleanable: [ScanItem] {
        store.shownItems.filter { $0.kind == .cache && $0.canTrash }
            .sorted { $0.cleanupBytes > $1.cleanupBytes }
    }

    private var categorizedGroups: [(category: JunkCategory, items: [ScanItem])] {
        var map: [JunkCategory: [ScanItem]] = [:]
        for item in allCleanable {
            let cat = JunkCategory.classify(item, home: store.policy.home)
            map[cat, default: []].append(item)
        }
        return JunkCategory.allCases.compactMap { cat in
            guard let list = map[cat], !list.isEmpty else { return nil }
            return (cat, list.sorted { $0.cleanupBytes > $1.cleanupBytes })
        }
    }

    private var redundantInstallers: [ScanItem] {
        store.largeAndInstallerItems.filter {
            ["dmg", "pkg"].contains($0.url.pathExtension.lowercased()) && store.isSelectable($0)
        }
    }

    private var cleanableSelectable: [ScanItem] {
        allCleanable.filter { store.isSelectable($0) }
    }

    private var allSafePicked: Bool {
        !cleanableSelectable.isEmpty && cleanableSelectable.allSatisfy { store.isPicked($0.id) }
    }

    private var selectedOnPage: [ScanItem] {
        (allCleanable + redundantInstallers).filter { store.isSelectable($0) && store.isPicked($0.id) }
    }

    var body: some View {
        let pickedItems = selectedOnPage
        let pickedBytes = ScanStore.cleanupSum(pickedItems)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { store.showingSmartCleanDetail = false }
                } label: {
                    Label("返回", systemImage: "chevron.left")
                }
                .buttonStyle(ToolbarButtonStyle(tinted: false))

                VStack(alignment: .leading, spacing: 2) {
                    Text("垃圾清理分类明细").font(.system(size: 18, weight: .bold))
                    Text("按应用、浏览器、AI 工具、开发缓存与日志归类；勾选即可一键清理，取消勾选即可跳过。")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                }
                Spacer()
                if !cleanableSelectable.isEmpty {
                    Button(allSafePicked ? "取消全选" : "全选安全缓存") {
                        let next = !allSafePicked
                        for item in cleanableSelectable {
                            store.setCleanupSelected(item, selected: next)
                        }
                    }
                    .buttonStyle(ToolbarButtonStyle(tinted: false))
                    .disabled(store.isCleaning)
                }
                Button(pickedBytes > 0 ? "立即清理 \(ByteFormat.string(pickedBytes))" : "立即清理") {
                    store.reviewCleanup(only: Set(pickedItems.map(\.id)))
                }
                .buttonStyle(HeroButtonStyle())
                .disabled(pickedItems.isEmpty || store.isCleaning)
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)
            .padding(.bottom, 12)

            ScrollView {
                GlassGroup {
                    VStack(alignment: .leading, spacing: 14) {
                        if allCleanable.isEmpty && redundantInstallers.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 28))
                                    .foregroundStyle(Theme.green)
                                Text("当前没有可清理的缓存项").font(.system(size: 15, weight: .semibold))
                                Text("可返回智能体检进行全盘深度扫描，或前往「文件整理」清理大文件与重复副本。")
                                    .font(.system(size: 13)).foregroundStyle(Theme.ink2)
                            }
                            .frame(maxWidth: .infinity, minHeight: 220)
                            .appleGroupedCard(radius: 14)
                        } else {
                            ForEach(categorizedGroups, id: \.category.id) { group in
                                categoryCard(group.category, items: group.items)
                            }

                            if !redundantInstallers.isEmpty {
                                installersCard
                            }
                        }

                        if !result.chatApps.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("通讯与办公数据（聊天记录受保护，展开查看原应用清理指引）")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(Theme.ink2)
                                VStack(spacing: 0) {
                                    ForEach(Array(result.chatApps.enumerated()), id: \.element.id) { index, app in
                                        if index > 0 { InsetHairlineDivider(leading: 48) }
                                        DisclosureGroup {
                                            VStack(alignment: .leading, spacing: 8) {
                                                if let parts = app.parts, !parts.isEmpty {
                                                    HStack(spacing: 12) {
                                                        ForEach(parts) { part in
                                                            let label: String = switch part.kind {
                                                            case .cache: "缓存"
                                                            case .media: "图片视频与文件"
                                                            case .records: "聊天记录"
                                                            case .drive: "微盘"
                                                            case .other: "其他"
                                                            }
                                                            Text("\(label) \(ByteFormat.string(part.bytes))")
                                                                .font(.system(size: 11.5))
                                                                .foregroundStyle(Theme.ink2)
                                                                .monospacedDigit()
                                                        }
                                                    }
                                                }
                                                let path = ChatGuide.path(for: app.id).joined(separator: " → ")
                                                Text("应用内路径：\(path)")
                                                    .font(.system(size: 12, weight: .medium))
                                                    .foregroundStyle(Theme.blue)
                                                ForEach(ChatGuide.steps(for: app.id), id: \.title) { step in
                                                    Text("· \(step.title)：\(step.text)")
                                                        .font(.system(size: 12))
                                                        .foregroundStyle(Theme.ink2)
                                                        .fixedSize(horizontal: false, vertical: true)
                                                }
                                                HStack {
                                                    Spacer()
                                                    Button("打开 \(app.name)") { store.openApp(bundleID: app.id) }
                                                        .buttonStyle(ToolbarButtonStyle(tinted: false))
                                                }
                                            }
                                            .padding(.top, 8)
                                            .padding(.bottom, 4)
                                        } label: {
                                            HStack {
                                                IconTile(symbol: "message.fill", tint: Theme.green, size: 24)
                                                Text(app.name).font(.system(size: 13.5, weight: .medium))
                                                Spacer()
                                                Text(app.bytes.map(ByteFormat.string) ?? "需完全磁盘访问")
                                                    .font(.system(size: 13, weight: .semibold))
                                                    .foregroundStyle(app.bytes == nil ? Theme.amber : Theme.ink)
                                                    .monospacedDigit()
                                            }
                                        }
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)
                                    }
                                }
                                .appleGroupedCard(radius: 14)
                            }
                        }

                        let readOnlyData = store.shownItems.filter {
                            $0.kind == .review && !store.isDecidable($0) && !CreativeApp.isReviewCache($0.url) && $0.bytes >= 100_000_000
                        }.sorted { $0.bytes > $1.bytes }
                        if !readOnlyData.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("AI 与软件本地保留数据（仅供空间参考，小清不会自动删除）")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(Theme.ink2)
                                VStack(spacing: 0) {
                                    ForEach(Array(readOnlyData.enumerated()), id: \.element.id) { index, item in
                                        if index > 0 { InsetHairlineDivider(leading: 48) }
                                        let info = ItemPresentation.info(for: item)
                                        HStack(spacing: 10) {
                                            IconTile(symbol: info.symbol, tint: Theme.ink3, size: 24)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(info.title).font(.system(size: 13, weight: .medium))
                                                Text(item.note).font(.system(size: 11.5)).foregroundStyle(Theme.ink2).lineLimit(1)
                                            }
                                            Spacer()
                                            Text(ByteFormat.string(item.bytes)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                                            Button("在访达中显示", systemImage: "folder") {
                                                NSWorkspace.shared.activateFileViewerSelecting([item.url])
                                            }
                                            .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(Theme.ink2)
                                        }
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)
                                    }
                                }
                                .appleGroupedCard(radius: 14)
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 26)
                }
            }
        }
    }

    private func categoryCard(_ category: JunkCategory, items: [ScanItem]) -> some View {
        let selectable = items.filter { store.isSelectable($0) }
        let picked = selectable.filter { store.isPicked($0.id) }
        let allOn = !selectable.isEmpty && picked.count == selectable.count
        let expanded = store.expandedJunkCategories.contains(category.id)
        let totalBytes = ScanStore.cleanupSum(items)
        let pickedBytes = ScanStore.cleanupSum(picked)
        return VStack(spacing: 0) {
            HStack(spacing: 11) {
                ToolCheckbox(on: allOn)
                    .opacity(selectable.isEmpty ? 0.35 : 1)
                    .onTapGesture {
                        guard !selectable.isEmpty, !store.isCleaning else { return }
                        let next = !allOn
                        for item in selectable { store.setCleanupSelected(item, selected: next) }
                    }
                IconTile(symbol: category.symbol, tint: category.tint, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(category.title).font(.system(size: 14, weight: .bold))
                        Text("\(items.count) 项")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.ink3)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Theme.fill(0.06)))
                    }
                    if pickedBytes > 0 && pickedBytes < totalBytes {
                        Text("已选 \(ByteFormat.string(pickedBytes)) / 共 \(ByteFormat.string(totalBytes))")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.blue)
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: 10)
                Text(ByteFormat.string(totalBytes))
                    .font(.system(size: 14.5, weight: .bold))
                    .foregroundStyle(picked.isEmpty ? Theme.ink3 : Theme.ink)
                    .monospacedDigit()
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.ink3)
                    .frame(width: 18)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.fill(0.02))
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.16)) {
                    if expanded {
                        store.expandedJunkCategories.remove(category.id)
                    } else {
                        store.expandedJunkCategories.insert(category.id)
                    }
                }
            }

            if expanded {
                ForEach(items) { item in
                    InsetHairlineDivider(leading: 54)
                    cacheRow(item)
                }
            }
        }
        .appleGroupedCard(radius: 14)
    }

    private var installersCard: some View {
        let total = ScanStore.cleanupSum(redundantInstallers)
        return VStack(spacing: 0) {
            HStack(spacing: 11) {
                IconTile(symbol: "shippingbox.fill", tint: Theme.violet, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("磁盘中的软件安装包（DMG / PKG）")
                        .font(.system(size: 14, weight: .bold))
                    Text("默认不勾选；勾选后将与以上缓存一并移到废纸篓（可在访达恢复）。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.ink2)
                }
                Spacer(minLength: 10)
                Text(ByteFormat.string(total))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.ink2)
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.fill(0.02))

            ForEach(redundantInstallers) { item in
                InsetHairlineDivider(leading: 54)
                let picked = store.isPicked(item.id)
                HStack(spacing: 11) {
                    ToolCheckbox(on: picked, amber: true)
                        .onTapGesture { store.toggleSelection(item) }
                    Image(nsImage: ItemPresentation.icon(forPath: item.url.path))
                        .resizable()
                        .frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                            if item.note.hasPrefix("已安装") {
                                ToolTag(text: "已安装", tint: Theme.green)
                            }
                        }
                        Text(item.note)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ink2)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 10)
                    Text(ByteFormat.string(item.bytes))
                        .font(.system(size: 13.5, weight: .semibold))
                        .monospacedDigit()
                    Button("在访达中显示", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.ink2)
                    .help("在访达中显示")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
                .onTapGesture { store.toggleSelection(item) }
            }
        }
        .appleGroupedCard(radius: 14)
    }

    private func cacheRow(_ item: ScanItem) -> some View {
        let blocked = store.deferredBrowsers[item.id]
        let picked = store.isPicked(item.id)
        let info = ItemPresentation.info(for: item)
        return HStack(spacing: 11) {
            if blocked == nil {
                ToolCheckbox(on: picked)
                    .onTapGesture { store.toggleSelection(item) }
            } else {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(Theme.amber)
                    .frame(width: 18)
            }
            if let icon = info.icon {
                Image(nsImage: icon).resizable().frame(width: 26, height: 26)
            } else {
                IconTile(symbol: info.symbol, tint: Theme.blue, size: 26)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(info.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                Text(blocked.map { "退出 \($0) 后可释放" } ?? item.note)
                    .font(.system(size: 12))
                    .foregroundStyle(blocked != nil ? Theme.amber : Theme.ink2)
                    .lineLimit(1)
            }
            Spacer(minLength: 10)
            Text(ByteFormat.string(item.cleanupBytes))
                .font(.system(size: 13.5, weight: .semibold))
                .monospacedDigit()
            Button("在访达中显示", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(Theme.ink2)
            .help("在访达中显示")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            if blocked == nil { store.toggleSelection(item) }
        }
        .contextMenu {
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("不再清理此项") { store.ignore([item]) }
        }
    }
}
