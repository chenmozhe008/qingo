import AppKit
import SwiftUI

/// Interactive Space Lens drill-down store powered by `FastSizeCalculator`.
/// Lets users explore any folder layer-by-layer with semantic labels and safe contextual actions.
@MainActor
final class SpaceLensStore: ObservableObject {
    @Published var isPresented = false
    @Published var showCategoryMap = false
    @Published private(set) var currentDirectory: URL
    @Published private(set) var breadcrumbs: [URL] = []
    @Published private(set) var entries: [FastSizeCalculator.ChildEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?
    @Published var pendingTrash: FastSizeCalculator.ChildEntry?
    @Published private(set) var collector: [FastSizeCalculator.ChildEntry] = []
    @Published var confirmCollectorTrash = false

    var collectorBytes: Int64 {
        collector.reduce(0) { sum, item in
            let add = sum.addingReportingOverflow(item.bytes)
            return add.overflow ? Int64.max : add.partialValue
        }
    }

    func isInCollector(_ entry: FastSizeCalculator.ChildEntry) -> Bool {
        collector.contains { $0.id == entry.id }
    }

    func toggleCollector(_ entry: FastSizeCalculator.ChildEntry) {
        if let idx = collector.firstIndex(where: { $0.id == entry.id }) {
            collector.remove(at: idx)
            return
        }
        guard !entry.isMeasuring, canOfferTrash(for: entry) else { return }
        let candidatePath = CanonicalPath.url(entry.url).path
        if collector.contains(where: { candidatePath.hasPrefix(CanonicalPath.url($0.url).path + "/") }) {
            message = "「\(entry.name)」的父级文件夹已在批量删除清单中。"
            return
        }
        collector.removeAll { CanonicalPath.url($0.url).path.hasPrefix(candidatePath + "/") }
        collector.append(entry)
    }

    func clearCollector() {
        collector.removeAll()
    }

    func trashCollectorConfirmed() {
        confirmCollectorTrash = false
        let items = collector
        guard !items.isEmpty else { return }
        var movedLog: [(url: URL, bytes: Int64)] = []
        var removedIDs: Set<URL> = []
        var failed = 0
        for entry in items {
            guard canOfferTrash(for: entry) else { failed += 1; continue }
            do {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: entry.url, resultingItemURL: &resulting)
                movedLog.append((entry.url, entry.bytes))
                removedIDs.insert(entry.id)
            } catch {
                failed += 1
            }
        }
        entries.removeAll { removedIDs.contains($0.id) }
        collector.removeAll { removedIDs.contains($0.id) }
        if !movedLog.isEmpty {
            CleanupLog.record("空间透视批量清理", moved: movedLog, failedCount: failed)
        }
        let freed = movedLog.reduce(Int64(0)) { $0 + $1.bytes }
        message = failed == 0
            ? "已将清单中的 \(movedLog.count) 项（约 \(ByteFormat.string(freed))）移到废纸篓。"
            : "已移走 \(movedLog.count) 项，\(failed) 项未能移到废纸篓。"
    }

    let rootHome: URL
    let policy: SafetyPolicy
    private var loadTask: Task<Void, Never>?

    init(home: URL = AppHome.url, policy: SafetyPolicy = SafetyPolicy()) {
        self.rootHome = CanonicalPath.url(home)
        self.currentDirectory = self.rootHome
        self.policy = policy
    }

    var totalBytes: Int64 {
        entries.reduce(0) { $0 + $1.bytes }
    }

    func open(at directory: URL? = nil) {
        let target = CanonicalPath.url(directory ?? rootHome)
        isPresented = true
        navigate(to: target)
    }

