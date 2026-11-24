import SwiftUI

/// 「空间分布」页（效果图 `output/mockups/s-map/d-combined.png`，2026-11-06 用户定）：
/// 顶部容量条 → 可直接清理 → 左「需要确认」暖色块、右「无法清理」冷色块，块的面积按大小分。
/// 右边不用灰色（用户：「那是看得最多的画面，别那么灰」）。
struct SpaceMapPage: View {
    @ObservedObject var store: ScanStore
    @ObservedObject private var tools: StorageToolsStore
    @ObservedObject private var lens: SpaceLensStore
    let embedded: Bool
    let embeddedCompact: Bool

    init(store: ScanStore, embedded: Bool = false, embeddedCompact: Bool = false) {
        self.store = store
        self.tools = store.storageTools
        self.lens = store.spaceLens
        self.embedded = embedded
        self.embeddedCompact = embeddedCompact
    }

    var body: some View {
        Group {
            if embedded {
                if let map = store.spaceMap {
                    content(map, compact: embeddedCompact, height: 420)
                } else {
                    measuringPlaceholder
                }
            } else {
                GeometryReader { proxy in
                    let compact = proxy.size.width < 900
                    ScrollView {
                        GlassGroup {
                            VStack(alignment: .leading, spacing: 14) {
                                header
                                spaceTabBar
                                switch store.spaceTab {
                                case .map:
                                    if let map = store.spaceMap {
                                        content(map, compact: compact, height: max(proxy.size.height - 300, 360))
                                    } else {
                                        measuringPlaceholder
                                    }
                                case .explore:
                                    SpaceLensInlineView(store: lens)
                                case .clutter:
                                    clutterTab
                                case .system:
                                    systemReleaseTab
                                }
                            }
                            .padding(.horizontal, 30)
                            .padding(.top, 16)
                            .padding(.bottom, 24)
                        }
                    }
                }
            }
        }
        .alert(tools.confirmation?.action ?? "", isPresented: Binding(
            get: { tools.confirmation != nil },
            set: { if !$0 { tools.confirmation = nil } }
        ), presenting: tools.confirmation) { operation in
            Button("取消", role: .cancel) {}
            Button(operation.action, role: .destructive) { tools.confirm(operation) }
        } message: { operation in
            Text(operation.detail)
        }
    }

