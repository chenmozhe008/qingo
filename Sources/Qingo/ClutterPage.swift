import AppKit
import SwiftUI

/// Page 3: Dedicated 「文件整理」 page — Large Files (≥100MB/≥1GB/Stale), Installers, Auto-Deduplication, and iCloud Local Copies.
struct ClutterPage: View {
    @ObservedObject var store: ScanStore
    @ObservedObject private var tools: StorageToolsStore
    @ObservedObject private var hover = HoverTracker()

    init(store: ScanStore) {
        self.store = store
        self.tools = store.storageTools
    }

    private var allLargeItems: [ScanItem] {
        store.largeAndInstallerItems
    }

    private var installerItems: [ScanItem] {
        allLargeItems.filter { ["dmg", "pkg", "ipsw"].contains($0.url.pathExtension.lowercased()) }
    }

    private var filteredLargeItems: [ScanItem] {
        let base = allLargeItems.filter { !["dmg", "pkg", "ipsw"].contains($0.url.pathExtension.lowercased()) }
        switch store.largeFileScope {
        case .all:
            return base
        case .huge:
            return base.filter { $0.bytes >= 1_000_000_000 }
        case .stale:
            let cutoff = Date().addingTimeInterval(-180 * 86_400)
            return base.filter { ($0.modified ?? .distantFuture) < cutoff }
        }
    }

    var body: some View {
        ScrollView {
            GlassGroup {
                VStack(alignment: .leading, spacing: 16) {
                    // Header
                    HStack(alignment: .center, spacing: 12) {
                        IconTile(symbol: "doc.on.doc.fill", tint: Theme.indigo, size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("文件整理").font(.system(size: 21, weight: .bold))
                            Text("整理大文件、安装包、重复副本与 iCloud 本机缓存，悬停点击眼睛图标或右键可快速预览。")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.ink2)
                        }
                        Spacer(minLength: 12)
                        headerActionButton
                    }

                    // Unified Filter Bar + Clean Pill Filter (wraps gracefully on narrow windows)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            clutterTabBar
                            Spacer(minLength: 8)
                            if store.clutterTab == .large {
                                largeFileScopeBar
                            }
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            clutterTabBar
                            if store.clutterTab == .large {
                                largeFileScopeBar
                            }
                        }
                    }

                    if store.isCleaning || tools.activity != nil {
                        let labelText = store.isCleaning
                            ? "正在清理（\(store.cleanedCount)/\(max(store.cleaningTotalCount, 1))）：\(store.cleaningCurrentItem.isEmpty ? "请稍候…" : store.cleaningCurrentItem)"
                            : (tools.activity ?? "正在处理…")
                        HStack(spacing: 12) {
                            ProgressView().controlSize(.small)
                            Text(labelText)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 10)
                            ScanProgressBar(fraction: store.isCleaning && store.cleaningTotalCount > 0 ? max(0.06, Double(store.cleanedCount) / Double(store.cleaningTotalCount)) : nil,
                                            fill: Theme.accent, glow: Theme.cyan)
                                .frame(width: 120, height: 5)
                        }
                        .padding(12)
                        .glass(radius: 12)
                    }