    func navigate(to directory: URL) {
        loadTask?.cancel()
        let target = CanonicalPath.url(directory)
        currentDirectory = target
        breadcrumbs = buildBreadcrumbs(for: target)
        entries = []
        message = nil
        isLoading = true
        loadTask = Task { [weak self] in
            let initial = await Task.detached(priority: .utility) {
                FastSizeCalculator.listImmediateChildren(of: target)
            }.value
            guard !Task.isCancelled, let self, self.currentDirectory == target else { return }
            self.entries = initial
            var byID = Dictionary(uniqueKeysWithValues: initial.map { ($0.id, $0) })
            var lastFlush = Date()
            let stream = FastSizeCalculator.childrenSizeStream(of: target, entries: initial)
            for await measured in stream {
                if Task.isCancelled || self.currentDirectory != target { return }
                if measured.bytes == 0 {
                    byID.removeValue(forKey: measured.id)
                } else {
                    byID[measured.id] = measured
                }
                let now = Date()
                if now.timeIntervalSince(lastFlush) >= 0.22 {
                    lastFlush = now
                    self.entries = Self.sortedEntries(Array(byID.values))
                }
            }
            guard !Task.isCancelled, self.currentDirectory == target else { return }
            self.entries = Self.sortedEntries(byID.values.filter { $0.bytes > 0 })
            self.isLoading = false
        }
    }