    private var spaceTabBar: some View {
        HStack(spacing: 4) {
            ForEach(ScanStore.SpaceTab.allCases) { tab in
                let active = store.spaceTab == tab
                Button {
                    store.openSpace(tab: tab)
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 13, weight: active ? .semibold : .medium))
                        .foregroundStyle(active ? Theme.ink : Theme.ink2)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6.5)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(active ? Theme.raised : .clear)
                                .shadow(color: active ? .black.opacity(0.08) : .clear, radius: 2, y: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fill(0.06)))
    }

    private var clutterTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Card 1: Large files & installers summary
            HStack(spacing: 14) {
                IconTile(symbol: "doc.on.doc.fill", tint: Theme.violet, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("大文件与安装包").font(.system(size: 14.5, weight: .semibold))
                    if let summary = store.largeFileSummary, summary.count > 0 {
                        Text("发现 \(summary.count) 项超过 1 GB 的文件或安装包，共约 \(ByteFormat.string(summary.bytes))。")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                    } else {
                        Text("查找个人文件夹中超过 1 GB 的大文件、压缩包与已安装软件的安装包。")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                    }
                }
                Spacer(minLength: 10)
                if store.largeFileSummary != nil {
                    Button("查看列表") {
                        store.selectCategory(.large)
                    }
                    .buttonStyle(ToolbarButtonStyle(tinted: true))
                }
                Button("重新扫描大文件") {
                    store.scanLocation(store.policy.home)
                }
                .buttonStyle(ToolbarButtonStyle(tinted: store.largeFileSummary == nil))
            }
            .padding(16)
            .glass(radius: 14)

            // Card 2: Inline Duplicate Files Finder
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    IconTile(symbol: "square.on.square", tint: Theme.blue, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("查找重复文件").font(.system(size: 14.5, weight: .semibold))
                        Text("在所选文件夹内按内容哈希查找大小至少 50 MB 的完全一致文件，清理时始终保留一份。")
                            .font(.system(size: 12)).foregroundStyle(Theme.ink2)
                    }
                    Spacer(minLength: 10)
                    Button("选择文件夹扫描…", action: tools.chooseFolder)
                        .buttonStyle(ToolbarButtonStyle(tinted: true))
                        .disabled(tools.activity != nil)
                }

                if let activity = tools.activity {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(activity).font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                        Button("取消", action: tools.cancelDuplicateScan).buttonStyle(ToolbarButtonStyle(tinted: false))
                    }
                }
                if let result = tools.results {
                    if result.groups.isEmpty {
                        Text("所选文件夹中未找到 50 MB 以上的重复文件。")
                            .font(.system(size: 13)).foregroundStyle(Theme.ink2)
                    } else {
                        Text("找到 \(result.groups.count) 组内容完全相同的文件：")
                            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.ink2)
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(result.groups) { group in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("\(group.files.count) 份相同文件 · 每份 \(ByteFormat.string(group.files[0].bytes))")
                                        .font(.system(size: 13, weight: .semibold))
                                    ForEach(group.files) { file in
                                        HStack(spacing: 8) {
                                            Text(ToolText.short(file.url))
                                                .font(.system(size: 12.5))
                                                .lineLimit(1).truncationMode(.middle)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            Button("在访达中显示", systemImage: "folder") {
                                                NSWorkspace.shared.activateFileViewerSelecting([file.url])
                                            }
                                            .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(Theme.ink2)
                                            Button("移到废纸篓…") { tools.requestMove(file, in: group) }
                                                .buttonStyle(ToolbarButtonStyle(tinted: false))
                                                .disabled(tools.activity != nil)
                                        }
                                    }
                                }
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fill(0.05)))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
                            }
                        }
                    }
                }
                if let msg = tools.message {
                    Text(msg).font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                }
            }
            .padding(16)
            .glass(radius: 14)
        }
    }

    private var systemReleaseTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 1. Hidden system space & Spotlight / logs / wallpapers / stale models
            ReconcilerInlineSection(store: store.reconciler)

            // 2. Time Machine Snapshots & iCloud Evict (side-by-side glass cards)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        IconTile(symbol: "clock.arrow.circlepath", tint: Theme.orange, size: 28)
                        Text("时间机器本地快照").font(.system(size: 14, weight: .semibold))
                    }
                    if let snapshots = tools.snapshots {
                        Text(snapshots.isEmpty ? "当前启动盘没有本地快照。" : "检测到 \(snapshots.count) 份本地快照，释放不影响外接备份盘。")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                    } else {
                        Text("检测隐藏在「系统数据」中的本地快照。").font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                    }
                    HStack(spacing: 8) {
                        if let snapshots = tools.snapshots, !snapshots.isEmpty {
                            Button("释放快照空间…") { tools.confirmation = .snapshots(snapshots) }
                                .buttonStyle(ToolbarButtonStyle(tinted: true))
                                .disabled(tools.activity != nil)
                        }
                        Button("重新检测", action: tools.refreshSnapshots)
                            .buttonStyle(ToolbarButtonStyle(tinted: false))
                            .disabled(tools.activity != nil)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .glass(radius: 14)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        IconTile(symbol: "icloud.and.arrow.down", tint: Theme.blue, size: 28)
                        Text("iCloud 本机副本").font(.system(size: 14, weight: .semibold))
                    }
                    Text("仅移除已同步文件的本机占用，云端完整保留，下次打开自动下载。")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                    HStack(spacing: 8) {
                        Button("选择 iCloud 文件…", action: tools.chooseCloudFile)
                            .buttonStyle(ToolbarButtonStyle(tinted: true))
                            .disabled(tools.activity != nil)
                        Button("查看系统更新", action: openSoftwareUpdate)
                            .buttonStyle(ToolbarButtonStyle(tinted: false))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .glass(radius: 14)
            }

            // 3. Installed Tools Batch Maintenance (only shows tools actually installed on this Mac!)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    IconTile(symbol: "wrench.and.screwdriver", tint: Theme.indigo, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("已安装工具与缓存维护").font(.system(size: 14, weight: .semibold))
                        Text("自动识别本机已安装工具，勾选后一次安全清理。未安装的工具不会显示。")
                            .font(.system(size: 12)).foregroundStyle(Theme.ink2)
                    }
                    Spacer(minLength: 10)
                    let ordered = tools.cliProbes.map(\.id).filter { tools.selectedCLIAdapters.contains($0) }
                    Button("清理所选（\(ordered.count) 项）") {
                        tools.confirmation = .cliBatch(ordered)
                    }
                    .buttonStyle(ToolbarButtonStyle(tinted: true))
                    .disabled(ordered.isEmpty || tools.activity != nil)
                }

                if tools.cliProbes.isEmpty {
                    Text("正在检测本机已安装的工具…").font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                } else {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        ForEach(tools.cliProbes) { probe in
                            let picked = tools.selectedCLIAdapters.contains(probe.id)
                            HStack(spacing: 10) {
                                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(picked ? Theme.blue : Theme.ink3)
                                    .font(.system(size: 15))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(probe.id.title).font(.system(size: 13, weight: .semibold))
                                    Text(probe.summary).font(.system(size: 12)).foregroundStyle(Theme.ink2).lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(picked ? Theme.selection : Theme.fill(0.05)))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(picked ? Theme.blue.opacity(0.35) : Theme.line))
                            .contentShape(Rectangle())
                            .onTapGesture { tools.toggleCLIAdapter(probe.id) }
                        }
                    }
                }
                if let msg = tools.message {
                    Text(msg).font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                }
            }
            .padding(16)
            .glass(radius: 14)
        }
    }

    private func openSoftwareUpdate() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!)
    }

    private var cleanable: Int64 { ScanStore.cleanupSum(store.eligibleItems) }

    private var header: some View {
        let map = store.spaceMap
        let subtitle = map.map { "共 \(ByteFormat.string($0.total))，已用 \(ByteFormat.string($0.used))，可用 \(ByteFormat.string($0.available))" }
            ?? "正在量各部分占用的空间"
        return PageHeader(symbol: "square.grid.2x2.fill", tint: Theme.indigo, title: "空间分布", subtitle: subtitle) {
            HStack(spacing: 10) {
                if let step = store.measuringSpaceMap {
                    ProgressView().controlSize(.small)
                    Text(step).font(.system(size: 12.5)).foregroundStyle(Theme.ink2).lineLimit(1)
                } else if let map {
                    Text("测量于 \(MainView.ago(map.measuredAt))").font(.system(size: 12.5)).foregroundStyle(Theme.ink3)
                }
                Button("重新测量") { store.measureSpaceMap() }
                    .buttonStyle(ToolbarButtonStyle(tinted: true))
                    .disabled(store.measuringSpaceMap != nil)
            }
        }
    }

    private var measuringPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("第一次打开需要量一遍应用程序和个人文件夹，约一两分钟").font(.system(size: 13)).foregroundStyle(Theme.ink2)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .glass()
    }

    // MARK: 内容

    private func content(_ map: SpaceMap, compact: Bool, height: CGFloat) -> some View {
        let other = map.remainder(cleanable: cleanable)
        let decide = map.blocks.filter { $0.section == .decide }
        let fixed = map.blocks.filter { $0.section == .fixed } + [SpaceMap.Block(
            id: "other", title: "其他", bytes: other, note: "包含沙盒容器、邮件和 macOS 更新准备文件。更新文件的大小无法单独读取。",
            section: .fixed, action: .softwareUpdate)]
        let decideBytes = decide.reduce(0) { $0 + $1.bytes }, fixedBytes = fixed.reduce(0) { $0 + $1.bytes }
        let left = pane(title: "需要确认", hint: "删除前由你决定", tint: Self.warm, bytes: decideBytes, blocks: decide,
                        height: compact ? 380 : height)
        let right = pane(title: "无法清理", hint: "属于系统或其他 App", tint: Self.cool, bytes: fixedBytes, blocks: fixed,
                         height: compact ? 380 : height)
        // 两区宽度按大小分，每区至少 36%，小的一边也放得下按钮
        let share = min(max(CGFloat(decideBytes) / CGFloat(max(decideBytes + fixedBytes, 1)), 0.36), 0.64)
        return VStack(alignment: .leading, spacing: 14) {
            capacityBar(map, decide: decideBytes, fixed: fixedBytes)
            cleanCard
            occupancyCard(map)
            if compact {
                VStack(spacing: 14) { left; right }
            } else {
                GeometryReader { proxy in
                    HStack(alignment: .top, spacing: 14) {
                        left.frame(width: (proxy.size.width - 14) * share)
                        right.frame(width: (proxy.size.width - 14) * (1 - share))
                    }
                }
                .frame(height: height + 68)
            }
        }
    }

    private func occupancyCard(_ map: SpaceMap) -> some View {
        let trash = map.trashOccupancy
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "trash")
                Text("废纸篓")
                Spacer()
                Text(trash?.bytes.map(ByteFormat.string) ?? (trash == nil ? "尚未测量" : "无法读取"))
                    .monospacedDigit()
                Button("在访达中查看") { store.openTrash() }
                    .buttonStyle(ToolbarButtonStyle(tinted: true))
            }
            if let copies = map.sharedBrowserCopies, copies.count > 0 {
                Text("\(copies.count) 项同版本浏览器签名副本，逐份合计 \(ByteFormat.string(copies.countedBytes))，可能与浏览器本体共享数据。")
                    .foregroundStyle(Theme.ink2)
                Text("共享部分不计入可清理估算。").foregroundStyle(Theme.ink2)
            }
        }
        .font(.system(size: 13.5))
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glass()
    }

    private static let warm = Color(red: 0.82, green: 0.55, blue: 0.24)
    private static let cool = Color(red: 0.36, green: 0.53, blue: 0.79)

    private func capacityBar(_ map: SpaceMap, decide: Int64, fixed: Int64) -> some View {
        let parts: [(Int64, AnyShapeStyle)] = [
            (cleanable, AnyShapeStyle(Theme.blue)),
            (decide, AnyShapeStyle(LinearGradient(colors: [Color(red: 0.87, green: 0.63, blue: 0.29), Self.warm], startPoint: .leading, endPoint: .trailing))),
            (fixed, AnyShapeStyle(LinearGradient(colors: [Color(red: 0.50, green: 0.66, blue: 0.86), Color(red: 0.49, green: 0.47, blue: 0.76)], startPoint: .leading, endPoint: .trailing))),
            (map.available, AnyShapeStyle(Theme.track.opacity(0.5)))
        ]
        let sum = max(parts.reduce(0) { $0 + $1.0 }, 1)
        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(parts.indices, id: \.self) { i in
                        Capsule().fill(parts[i].1)
                            .frame(width: max(proxy.size.width * CGFloat(parts[i].0) / CGFloat(sum) - 2, parts[i].0 > 0 ? 3 : 0))
                    }
                }
            }
            .frame(height: 10)
            HStack(spacing: 18) {
                legend("可清理", cleanable, Theme.blue)
                legend("需要确认", decide, Self.warm)
                legend("无法清理", fixed, Self.cool)
                Spacer(minLength: 0)
                legend("可用", map.available, Theme.track)
            }
        }
    }

    private func legend(_ title: String, _ bytes: Int64, _ color: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(title).foregroundStyle(Theme.ink2)
            Text(ByteFormat.string(bytes)).fontWeight(.semibold).monospacedDigit()
        }
        .font(.system(size: 13.5))
        .lineLimit(1)
    }

    private var cleanCard: some View {
        let selected = store.selectedCacheBytes
        let allDirectPurge = selected > 0 && store.selectedCacheItems.allSatisfy { store.policy.isDirectPurgeEligible($0) }
        let detailText: String = {
            if cleanable == 0 { return "缓存会随使用重新生成，可稍后重新扫描" }
            if selected > 0 && allDirectPurge {
                return "应用与开发缓存可自动重建，直接永久释放以立即腾出空间"
            }
            return "应用与开发缓存可自动重建，纯缓存直接释放，其余移到废纸篓可撤销"
        }()
        return HStack(spacing: 16) {
            // 没有可清理的不写「0」（总览同一规矩）
            if cleanable > 0 {
                Text(ByteFormat.string(cleanable))
                    .font(.system(size: 34, weight: .bold)).foregroundStyle(Theme.blue).monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(cleanable > 0 ? "可直接清理" : "暂无可清理的缓存").font(.system(size: cleanable > 0 ? 16 : 18, weight: .semibold))
                Text(detailText)
                    .font(.system(size: 14)).foregroundStyle(Theme.ink2).lineLimit(2)
                if !store.deferredBrowsers.isEmpty {
                    Button("退出对应浏览器后可清理约 \(ByteFormat.string(store.deferredBrowserBytes)) ›") {
                        store.selectCategory(.caches)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.amber)
                }
            }
            Spacer(minLength: 12)
            if cleanable > 0 {
                Button { store.reviewCleanup(scope: .caches) } label: {
                    if store.isCleaning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).tint(.white)
                            Text("正在清理 \(store.cleanedCount)/\(store.itemsToClean.count)").monospacedDigit()
                        }
                    } else {
                        Text(selected > 0 ? "清理 \(ByteFormat.string(selected))" : "清理")
                    }
                }
                .buttonStyle(HeroButtonStyle())
                .disabled(selected == 0 || store.isCleaning)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .glass()
    }

    // MARK: 色块区

    private func pane(title: String, hint: String, tint: Color, bytes: Int64, blocks: [SpaceMap.Block], height: CGFloat) -> some View {
        // 太小的块看不清也点不准，并进同区最后一块的说明里不单列
        let shown = blocks.filter { $0.bytes >= 500_000_000 }
            .sorted { (Self.order.firstIndex(of: $0.id) ?? 99) < (Self.order.firstIndex(of: $1.id) ?? 99) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(tint).frame(width: 9, height: 9)
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(hint).font(.system(size: 13.5)).foregroundStyle(Theme.ink2)
                Spacer(minLength: 8)
                Text(ByteFormat.string(bytes)).font(.system(size: 19, weight: .bold)).foregroundStyle(tint).monospacedDigit()
            }
            .padding(.horizontal, 4)
            Treemap(blocks: shown) { block, size in tile(block, size: size) }
                .frame(height: height)
        }
        .padding(12)
        .glass()
    }

    private func tile(_ block: SpaceMap.Block, size: CGSize) -> some View {
        let small = size.height < 110 || size.width < 170
        // 很小的块才藏按钮；矮一点的只省说明，按钮照常（排序后「微信等聊天」会变矮，按钮不能丢）
        let tiny = size.height < 76 || size.width < 150
        let showNote = size.height >= 130 && size.width >= 170
        let colors = Self.colors[block.id] ?? [Theme.slate, Theme.slate]
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(RadialGradient(colors: [.white.opacity(0.20), .clear], center: .topLeading, startRadius: 0, endRadius: max(size.width, size.height) * 0.7))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [.clear, .black.opacity(0.24)], startPoint: .center, endPoint: .bottom))
            VStack(alignment: .leading, spacing: 1) {
                Text(block.title).font(.system(size: 15, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
                Text(ByteFormat.string(block.bytes)).font(.system(size: small ? 20 : 28, weight: .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.55)
                Spacer(minLength: 0)
                if !tiny, showNote || block.action != nil {
                    HStack(alignment: .bottom, spacing: 10) {
                        if showNote {
                            Text(block.note).font(.system(size: 13)).opacity(0.92).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        if let action = block.action { actionButton(action) }
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(width: size.width, height: size.height)
        .help(block.note)
    }

    private func actionButton(_ action: SpaceMap.Action) -> some View {
        let title: String = switch action {
        case .uninstall: "卸载应用"
        case .largeFiles: "大文件"
        case .chat: "查看方法"
        case .dev: "开发缓存"
        case .softwareUpdate: "前往更新"
        case .trash: "打开废纸篓"
        }
        return Button(title) {
            withAnimation(.easeOut(duration: 0.15)) {
                switch action {
                case .uninstall: store.navigate(to: .apps)
                case .dev: store.navigate(to: .devMaintenance); store.devMaintenanceTab = .projects
                case .largeFiles: store.navigate(to: .clutter)
                case .chat: store.navigate(to: .chatAI)
                case .softwareUpdate: openSoftwareUpdate()
                case .trash: store.openTrash()
                }
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Color(red: 0.10, green: 0.13, blue: 0.17))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(.white.opacity(0.94)))
        .fixedSize()
    }

    /// 块按「好理解」排，不按大小（用户：「macOS 系统应该放在第一个」）：先系统本身，再到各 App 和自己的东西，「其他」最后
    private static let order = ["apps", "documents", "chat", "ai", "dev", "trash",
                                "system", "systemdata", "appdata", "tooling", "other"]

    /// 柔和苹果储存空间色阶：暖色（需要决定）与冷色（系统与固定占用），与整体青绿玻璃和谐统一
    private static let colors: [String: [Color]] = [
        "apps": [Color(red: 0.85, green: 0.57, blue: 0.23), Color(red: 0.77, green: 0.48, blue: 0.15)],
        "documents": [Color(red: 0.63, green: 0.54, blue: 0.79), Color(red: 0.51, green: 0.42, blue: 0.68)],
        "chat": [Color(red: 0.85, green: 0.42, blue: 0.47), Color(red: 0.75, green: 0.33, blue: 0.38)],
        "dev": [Color(red: 0.86, green: 0.49, blue: 0.32), Color(red: 0.77, green: 0.39, blue: 0.23)],
        "ai": [Color(red: 0.84, green: 0.52, blue: 0.43), Color(red: 0.73, green: 0.41, blue: 0.33)],
        "appdata": [Color(red: 0.37, green: 0.42, blue: 0.76), Color(red: 0.29, green: 0.35, blue: 0.66)],
        "system": [Color(red: 0.42, green: 0.49, blue: 0.56), Color(red: 0.34, green: 0.40, blue: 0.47)],
        "other": [Color(red: 0.14, green: 0.56, blue: 0.54), Color(red: 0.10, green: 0.44, blue: 0.43)],
        "tooling": [Color(red: 0.22, green: 0.60, blue: 0.56), Color(red: 0.15, green: 0.48, blue: 0.45)],
        "systemdata": [Color(red: 0.44, green: 0.50, blue: 0.66), Color(red: 0.35, green: 0.41, blue: 0.56)],
        "trash": [Color(red: 0.82, green: 0.68, blue: 0.35), Color(red: 0.71, green: 0.56, blue: 0.23)]
    ]
}

/// 两块一行，行高按这一行的大小、行内宽度按各块大小分（块数少，比方形树图好读）
struct Treemap<Tile: View>: View {
    let blocks: [SpaceMap.Block]
    @ViewBuilder let tile: (SpaceMap.Block, CGSize) -> Tile

    var body: some View {
        GeometryReader { proxy in
            let rows = stride(from: 0, to: blocks.count, by: 2).map { Array(blocks[$0..<min($0 + 2, blocks.count)]) }
            let total = max(blocks.reduce(0) { $0 + $1.bytes }, 1)
            let gap: CGFloat = 6
            let usableHeight = proxy.size.height - gap * CGFloat(max(rows.count - 1, 0))
            let heights = TreemapLayout.rowHeights(rows.map { $0.reduce(0) { $0 + $1.bytes } }, total: total, height: usableHeight)
            VStack(spacing: gap) {
                ForEach(rows.indices, id: \.self) { r in
                    let row = rows[r]
                    let rowBytes = max(row.reduce(0) { $0 + $1.bytes }, 1)
                    let height = heights[r]
                    let usableWidth = proxy.size.width - gap * CGFloat(row.count - 1)
                    HStack(spacing: gap) {
                        ForEach(row) { block in
                            tile(block, CGSize(width: usableWidth * CGFloat(block.bytes) / CGFloat(rowBytes), height: height))
                        }
                    }
                }
            }
        }
    }
}

/// 色块区的行高（单独放，测试不用碰界面类型）
enum TreemapLayout {
    /// 小行至少 `minimum` 高（放得下名字和大小），其余行按大小分剩下的高度；加起来正好等于可用高度，不会撑出框
    static func rowHeights(_ bytes: [Int64], total: Int64, height: CGFloat, minimum: CGFloat = 72) -> [CGFloat] {
        guard !bytes.isEmpty else { return [] }
        if height <= minimum * CGFloat(bytes.count) { return bytes.map { _ in height / CGFloat(bytes.count) } }
        var pinned = Set<Int>()
        while true {
            let free = height - minimum * CGFloat(pinned.count)
            let flexBytes = bytes.indices.filter { !pinned.contains($0) }.reduce(Int64(0)) { $0 + bytes[$1] }
            let heights = bytes.indices.map { pinned.contains($0) ? minimum : free * CGFloat(bytes[$0]) / CGFloat(max(flexBytes, 1)) }
            let tooSmall = bytes.indices.filter { !pinned.contains($0) && heights[$0] < minimum }
            if tooSmall.isEmpty { return heights }
            pinned.formUnion(tooSmall)
        }
    }
}
