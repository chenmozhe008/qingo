import SwiftUI

/// 「空间分布」页（效果图 `output/mockups/s-map/d-combined.png`，2026-11-06 用户定）：
/// 顶部容量条 → 可直接清理 → 左「需要确认」暖色块、右「无法清理」冷色块，块的面积按大小分。
/// 右边不用灰色（用户：「那是看得最多的画面，别那么灰」）。
struct SpaceMapPage: View {
    @ObservedObject var store: ScanStore

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 900
            ScrollView {
                GlassGroup {
                    VStack(alignment: .leading, spacing: 14) {
                        header
                        if let map = store.spaceMap {
                            content(map, compact: compact, height: max(proxy.size.height - 300, 360))
                        } else {
                            measuringPlaceholder
                        }
                    }
                    .padding(.horizontal, 30)
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private var cleanable: Int64 { ScanStore.sum(store.eligibleItems) }

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
            id: "other", title: "其他", bytes: other, note: "沙盒容器、邮件、系统更新等，无法逐项读取",
            section: .fixed, action: nil)]
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
        .font(.system(size: 12.5))
        .lineLimit(1)
    }

    private var cleanCard: some View {
        let selected = store.selectedCleanupBytes
        return HStack(spacing: 16) {
            // 没有可清理的不写「0」（总览同一规矩）
            if cleanable > 0 {
                Text(ByteFormat.string(cleanable))
                    .font(.system(size: 30, weight: .bold)).foregroundStyle(Theme.blue).monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(cleanable > 0 ? "可直接清理" : "暂无可清理的缓存").font(.system(size: cleanable > 0 ? 14 : 17, weight: .semibold))
                Text(cleanable > 0 ? "缓存和旧版本副本，可自动重建，移到废纸篓后可撤销" : "缓存会随使用重新生成，可稍后重新扫描")
                    .font(.system(size: 13)).foregroundStyle(Theme.ink2).lineLimit(2)
            }
            Spacer(minLength: 12)
            if cleanable > 0 {
                Button { store.reviewCleanup() } label: {
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
        let shown = blocks.filter { $0.bytes >= 500_000_000 }.sorted { $0.bytes > $1.bytes }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(tint).frame(width: 9, height: 9)
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(hint).font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                Spacer(minLength: 8)
                Text(ByteFormat.string(bytes)).font(.system(size: 16, weight: .bold)).foregroundStyle(tint).monospacedDigit()
            }
            .padding(.horizontal, 4)
            Treemap(blocks: shown) { block, size in tile(block, size: size) }
                .frame(height: height)
        }
        .padding(12)
        .glass()
    }

    private func tile(_ block: SpaceMap.Block, size: CGSize) -> some View {
        let small = size.height < 96 || size.width < 150
        let colors = Self.colors[block.id] ?? [Theme.slate, Theme.slate]
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(RadialGradient(colors: [.white.opacity(0.22), .clear], center: .topLeading, startRadius: 0, endRadius: max(size.width, size.height) * 0.7))
            VStack(alignment: .leading, spacing: 1) {
                Text(block.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                Text(ByteFormat.string(block.bytes)).font(.system(size: small ? 17 : 22, weight: .bold)).monospacedDigit().lineLimit(1)
                Spacer(minLength: 0)
                if !small {
                    HStack(alignment: .bottom, spacing: 10) {
                        Text(block.note).font(.system(size: 12)).opacity(0.92).lineLimit(2).fixedSize(horizontal: false, vertical: true)
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
        }
        return Button(title) {
            withAnimation(.easeOut(duration: 0.15)) {
                switch action {
                case .uninstall: store.openTool(.uninstall)
                case .dev: store.openTool(.dev)
                case .largeFiles: store.selectCategory(.large)
                case .chat: store.selectCategory(.chat)
                }
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(.white.opacity(0.94)))
        .fixedSize()
    }

    /// 左边暖色、右边冷色；同一区里颜色各不相同
    private static let colors: [String: [Color]] = [
        "apps": [Color(red: 0.89, green: 0.64, blue: 0.37), Color(red: 0.79, green: 0.47, blue: 0.24)],
        "documents": [Color(red: 0.71, green: 0.59, blue: 0.84), Color(red: 0.54, green: 0.42, blue: 0.72)],
        "chat": [Color(red: 0.50, green: 0.73, blue: 0.54), Color(red: 0.35, green: 0.58, blue: 0.41)],
        "dev": [Color(red: 0.49, green: 0.56, blue: 0.80), Color(red: 0.35, green: 0.41, blue: 0.66)],
        "ai": [Color(red: 0.90, green: 0.60, blue: 0.53), Color(red: 0.79, green: 0.44, blue: 0.36)],
        "appdata": [Color(red: 0.55, green: 0.71, blue: 0.89), Color(red: 0.37, green: 0.55, blue: 0.78)],
        "system": [Color(red: 0.66, green: 0.65, blue: 0.89), Color(red: 0.49, green: 0.47, blue: 0.76)],
        "other": [Color(red: 0.49, green: 0.78, blue: 0.76), Color(red: 0.27, green: 0.60, blue: 0.60)],
        "tooling": [Color(red: 0.62, green: 0.80, blue: 0.70), Color(red: 0.42, green: 0.66, blue: 0.54)],
        "systemdata": [Color(red: 0.58, green: 0.66, blue: 0.86), Color(red: 0.42, green: 0.48, blue: 0.74)],
        "trash": [Color(red: 0.86, green: 0.75, blue: 0.43), Color(red: 0.72, green: 0.60, blue: 0.27)]
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
            VStack(spacing: gap) {
                ForEach(rows.indices, id: \.self) { r in
                    let row = rows[r]
                    let rowBytes = max(row.reduce(0) { $0 + $1.bytes }, 1)
                    let height = max(usableHeight * CGFloat(rowBytes) / CGFloat(total), 56)
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