    private static func sortedEntries(_ items: [FastSizeCalculator.ChildEntry]) -> [FastSizeCalculator.ChildEntry] {
        items.sorted { lhs, rhs in
            if lhs.isMeasuring != rhs.isMeasuring { return !lhs.isMeasuring }
            if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func canOfferTrash(for entry: FastSizeCalculator.ChildEntry) -> Bool {
        guard !policy.isProtected(entry.url), !policy.hasProtectedDescendant(entry.url) else { return false }
        let path = CanonicalPath.url(entry.url).path
        // Never allow trashing top-level system or home-critical directories directly from Space Lens.
        let forbidden = [
            rootHome.path,
            rootHome.appending(path: "Library").path,
            rootHome.appending(path: "Applications").path,
            "/Applications", "/Library", "/System", "/Users"
        ]
        return !forbidden.contains(path)
    }

    func trashConfirmed(_ entry: FastSizeCalculator.ChildEntry) {
        pendingTrash = nil
        guard canOfferTrash(for: entry) else {
            message = "受保护路径无法直接移到废纸篓。"
            return
        }
        do {
            var resulting: NSURL?
            try FileManager.default.trashItem(at: entry.url, resultingItemURL: &resulting)
            entries.removeAll { $0.id == entry.id }
            let trashedPath = CanonicalPath.url(entry.url).path
            collector.removeAll { item in
                let p = CanonicalPath.url(item.url).path
                return p == trashedPath || p.hasPrefix(trashedPath + "/")
            }
            CleanupLog.record("空间透视清理", moved: [(entry.url, entry.bytes)], failedCount: 0)
            message = "已将「\(Self.semanticTitle(for: entry.url, home: rootHome))」移到废纸篓。"
        } catch {
            message = "无法移到废纸篓：\(error.localizedDescription)"
        }
    }

    private func buildBreadcrumbs(for target: URL) -> [URL] {
        var chain: [URL] = []
        var cursor = target
        let homePath = rootHome.path
        while true {
            chain.append(cursor)
            if cursor.path == homePath || cursor.path == "/" { break }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { break }
            cursor = parent
        }
        return chain.reversed()
    }

    static func semanticTitle(for url: URL, home: URL) -> String {
        if url.path == home.path { return "个人文件夹" }
        let map: [String: String] = [
            "Desktop": "桌面",
            "Documents": "文稿",
            "Downloads": "下载",
            "Movies": "影片",
            "Music": "音乐",
            "Pictures": "图片",
            "Library": "资源库",
            "Applications": "应用程序",
            "Caches": "应用缓存",
            "Application Support": "应用支持数据",
            "Containers": "沙盒应用容器",
            "Developer": "开发者工具与模拟器"
        ]
        return map[url.lastPathComponent] ?? url.lastPathComponent
    }
}

/// Inline interactive Space Lens drill-down view embedded directly inside the 「空间」 workbench.
struct SpaceLensInlineView: View {
    @ObservedObject var store: SpaceLensStore
    @ObservedObject private var hover = HoverTracker()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Breadcrumbs only (single refresh lives in page header)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(store.breadcrumbs.enumerated()), id: \.element) { idx, url in
                        if idx > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.ink3)
                        }
                        Button(SpaceLensStore.semanticTitle(for: url, home: store.rootHome)) {
                            store.navigate(to: url)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: idx == store.breadcrumbs.count - 1 ? .semibold : .regular))
                        .foregroundStyle(idx == store.breadcrumbs.count - 1 ? Theme.ink : Theme.blue)
                    }
                }
            }

            if store.isLoading && store.entries.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在读取目录…").foregroundStyle(Theme.ink2)
                }
                .frame(maxWidth: .infinity, minHeight: 340, alignment: .center)
            } else if store.entries.isEmpty {
                Text("当前目录没有可统计的占用项。")
                    .foregroundStyle(Theme.ink2)
                    .frame(maxWidth: .infinity, minHeight: 340, alignment: .center)
            } else {
                let total = max(store.totalBytes, 1)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(store.entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            InsetHairlineDivider(leading: 42)
                        }
                        let share = entry.isMeasuring ? 0.02 : min(max(Double(entry.bytes) / Double(total), 0.01), 1.0)
                        let badge = semanticBadge(for: entry)
                        let hovered = hover.id == entry.id
                        let inBasket = store.isInCollector(entry)
                        let canTrash = store.canOfferTrash(for: entry) && !entry.isMeasuring
                        HStack(spacing: 12) {
                            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                                .foregroundStyle(entry.isDirectory ? Theme.blue : Theme.ink2)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(SpaceLensStore.semanticTitle(for: entry.url, home: store.rootHome))
                                        .font(.system(size: 13.5, weight: .medium))
                                        .lineLimit(1)
                                    if let badge {
                                        Text(badge.label)
                                            .font(.system(size: 10.5, weight: .medium))
                                            .foregroundStyle(badge.tint)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(badge.tint.opacity(0.12)))
                                    }
                                    if entry.isDirectory {
                                        Text("›")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(Theme.ink3)
                                    }
                                    Spacer(minLength: 0)
                                }
                                GeometryReader { geo in
                                    RoundedRectangle(cornerRadius: 2.5)
                                        .fill(entry.isMeasuring ? Theme.fill(0.12) : Theme.blue.opacity(0.32))
                                        .frame(width: max(5, geo.size.width * share), height: 4)
                                }
                                .frame(height: 4)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if entry.isDirectory {
                                    store.navigate(to: entry.url)
                                } else {
                                    QuickLookPreviewController.shared.preview(entry.url)
                                }
                            }

                            HStack(spacing: 6) {
                                Button("快速预览", systemImage: "eye") {
                                    QuickLookPreviewController.shared.preview(entry.url)
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.ink2)
                                .frame(width: 18, height: 18)
                                .opacity(hovered && !entry.isDirectory ? 1 : 0)
                                .allowsHitTesting(hovered && !entry.isDirectory)
                                .help("快速预览（Quick Look）")

                                Button("在访达中显示", systemImage: "folder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.ink2)
                                .frame(width: 18, height: 18)
                                .opacity(hovered ? 1 : 0)
                                .allowsHitTesting(hovered)
                                .help("在访达中显示")

                                Button {
                                    store.toggleCollector(entry)
                                } label: {
                                    Text(inBasket ? "已选 ✓" : "+ 清单")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(inBasket ? Theme.blue : Theme.ink)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(
                                            Capsule().fill(inBasket ? Theme.blue.opacity(0.16) : Theme.fill(0.08))
                                        )
                                        .overlay(
                                            Capsule().strokeBorder(inBasket ? Theme.blue.opacity(0.4) : Theme.line)
                                        )
                                }
                                .buttonStyle(.plain)
                                .opacity(canTrash && (hovered || inBasket) ? 1 : 0)
                                .allowsHitTesting(canTrash && (hovered || inBasket))
                                .help(inBasket ? "从批量删除清单移除" : "加入批量删除清单，稍后统一移到废纸篓")

                                Button("移到废纸篓", systemImage: "trash") {
                                    store.pendingTrash = entry
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.amber)
                                .frame(width: 18, height: 18)
                                .opacity(canTrash && hovered ? 1 : 0)
                                .allowsHitTesting(canTrash && hovered)
                                .help("移到废纸篓")
                            }
                            .frame(width: 136, height: 22, alignment: .trailing)

                            Group {
                                if entry.isMeasuring {
                                    Text("统计中…")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.ink3)
                                } else {
                                    Text(ByteFormat.string(entry.bytes))
                                        .font(.system(size: 13.5, weight: .semibold))
                                        .monospacedDigit()
                                }
                            }
                            .frame(width: 80, alignment: .trailing)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovered ? Theme.selection.opacity(0.45) : .clear))
                        .contentShape(Rectangle())
                        .onHover { hover.update(entry.id, inside: $0) }
                        .contextMenu {
                            if !entry.isDirectory {
                                Button("快速预览") { QuickLookPreviewController.shared.preview(entry.url) }
                            }
                            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                            if store.canOfferTrash(for: entry) {
                                Button("移到废纸篓…", role: .destructive) { store.pendingTrash = entry }
                            }
                        }
                    }
                }
                .frame(minHeight: 340, alignment: .top)
            }

            if !store.collector.isEmpty {
                HStack(spacing: 12) {
                    IconTile(symbol: "tray.full.fill", tint: Theme.blue, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("批量删除清单 · 已选 \(store.collector.count) 项")
                            .font(.system(size: 13.5, weight: .bold))
                            .monospacedDigit()
                        Text(store.collector.map(\.name).joined(separator: "、"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.ink2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 10)
                    Button("清空") { store.clearCollector() }
                        .buttonStyle(ToolbarButtonStyle(tinted: false))
                    Button("全部移到废纸篓（\(ByteFormat.string(store.collectorBytes))）") {
                        store.confirmCollectorTrash = true
                    }
                    .buttonStyle(ToolbarButtonStyle(tinted: true))
                }
                .padding(12)
                .glass(radius: 13)
            }

            if let message = store.message {
                Text(message).font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
            }
        }
        .padding(16)
        .appleGroupedCard(radius: 14)
        .background {
            Color.clear
                .alert("移到废纸篓", isPresented: Binding(
                    get: { store.pendingTrash != nil },
                    set: { if !$0 { store.pendingTrash = nil } }
                ), presenting: store.pendingTrash) { entry in
                    Button("取消", role: .cancel) {}
                    Button("移到废纸篓", role: .destructive) { store.trashConfirmed(entry) }
                } message: { entry in
                    Text("将把「\(entry.name)」（约 \(ByteFormat.string(entry.bytes))）移到废纸篓，可在访达中恢复。")
                }
        }
        .background {
            Color.clear
                .alert("批量移到废纸篓", isPresented: $store.confirmCollectorTrash) {
                    Button("取消", role: .cancel) {}
                    Button("移到废纸篓", role: .destructive) { store.trashCollectorConfirmed() }
                } message: {
                    Text("将把清单中的 \(store.collector.count) 项（约 \(ByteFormat.string(store.collectorBytes))）全部移到废纸篓，可在访达中恢复。")
                }
        }
    }

    private func semanticBadge(for entry: FastSizeCalculator.ChildEntry) -> (label: String, tint: Color)? {
        guard entry.isDirectory else { return nil }
        if store.policy.cacheDescription(for: entry.url, isDirectory: true) != nil {
            return ("可清理缓存", Theme.blue)
        }
        if entry.url.lastPathComponent.contains("xinWeChat") || entry.url.lastPathComponent.contains("WeWorkMac") {
            return ("聊天受保护", Theme.green)
        }
        if store.policy.isProtected(entry.url) {
            return ("受保护", Theme.ink3)
        }
        return nil
    }
}

