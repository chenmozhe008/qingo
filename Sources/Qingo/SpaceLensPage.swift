import AppKit
import SwiftUI

/// Page 2: Pure, focused Apple Storage + DaisyDisk–style Space Lens.
/// Does ONE job brilliantly: shows where disk space went and lets the user drill down layer-by-layer.
struct SpaceLensPage: View {
    enum Mode: String, CaseIterable, Identifiable {
        case directory = "按目录"
        case category = "按分类"
        var id: String { rawValue }
    }

    @ObservedObject var store: ScanStore
    @ObservedObject private var lens: SpaceLensStore

    init(store: ScanStore) {
        self.store = store
        self.lens = store.spaceLens
    }

    private var isExternalVolume: Bool {
        CanonicalPath.url(lens.currentDirectory).path.hasPrefix("/Volumes/")
    }

    private var capacity: (total: Int64, free: Int64)? {
        let target = lens.showCategoryMap ? store.policy.home : lens.currentDirectory
        return store.volumeCapacity(for: target)
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                GlassGroup {
                    VStack(alignment: .leading, spacing: 16) {
                        // Header
                        HStack(alignment: .center, spacing: 12) {
                            IconTile(symbol: "chart.pie.fill", tint: Theme.violet, size: 38)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("空间透视").font(.system(size: 21, weight: .bold))
                                if let cap = capacity, cap.total > 0 {
                                    let used = max(cap.total - cap.free, 0)
                                    let prefix = lens.showCategoryMap ? "内置启动盘 · " : ""
                                    Text("\(prefix)共 \(ByteFormat.string(cap.total))，已用 \(ByteFormat.string(used))，可用 \(ByteFormat.string(cap.free))")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Theme.ink2)
                                        .monospacedDigit()
                                } else {
                                    Text("查看整台 Mac 与外接磁盘的真实空间去向，支持按分类色块或按目录逐层深入。")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Theme.ink2)
                                }
                            }
                            Spacer(minLength: 12)
                            Picker("", selection: Binding(
                                get: { lens.showCategoryMap ? Mode.category : Mode.directory },
                                set: { lens.showCategoryMap = ($0 == .category) }
                            )) {
                                ForEach(Mode.allCases) { item in
                                    Text(item.rawValue).tag(item)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 148)
                            Button(store.measuringSpaceMap != nil || lens.isLoading ? "正在统计…" : "重新统计") {
                                if lens.showCategoryMap || !isExternalVolume {
                                    store.measureSpaceMap()
                                }
                                if !lens.showCategoryMap {
                                    lens.navigate(to: lens.currentDirectory)
                                }
                            }
                            .buttonStyle(ToolbarButtonStyle(tinted: true))
                            .disabled(store.measuringSpaceMap != nil || lens.isLoading)
                        }

                        if lens.showCategoryMap {
                            SpaceMapPage(store: store, embedded: true, embeddedCompact: proxy.size.width < 920)
                        } else {
                        // Volume / Folder Picker (replaces bloated sidebar volume list)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                volumeChip(title: "个人文件夹", icon: "house.fill", url: store.policy.home)
                                volumeChip(title: "应用程序", icon: "app.badge.fill", url: URL(fileURLWithPath: "/Applications"))
                                ForEach(store.externalVolumes, id: \.self) { vol in
                                    volumeChip(title: vol.lastPathComponent, icon: "externaldrive.fill", url: vol)
                                }
                                ForEach(store.savedFolders, id: \.self) { folder in
                                    volumeChip(title: folder.lastPathComponent, icon: "folder.fill", url: folder)
                                }
                                Button {
                                    chooseExploreFolder()
                                } label: {
                                    Label("选择文件夹…", systemImage: "plus")
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundStyle(Theme.ink2)
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 6)
                                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.fill(0.05)))
                                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line))
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        // Apple Storage–style capacity bar only for startup disk (prevents mixing startup & external disk data)
                        if !isExternalVolume, let map = store.spaceMap {
                            storageSummaryBar(map)
                        }

                        // Direct Interactive Drill-Down Explorer (zero popups!)
                        SpaceLensInlineView(store: lens)
                    }
                }
                .padding(.horizontal, 30)
                .padding(.top, 22)
                .padding(.bottom, 28)
            }
        }
        }
        .onAppear {
            if lens.entries.isEmpty && !lens.isLoading {
                lens.navigate(to: store.policy.home)
            }
            if store.spaceMap == nil && store.measuringSpaceMap == nil {
                store.measureSpaceMap()
            }
        }
    }

    private func volumeChip(title: String, icon: String, url: URL) -> some View {
        let canonical = CanonicalPath.url(url).path
        let current = CanonicalPath.url(lens.currentDirectory).path
        let active = current == canonical || (canonical != store.policy.home.path && current.hasPrefix(canonical + "/"))
        return Button {
            lens.navigate(to: url)
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 12.5, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? Theme.blue : Theme.ink)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(active ? Theme.selection : Theme.fill(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(active ? Theme.blue.opacity(0.35) : Theme.line))
        }
        .buttonStyle(.plain)
    }

    private func storageSummaryBar(_ map: SpaceMap) -> some View {
        let total = max(map.total, 1)
        let cleanable = ScanStore.cleanupSum(store.eligibleItems)
        let decide = map.blocks.filter { $0.section == .decide }.reduce(Int64(0)) { $0 + $1.bytes }
        let fixed = map.blocks.filter { $0.section == .fixed }.reduce(Int64(0)) { $0 + $1.bytes } + map.remainder(cleanable: cleanable)
        return VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                let w = max(geo.size.width, 1)
                HStack(spacing: 2) {
                    if cleanable > 0 {
                        RoundedRectangle(cornerRadius: 4).fill(Theme.blue)
                            .frame(width: max(6, w * CGFloat(cleanable) / CGFloat(total)))
                    }
                    if decide > 0 {
                        RoundedRectangle(cornerRadius: 4).fill(Theme.orange)
                            .frame(width: max(6, w * CGFloat(decide) / CGFloat(total)))
                    }
                    if fixed > 0 {
                        RoundedRectangle(cornerRadius: 4).fill(Theme.violet.opacity(0.75))
                            .frame(width: max(6, w * CGFloat(fixed) / CGFloat(total)))
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 11)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.fill(0.08)))
            .clipShape(RoundedRectangle(cornerRadius: 5))

            HStack(spacing: 18) {
                legendDot("可清理缓存", cleanable, Theme.blue)
                legendDot("文稿、应用与数据", decide, Theme.orange)
                legendDot("系统与隐藏数据", fixed, Theme.violet.opacity(0.75))
                Spacer()
                Text("可用 \(ByteFormat.string(capacity?.free ?? map.available))")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.blue)
                    .monospacedDigit()
            }
        }
        .padding(14)
        .appleGroupedCard(radius: 13)
    }

    private func legendDot(_ title: String, _ bytes: Int64, _ color: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2.5).fill(color).frame(width: 9, height: 9)
            Text("\(title) \(ByteFormat.string(bytes))")
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink2)
                .monospacedDigit()
        }
    }

    private func chooseExploreFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "查看"
        if panel.runModal() == .OK, let url = panel.url {
            store.addSavedFolder(url)
            lens.navigate(to: url)
        }
    }
}