                    switch store.clutterTab {
                    case .large:
                        fileListSection(
                            items: filteredLargeItems,
                            emptyTitle: store.largeFileScope == .all ? "暂无 100 MB 以上的大文件" : "当前筛选条件下没有大文件",
                            emptyHint: "点击右上角「扫描个人目录」检查下载、桌面、文稿与影片中的大文件。"
                        )
                    case .installers:
                        fileListSection(
                            items: installerItems,
                            emptyTitle: "未发现安装包（DMG / PKG / IPSW）",
                            emptyHint: "点击右上角「扫描个人目录」检查下载、桌面与文稿中的安装包与系统固件。"
                        )
                    case .duplicates:
                        duplicatesSection
                    case .cloud:
                        cloudSection
                    }
                }
                .padding(.horizontal, 30)
                .padding(.top, 22)
                .padding(.bottom, 28)
            }
        }
        .onAppear {
            onTabSelected(store.clutterTab)
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

    private var clutterTabBar: some View {
        HStack(spacing: 4) {
            ForEach(ClutterTab.allCases) { tab in
                let active = store.clutterTab == tab
                Button {
                    store.clutterTab = tab
                    onTabSelected(tab)
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 13, weight: active ? .semibold : .medium))
                        .foregroundStyle(active ? Theme.ink : Theme.ink2)
                        .lineLimit(1)
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

    private var largeFileScopeBar: some View {
        HStack(spacing: 6) {
            ForEach(LargeFileScope.allCases) { scope in
                let on = store.largeFileScope == scope
                Button {
                    store.largeFileScope = scope
                } label: {
                    Text(scope.rawValue)
                        .font(.system(size: 12, weight: on ? .semibold : .medium))
                        .foregroundStyle(on ? Theme.blue : Theme.ink2)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(on ? Theme.selection : Theme.fill(0.05)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var headerActionButton: some View {
        switch store.clutterTab {
        case .large:
            let visibleIDs = Set(filteredLargeItems.map(\.id))
            let picked = store.selectedItems(in: .large).filter { visibleIDs.contains($0.id) }
            if !picked.isEmpty {
                Button {
                    store.reviewCleanup(only: Set(picked.map(\.id)))
                } label: {
                    if store.isCleaning {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small).tint(.white)
                            Text("正在处理…")
                        }
                    } else {
                        Text("移到废纸篓（\(ByteFormat.string(ScanStore.cleanupSum(picked)))）")
                    }
                }
                .buttonStyle(HeroButtonStyle())
                .disabled(store.isCleaning)
            } else {
                Button("扫描个人目录") {
                    store.scanOverview()
                }
                .buttonStyle(ToolbarButtonStyle(tinted: true))
                .disabled(store.isScanning || store.isCleaning)
            }
        case .installers:
            let visibleIDs = Set(installerItems.map(\.id))
            let picked = store.selectedItems(in: .large).filter { visibleIDs.contains($0.id) }
            if !picked.isEmpty {
                Button {
                    store.reviewCleanup(only: Set(picked.map(\.id)))
                } label: {
                    if store.isCleaning {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small).tint(.white)
                            Text("正在处理…")
                        }
                    } else {
                        Text("移到废纸篓（\(ByteFormat.string(ScanStore.cleanupSum(picked)))）")
                    }
                }
                .buttonStyle(HeroButtonStyle())
                .disabled(store.isCleaning)
            } else {
                Button("扫描个人目录") {
                    store.scanOverview()
                }
                .buttonStyle(ToolbarButtonStyle(tinted: true))
                .disabled(store.isScanning || store.isCleaning)
            }
        case .duplicates:
            if let groups = tools.results?.groups, !groups.isEmpty {
                let extraBytes = groups.reduce(Int64(0)) { sum, g in
                    sum + Int64(max(0, g.files.count - 1)) * (g.files.first?.bytes ?? 0)
                }
                Button {
                    tools.requestSmartDeduplicate()
                } label: {
                    if tools.activity != nil {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small).tint(.white)
                            Text("正在处理…")
                        }
                    } else {
                        Text("智能清理多余副本（\(ByteFormat.string(extraBytes))）")
                    }
                }
                .buttonStyle(HeroButtonStyle())
                .disabled(tools.activity != nil)
            } else {
                Button("扫描指定文件夹…", action: tools.chooseFolder)
                    .buttonStyle(ToolbarButtonStyle(tinted: true))
                    .disabled(tools.activity != nil)
            }
        case .cloud:
            if let items = tools.cloudItems, !items.isEmpty {
                let total = items.reduce(0) { $0 + $1.bytes }
                Button {
                    tools.requestEvictAllCloud()
                } label: {
                    if tools.activity != nil {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small).tint(.white)
                            Text("正在处理…")
                        }
                    } else {
                        Text("全部释放本机空间（\(ByteFormat.string(total))）")
                    }
                }
                .buttonStyle(HeroButtonStyle())
                .disabled(tools.activity != nil)
            } else {
                Button("刷新列表") {
                    tools.refreshCloudItems(force: true)
                }
                .buttonStyle(ToolbarButtonStyle(tinted: true))
                .disabled(tools.isScanningCloud)
            }
        }
    }

    private func onTabSelected(_ tab: ClutterTab) {
        if tab == .duplicates {
            tools.scanDefaultDuplicatesIfNeeded()
        } else if tab == .cloud {
            tools.refreshCloudItems()
        }
    }

    private func fileListSection(items: [ScanItem], emptyTitle: String, emptyHint: String) -> some View {
        Group {
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundStyle(Theme.ink3)
                    Text(emptyTitle).font(.system(size: 15, weight: .semibold))
                    Text(emptyHint).font(.system(size: 13)).foregroundStyle(Theme.ink2)
                }
                .frame(maxWidth: .infinity, minHeight: 240)
                .appleGroupedCard(radius: 14)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { InsetHairlineDivider(leading: 54) }
                        let canPick = store.isSelectable(item)
                        let picked = store.isPicked(item.id)
                        let hovered = hover.id == item.id
                        HStack(spacing: 12) {
                            if canPick {
                                ToolCheckbox(on: picked, amber: true)
                                    .onTapGesture { store.toggleSelection(item) }
                            } else {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.ink3)
                                    .frame(width: 18)
                            }
                            Image(nsImage: ItemPresentation.icon(forPath: item.url.path))
                                .resizable()
                                .frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 8) {
                                    Text(item.name)
                                        .font(.system(size: 13.5, weight: .semibold))
                                        .lineLimit(1)
                                    if item.note.hasPrefix("已安装") {
                                        ToolTag(text: "已安装", tint: Theme.green)
                                    }
                                }
                                Text(cleanSubtitle(for: item))
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.ink2)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 10)
                            HStack(spacing: 8) {
                                Button("快速预览", systemImage: "eye") {
                                    QuickLookPreviewController.shared.preview(item.url)
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.ink2)
                                .help("快速预览（Quick Look）")

                                Button("在访达中显示", systemImage: "folder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.ink2)
                                .help("在访达中显示")
                            }
                            .frame(width: 48, alignment: .trailing)
                            .opacity(hovered ? 1 : 0)
                            .allowsHitTesting(hovered)

                            Text(ByteFormat.string(item.bytes))
                                .font(.system(size: 13.5, weight: .semibold))
                                .monospacedDigit()
                                .frame(width: 80, alignment: .trailing)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(picked ? Theme.amber.opacity(0.08) : (hovered ? Theme.selection.opacity(0.4) : .clear))
                        .contentShape(Rectangle())
                        .onHover { hover.update(item.id, inside: $0) }
                        .onTapGesture {
                            if canPick { store.toggleSelection(item) }
                        }
                        .contextMenu {
                            Button("快速预览") { QuickLookPreviewController.shared.preview(item.url) }
                            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                        }
                    }
                }
                .appleGroupedCard(radius: 14)
            }
        }
    }

    private var duplicatesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconTile(symbol: "square.on.square", tint: Theme.blue, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tools.folder.map { "已扫描：\(ToolText.short($0))" } ?? "自动扫描下载、桌面、文稿与图片中的重复文件（≥ 10 MB）")
                        .font(.system(size: 14, weight: .semibold))
                    Text("按字节、首尾采样与 SHA-256 三级精确校验内容，清理时始终保留一份。")
                        .font(.system(size: 12)).foregroundStyle(Theme.ink2)
                }
                Spacer(minLength: 10)
                Button("重新检查") { tools.rescanDuplicates() }
                    .buttonStyle(ToolbarButtonStyle(tinted: false))
                    .disabled(tools.activity != nil)
                Button("换文件夹…", action: tools.chooseFolder)
                    .buttonStyle(ToolbarButtonStyle(tinted: false))
                    .disabled(tools.activity != nil)
            }

            if let activity = tools.activity {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(activity).font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                    Button("取消", action: tools.cancelDuplicateScan).buttonStyle(ToolbarButtonStyle(tinted: false))
                }
            } else if let result = tools.results {
                if result.groups.isEmpty {
                    Text("未发现重复的大文件。")
                        .font(.system(size: 13)).foregroundStyle(Theme.ink2)
                        .padding(.vertical, 12)
                } else {
                    Text("共找到 \(result.groups.count) 组内容完全相同的文件：")
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.ink2)
                    VStack(spacing: 0) {
                        ForEach(Array(result.groups.enumerated()), id: \.element.id) { idx, group in
                            if idx > 0 { InsetHairlineDivider(leading: 14) }
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(group.files.count) 份相同文件 · 每份 \(ByteFormat.string(group.files[0].bytes))")
                                    .font(.system(size: 13, weight: .semibold))
                                ForEach(group.files) { file in
                                    HStack(spacing: 8) {
                                        Text(ToolText.short(file.url))
                                            .font(.system(size: 12.5))
                                            .lineLimit(1).truncationMode(.middle)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Button("快速预览", systemImage: "eye") {
                                            QuickLookPreviewController.shared.preview(file.url)
                                        }
                                        .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(Theme.ink2)
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
                            .padding(14)
                        }
                    }
                    .appleGroupedCard(radius: 12)
                }
            }

            if let msg = tools.message {
                Text(msg).font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
            }
        }
        .padding(16)
        .appleGroupedCard(radius: 14)
    }

    private var cloudSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconTile(symbol: "icloud.and.arrow.down", tint: Theme.blue, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("iCloud 云盘已下载的本机大文件（≥ 20 MB）").font(.system(size: 14, weight: .semibold))
                    Text("仅移除已同步文件的本机占用，云端完整保留，下次打开自动下载。")
                        .font(.system(size: 12)).foregroundStyle(Theme.ink2)
                }
                Spacer(minLength: 10)
                Button("选择特定文件…", action: tools.chooseCloudFile)
                    .buttonStyle(ToolbarButtonStyle(tinted: false))
                    .disabled(tools.activity != nil)
            }

            if tools.isScanningCloud {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在扫描 iCloud 本机副本…").font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                }
                .padding(.vertical, 12)
            } else if let items = tools.cloudItems {
                if items.isEmpty {
                    Text("当前没有占用较多空间的可释放 iCloud 本机副本。")
                        .font(.system(size: 13)).foregroundStyle(Theme.ink2)
                        .padding(.vertical, 12)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                            if idx > 0 { InsetHairlineDivider(leading: 48) }
                            HStack(spacing: 12) {
                                Image(nsImage: ItemPresentation.icon(forPath: item.url.path))
                                    .resizable().frame(width: 24, height: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                                    Text(ToolText.short(item.url.deletingLastPathComponent()))
                                        .font(.system(size: 12)).foregroundStyle(Theme.ink2).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 8)
                                Text(ByteFormat.string(item.bytes)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                                Button("快速预览", systemImage: "eye") {
                                    QuickLookPreviewController.shared.preview(item.url)
                                }
                                .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(Theme.ink2)
                                Button("释放本机") { tools.requestEvict(item) }
                                    .buttonStyle(ToolbarButtonStyle(tinted: false))
                                    .disabled(tools.activity != nil)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }
                    }
                    .appleGroupedCard(radius: 12)
                }
            }

            if let msg = tools.message {
                Text(msg).font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
            }
        }
        .padding(16)
        .appleGroupedCard(radius: 14)
    }

    private func cleanSubtitle(for item: ScanItem) -> String {
        let dir = ToolText.short(item.url.deletingLastPathComponent())
        if let mod = item.modified {
            let days = Int(Date().timeIntervalSince(mod) / 86_400)
            let ago = days >= 365 ? "\(days / 365) 年前修改"
                : (days >= 30 ? "\(days / 30) 个月前修改"
                : (days >= 1 ? "\(days) 天前修改" : "今天修改"))
            return "\(dir) · \(ago)"
        }
        return dir
    }
}