struct SpaceLensSheet: View {
    @ObservedObject var store: SpaceLensStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                IconTile(symbol: "square.grid.2x2", tint: Theme.blue, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("空间透视").font(.system(size: 19, weight: .bold))
                    Text("按实际占用排序，点文件夹逐层查看空间去向。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Button("完成") { store.isPresented = false }
                    .buttonStyle(ToolbarButtonStyle(tinted: true))
            }

            // Breadcrumbs
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(store.breadcrumbs.enumerated()), id: \.element) { idx, url in
                        if idx > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.ink3)
                        }
                        Button(SpaceLensStore.semanticTitle(for: url, home: store.rootHome)) {
                            store.navigate(to: url)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: idx == store.breadcrumbs.count - 1 ? .semibold : .regular))
                        .foregroundStyle(idx == store.breadcrumbs.count - 1 ? Theme.ink : Theme.blue)
                    }
                }
            }

            if store.isLoading {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在统计当前目录实际占用…").foregroundStyle(Theme.ink2)
                }
                .frame(maxWidth: .infinity, minHeight: 260, alignment: .center)
            } else if store.entries.isEmpty {
                Text("当前目录没有可统计的占用项。")
                    .foregroundStyle(Theme.ink2)
                    .frame(maxWidth: .infinity, minHeight: 260, alignment: .center)
            } else {
                let total = max(store.totalBytes, 1)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(store.entries) { entry in
                            let share = min(max(Double(entry.bytes) / Double(total), 0.01), 1.0)
                            HStack(spacing: 10) {
                                Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                                    .foregroundStyle(entry.isDirectory ? Theme.blue : Theme.ink2)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(SpaceLensStore.semanticTitle(for: entry.url, home: store.rootHome))
                                            .font(.system(size: 13, weight: .medium))
                                            .lineLimit(1)
                                        Spacer()
                                        Text(ByteFormat.string(entry.bytes))
                                            .font(.system(size: 13, weight: .semibold))
                                            .monospacedDigit()
                                    }
                                    GeometryReader { geo in
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(Theme.blue.opacity(0.28))
                                            .frame(width: max(6, geo.size.width * share), height: 5)
                                    }
                                    .frame(height: 5)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if entry.isDirectory { store.navigate(to: entry.url) }
                                }

                                Button("在访达中显示", systemImage: "folder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.ink2)

                                if store.canOfferTrash(for: entry) {
                                    Button("移到废纸篓", systemImage: "trash") {
                                        store.pendingTrash = entry
                                    }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Theme.amber)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.fill(0.05)))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.line))
                        }
                    }
                }
                .frame(height: 320)
            }

            if let message = store.message {
                Text(message).font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
            }
        }
        .padding(24)
        .frame(width: 720)
        .alert("移到废纸篓", isPresented: Binding(
            get: { store.pendingTrash != nil },
            set: { if !$0 { store.pendingTrash = nil } }
        ), presenting: store.pendingTrash) { entry in
            Button("取消", role: .cancel) {}
            Button("移到废纸篓", role: .destructive) { store.trashConfirmed(entry) }
        } message: { entry in
            Text("将把「\(entry.name)」（约 \(ByteFormat.string(entry.bytes))）移到废纸篓，可在访达中恢复。")
        }
    }

    private func semanticBadge(for entry: FastSizeCalculator.ChildEntry) -> (label: String, tint: Color)? {
        guard entry.isDirectory else { return nil }
        if store.policy.cacheDescription(for: entry.url, isDirectory: true) != nil {
            return ("可清理缓存", Theme.blue)
        }
        if entry.url.lastPathComponent.contains("xinWeChat") || entry.url.lastPathComponent.contains("WeWorkMac") {
            return ("聊天受保护", Theme.green)
        }
        if store.policy.isProtected(entry.url) {
            return ("受保护", Theme.ink3)
        }
        return nil
    }
}
