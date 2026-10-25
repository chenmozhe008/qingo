import AppKit
import SwiftUI

private enum BrandAsset {
    static let icon = Bundle.main.url(forResource: "AppIcon-source", withExtension: "png")
        .flatMap(NSImage.init(contentsOf:))
}

struct MainView: View {
    @ObservedObject var store: ScanStore

    var hasResult: Bool { store.result != nil && !store.isScanning }
    var showSidebar: Bool { !store.isScanning && (store.result != nil || store.hasHistory || store.tool != nil) }
    var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    var body: some View {
        HStack(spacing: 0) {
            if showSidebar {
                sidebar
                    .frame(width: 260)
                    .background(Theme.panel)
                    .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
            }
            Group {
                if let tool = store.tool, !store.isScanning {
                    switch tool {
                    case .uninstall: UninstallView(store: store.uninstaller, appearance: store.appearance)
                    case .dev: DevProjectsView(store: store.dev, appearance: store.appearance)
                    }
                } else if store.isScanning {
                    scanningView
                } else if let result = store.result {
                    resultView(result)
                } else if store.hasHistory {
                    readyView
                } else {
                    welcomeView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(Theme.ink)
        .background(Backdrop(warm: (volumeCapacity(home)?.free ?? .max) < Self.lowSpaceBytes))
        .ignoresSafeArea(.container, edges: .top)
        .background(WindowDragEnabler())
        .sheet(isPresented: $store.showTrashConfirmation) { cleanupReviewSheet }
        .overlay {
            if store.showAbout {
                AboutView(store: store).transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: store.showAbout)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshFullDiskAccess()
        }
        .onAppear { store.appearance.apply() }
    }

    // MARK: Welcome

    private var welcomeView: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 48)
            brandIcon(150)
                .shadow(color: Theme.blue.opacity(0.7), radius: 34, y: 18)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("小清").font(.system(size: 20, weight: .bold))
                Text("Mac 清理工具").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.ink2)
            }
            .padding(.top, 22)
            Text("查看磁盘空间占用")
                .font(.system(size: 34, weight: .bold))
                .padding(.top, 10)
            Text("扫描只读取、不修改文件。只列出可自动重建的缓存。")
                .font(.system(size: 14))
                .foregroundStyle(Theme.ink2)
                .padding(.top, 10)
            Button { store.scanKnownCaches() } label: { Label("快速扫描", systemImage: "bolt.fill") }
                .buttonStyle(HeroButtonStyle())
                .keyboardShortcut(.defaultAction)
                .padding(.top, 34)
            HStack(spacing: 18) {
                Text("或").foregroundStyle(Theme.ink2)
                Button("完整扫描") { store.scanLocation(home) }
                ForEach(store.savedFolders, id: \.self) { folder in
                    Button(folder.lastPathComponent) { store.scanLocation(folder) }
                }
                Button("添加文件夹…") { store.chooseFolder() }
            }
            .buttonStyle(LinkButtonStyle())
            .font(.system(size: 13.5))
            .padding(.top, 34)
            if let message = store.message {
                Text(message).font(.system(size: 12.5)).foregroundStyle(Theme.ink3).padding(.top, 14)
            }
            if !store.hasFullDiskAccess {
                Button { store.openFullDiskAccessSettings() } label: {
                    Label("开启完全磁盘访问，查看更完整的占用情况", systemImage: "exclamationmark.shield.fill")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.amber)
                }
                .buttonStyle(.plain)
                .padding(.top, 14)
            }
            Spacer(minLength: 30)
            HStack(spacing: 16) {
                diskCard(home, name: "Mac 内置盘", icon: "laptopcomputer")
                ForEach(otherVolumes, id: \.self) { volume in
                    diskCard(volume, name: volume.lastPathComponent, icon: "externaldrive.fill")
                }
            }
            .frame(maxWidth: 900)
            .padding(.horizontal, 40)
            Button { store.aboutTab = .intro; store.showAbout = true } label: {
                Label("关于与反馈", systemImage: "info.circle")
            }
            .buttonStyle(GhostButtonStyle())
            .padding(.top, 16)
            .padding(.bottom, 20)
        }
    }

    @ViewBuilder
    private func diskCard(_ url: URL, name: String, icon: String) -> some View {
        if let capacity = volumeCapacity(url), capacity.total > 0 {
            let low = capacity.free < Self.lowSpaceBytes
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(name, systemImage: icon)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.ink2)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ByteFormat.string(capacity.free)).font(.system(size: 22, weight: .bold)).monospacedDigit()
                        Text("可用 / \(ByteFormat.string(capacity.total))").font(.system(size: 12.5)).foregroundStyle(Theme.ink3)
                    }
                    .lineLimit(1)
                    .fixedSize()
                    GlowBar(fraction: Double(capacity.total - capacity.free) / Double(capacity.total),
                            fill: low ? Theme.warning : Theme.accent, glow: low ? Theme.orange : Theme.cyan)
                        .frame(width: 260, height: 6)
                        .padding(.top, 4)
                }
                Spacer(minLength: 8)
                Button("扫描") { store.scanLocation(url) }.buttonStyle(GhostButtonStyle())
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: 440)
            .glass(radius: 16)
        }
    }

    // MARK: Ready (location selected, not scanned yet)

    private var readyView: some View {
        let quick = store.isQuickScope
        return VStack(spacing: 0) {
            HStack {
                Text(store.scopeTitle).font(.system(size: 15, weight: .semibold))
                Text("未扫描").font(.system(size: 12.5)).foregroundStyle(Theme.ink3)
                Spacer()
            }
            .padding(.horizontal, 22)
            .frame(height: 52)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
            Spacer()
            IconTile(symbol: quick ? "bolt.fill" : "internaldrive.fill", tint: Theme.blue, size: 84)
                .shadow(color: Theme.blue.opacity(0.3), radius: 20, y: 8)
            Text(store.notScannedTitle)
                .font(.system(size: 24, weight: .bold))
                .padding(.top, 24)
            Text(quick ? "只检查常见的缓存位置，通常几秒内完成。" : "可能需要几分钟。扫描只读取，不改动任何文件。")
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.ink2)
                .padding(.top, 8)
            Button { store.scan() } label: { Text("开始扫描") }
                .buttonStyle(HeroButtonStyle())
                .keyboardShortcut(.defaultAction)
                .padding(.top, 26)
            Spacer()
            Spacer()
        }
    }

    // MARK: Scanning (live discoveries)

    private var scanningView: some View {
        HStack(spacing: 48) {
            VStack(spacing: 0) {
                // Same dial as the overview; a band of lit ticks sweeps round while scanning.
                ZStack {
                    // The overview's ring, turning: same thickness and blue, so scanning and result feel like one thing.
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        let angle = context.date.timeIntervalSinceReferenceDate * 220
                        ZStack {
                            Circle().stroke(Theme.blue.opacity(0.12), lineWidth: 30)
                            Circle()
                                .trim(from: 0, to: 0.32)
                                .stroke(AngularGradient(colors: [Theme.blue.opacity(0), Color(red: 0.50, green: 0.84, blue: 0.78), Theme.blue],
                                                        center: .center, startAngle: .degrees(0), endAngle: .degrees(115)),
                                        style: StrokeStyle(lineWidth: 30, lineCap: .round))
                                .rotationEffect(.degrees(angle))
                                .shadow(color: Theme.blue.opacity(0.3), radius: 8)
                        }
                        .padding(15)
                    }
                    VStack(spacing: 4) {
                        Text(store.progress.scannedCount.formatted())
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("项已检查").font(.system(size: 13)).foregroundStyle(Theme.ink2)
                    }
                }
                .frame(width: 290, height: 290)
                Text(store.scanningTitle)
                    .font(.system(size: 22, weight: .semibold))
                    .padding(.top, 24)
                Text(scanningPlace(store.progress.currentFolder))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 360)
                    .padding(.top, 8)
                scanProgressBar
                    .frame(width: 300, height: 6)
                    .padding(.top, 18)
                Button { store.cancelScan() } label: { Label("停止扫描", systemImage: "stop.circle.fill") }
                    .buttonStyle(ToolbarButtonStyle(large: true, tinted: true))
                    .keyboardShortcut(.cancelAction)
                    .padding(.top, 24)
            }
            .frame(width: 380)
            liveFeed
        }
        .padding(.horizontal, 56)
        .padding(.top, 70)
        .padding(.bottom, 44)
    }

    @ViewBuilder
    private var scanProgressBar: some View {
        if let estimate = store.estimatedProgress {
            GlowBar(fraction: estimate)
        } else {
            TimelineView(.animation) { context in
                GeometryReader { proxy in
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.fill(0.08))
                        Capsule().fill(Theme.accent)
                            .frame(width: proxy.size.width * 0.3)
                            .offset(x: proxy.size.width * (phase * 1.3 - 0.3))
                            .shadow(color: Theme.cyan.opacity(0.6), radius: 4)
                    }
                    .clipShape(Capsule())
                }
            }
        }
    }

    private var liveFeed: some View {
        // Only what the result will show: cleanable items and large files, not data that stays.
        let notable = store.liveFound.filter { $0.bytes >= 5_000_000 && ($0.canTrash || $0.kind == .largeFile || $0.kind == .project) }
        let recent = Array(notable.suffix(7).reversed())
        let caches = store.liveFound.filter { ItemFilter.caches.contains($0) }
        let creative = store.liveFound.filter { ItemFilter.creative.contains($0) && $0.canTrash }
        let large = store.liveFound.filter { ItemFilter.large.contains($0) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("已发现的内容")
                Spacer()
                Text("已发现 \(notable.count) 项")
            }
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.ink3)
            .padding(.horizontal, 4)
            VStack(spacing: 0) {
                if recent.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "sparkle.magnifyingglass").font(.system(size: 28)).foregroundStyle(Theme.ink3)
                        Text("扫描结果将显示在这里").font(.system(size: 13)).foregroundStyle(Theme.ink3)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ForEach(recent) { item in
                        feedRow(item)
                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(.easeOut(duration: 0.35), value: notable.count)
            .glass()
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, Theme.base.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 70)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            HStack(spacing: 10) {
                liveTotal(.caches, ByteFormat.string(ScanStore.sum(caches)))
                liveTotal(.creative, ByteFormat.string(ScanStore.sum(creative)))
                liveTotal(.large, store.isQuickScope ? "完整扫描才查" : "\(large.count) 项")
            }
        }
    }

    private func feedRow(_ item: ScanItem) -> some View {
        let info = ItemPresentation.info(for: item)
        let category = ItemFilter.allCases.first { $0.contains(item) }
        return HStack(spacing: 12) {
            itemIcon(item, info: info)
            VStack(alignment: .leading, spacing: 3) {
                Text(info.title).font(.system(size: 14, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(category?.title ?? item.kind.label)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(1)
            }
            Spacer(minLength: 10)
            Text(ByteFormat.string(item.bytes)).font(.system(size: 14, weight: .medium)).monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    /// Same tile and colour as the overview platter for that category.
    private func liveTotal(_ category: ItemFilter, _ value: String) -> some View {
        HStack(spacing: 12) {
            IconTile(symbol: Theme.symbol(category), tint: Theme.color(category), size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(category.title).font(.system(size: 12)).foregroundStyle(Theme.ink2)
                Text(value).font(.system(size: 19, weight: .semibold)).monospacedDigit()
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glass(radius: 18)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                brandIcon(38).shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text("小清").font(.system(size: 16, weight: .bold))
                    Text("Mac 清理工具").font(.system(size: 12)).foregroundStyle(Theme.ink2)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    if store.result != nil { overviewRow }
                    sectionHeader("扫描位置")
                    locationRow("快速扫描", icon: "bolt.fill", url: home, quick: true)
                    locationRow("完整扫描", icon: "internaldrive.fill", url: home, quick: false)
                    ForEach(otherVolumes, id: \.self) { volume in
                        locationRow(volume.lastPathComponent, icon: "externaldrive.fill", url: volume, quick: false)
                    }
                    ForEach(store.savedFolders, id: \.self) { folder in
                        locationRow(folder.lastPathComponent, icon: "folder.fill", url: folder, quick: false, removable: true)
                            .contextMenu {
                                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                                Button("从列表移除") { store.removeSavedFolder(folder) }
                            }
                    }
                    addFolderRow

                    sectionHeader("工具").padding(.top, 12)
                    toolRow("卸载应用", icon: "trash.fill", tint: Theme.orange, page: .uninstall)
                    toolRow("开发工程", icon: "hammer.fill", tint: Theme.indigo, page: .dev)

                    if store.result != nil {
                        sectionHeader("分类").padding(.top, 12)
                    }
                    ForEach(store.result == nil ? [] : ItemFilter.visible) { category in
                        let items = store.items(in: category)
                        switch category {
                        case .chat:
                            if let chats = store.result?.chatApps, !chats.isEmpty {
                                categoryRow(category, bytes: chats.reduce(0) { $0 + ($1.bytes ?? 0) })
                            }
                        case .creative:
                            // Only what can be cleaned counts; conversations and works are not shown.
                            if !items.isEmpty {
                                categoryRow(category, bytes: ScanStore.sum(items.filter(\.canTrash)))
                            }
                        default:
                            // Keep the sidebar in step with the six overview cards.
                            if category == .caches || category == .large || !items.isEmpty {
                                categoryRow(category, bytes: ScanStore.sum(items))
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            Divider().padding(.vertical, 8)
            permissionCard
            appearancePicker
            Button { store.aboutTab = .intro; store.showAbout = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle").font(.system(size: 16)).foregroundStyle(Theme.ink2)
                    Text("关于与反馈").font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 4)
                    Text("v\(AppInfo.version)").font(.system(size: 12)).foregroundStyle(Theme.ink3)
                }
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .padding(.top, 40)
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    private var appearancePicker: some View {
        HStack(spacing: 2) {
            ForEach(AppearanceMode.allCases) { mode in
                let on = store.appearance == mode
                Button { store.appearance = mode } label: {
                    // Words, not just icons (a half-filled circle explains nothing); the chosen one is raised, never darker.
                    Label(mode.title, systemImage: mode.symbol)
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12, weight: on ? .semibold : .medium))
                        .foregroundStyle(on ? Theme.ink : Theme.ink2)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Theme.raised : .clear)
                            .shadow(color: .black.opacity(on ? 0.12 : 0), radius: 1.5, y: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(mode == .system ? "白天浅色，夜间深色（7:00–19:00 为白天；系统外观为「自动」时跟随系统）" : "外观：\(mode.rawValue)")
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.fill(0.07)))
        .padding(.horizontal, 6)
        .padding(.top, 10)
    }

    /// Same colored tile as the categories, so the tools read as part of the app rather than plain links.
    private func toolRow(_ title: String, icon: String, tint: Color, page: ScanStore.ToolPage) -> some View {
        let active = store.tool == page
        return Button { withAnimation(.easeOut(duration: 0.15)) { store.openTool(page) } } label: {
            HStack(spacing: 10) {
                IconTile(symbol: icon, tint: tint, size: 24)
                Text(title)
                Spacer(minLength: 4)
            }
            .font(.system(size: 14))
            .foregroundStyle(active ? Theme.ink : Theme.ink2)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(active ? Theme.fill(0.13) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.isCleaning)
    }

    private var overviewRow: some View {
        let active = store.showingOverview && store.tool == nil
        return Button { withAnimation(.easeOut(duration: 0.15)) { store.showOverview() } } label: {
            HStack(spacing: 10) {
                IconTile(symbol: "gauge.with.dots.needle.67percent", tint: Theme.blue, size: 24)
                Text("总览").font(.system(size: 14, weight: active ? .semibold : .regular))
                Spacer(minLength: 4)
            }
            .foregroundStyle(active ? Theme.ink : Theme.ink2)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(active ? Theme.fill(0.13) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.ink3)
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    /// Clicking only switches to the location and shows its last result; scanning starts from the scan button.
    private func locationRow(_ title: String, icon: String, url: URL, quick: Bool, removable: Bool = false) -> some View {
        let active = store.tool == nil && store.isCurrentScope(url, quick: quick)
        let hovered = removable && store.hoveredID == url
        return Button { withAnimation(.easeOut(duration: 0.15)) { store.selectLocation(url, quick: quick) } } label: {
            HStack(spacing: 10) {
                // The location being shown keeps its colour; the others are grey. The row background is kept for
                // the page (总览, a category, a tool), so two rows never look selected at once.
                IconTile(symbol: icon, tint: active ? Theme.blue : Theme.slate.opacity(0.7), size: 24)
                Text(title).lineLimit(1).truncationMode(.middle).fontWeight(active ? .semibold : .regular)
                Spacer(minLength: 4)
                if hovered {
                    Button { store.removeSavedFolder(url) } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(Theme.ink3)
                    }
                    .buttonStyle(.plain)
                    .help("从列表移除（不会删除文件夹）")
                } else {
                    TimelineView(.everyMinute) { _ in
                        Text(store.lastScanDate(url, quick: quick).map(Self.ago) ?? "未扫描")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ink3)
                    }
                }
            }
            .font(.system(size: 14))
            .foregroundStyle(active ? Theme.ink : Theme.ink2)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.isCleaning)
        .onHover { inside in
            guard removable else { return }
            if inside { store.hoveredID = url } else if store.hoveredID == url { store.hoveredID = nil }
        }
    }

    private var addFolderRow: some View {
        Button { store.chooseFolder() } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 24 * 0.28, style: .continuous)
                    .strokeBorder(Theme.ink3.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2.5]))
                    .overlay(Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.ink3))
                    .frame(width: 24, height: 24)
                Text("添加文件夹")
                Spacer(minLength: 4)
            }
            .font(.system(size: 14))
            .foregroundStyle(Theme.ink3)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.isCleaning)
    }

    /// "刚刚 / 3 分钟前 / 2 小时前 / 昨天 / 10月18日"
    static func ago(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if Calendar.current.isDateInToday(date) { return "\(Int(seconds / 3600)) 小时前" }
        if Calendar.current.isDateInYesterday(date) { return "昨天" }
        return date.formatted(.dateTime.month().day())
    }

    private func categoryRow(_ category: ItemFilter, bytes: Int64) -> some View {
        let selected = store.tool == nil && !store.showingOverview && store.filter == category
        let tint = Theme.color(category)
        return Button { withAnimation(.easeOut(duration: 0.15)) { store.selectCategory(category) } } label: {
            HStack(spacing: 10) {
                IconTile(symbol: Theme.symbol(category), tint: tint, size: 24)
                Text(category.title).lineLimit(1)
                Spacer(minLength: 4)
                if bytes > 0 {
                    Text(ByteFormat.string(bytes))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink3)
                        .fixedSize()
                }
            }
            .font(.system(size: 14))
            .foregroundStyle(selected ? Theme.ink : Theme.ink2)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Theme.fill(0.13) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("分类：\(category.title)")
    }

    @ViewBuilder
    private var permissionCard: some View {
        if store.hasFullDiskAccess {
            Label("完全磁盘访问已开启", systemImage: "checkmark.shield.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.ink2)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label("未开启完全磁盘访问", systemImage: "exclamationmark.shield.fill")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.amber)
                Text("授权后可读取更多缓存和聊天文件的占用。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Button("前往开启") { store.openFullDiskAccessSettings() }.buttonStyle(GhostButtonStyle())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.amber.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.amber.opacity(0.3)))
        }
    }

    // MARK: Result

    private func resultView(_ result: ScanResult) -> some View {
        VStack(spacing: 0) {
            topBar(result)
            if store.showingOverview {
                overviewPage(result)
            } else if store.filter == .creative {
                creativeView(result)
            } else if store.filter == .chat {
                chatView(result)
            } else {
                VStack(spacing: 16) {
                    categoryHeader(result)
                    banners
                    listPanel
                }
                .padding(.horizontal, 30)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
        }
    }

    /// Caches and large files: what the page holds, and its own clean button (only this page's picks).
    private func categoryHeader(_ result: ScanResult) -> some View {
        let category = store.filter
        let items = store.displayedItems
        let subtitle: String = {
            if category == .large {
                if result.isQuickScan { return "1 GB 以上的大文件、安装包和工程，需手动确认后删除。" }
                return "\(items.count) 个。大文件和安装包需手动确认后删除，工程仅显示占用。"
            }
            return items.isEmpty ? "没有需要清理的缓存。" : "\(items.count) 处，清理后会在使用时自动重建。"
        }()
        return PageHeader(symbol: Theme.symbol(category), tint: Theme.color(category), title: category.title, subtitle: subtitle) {
            cleanActions(scope: category)
        }
    }

    /// "全选 / 取消全选" for what is safe, and the capsule clean button for one page's picks.
    @ViewBuilder
    private func cleanActions(scope: ItemFilter) -> some View {
        let picked = store.selectedItems(in: scope)
        let safe = store.eligibleItems.filter { scope.contains($0) }
        let allSafe = !safe.isEmpty && safe.allSatisfy { store.isPicked($0.id) }
        HStack(spacing: 16) {
            if !safe.isEmpty {
                Button(allSafe ? "取消全选" : "全选") {
                    withAnimation(.easeOut(duration: 0.15)) {
                        if allSafe { store.setGroupSelected(safe, selected: false) } else { store.setGroupSelected(safe, selected: true) }
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.blue)
                .keyboardShortcut("a", modifiers: .command)
            }
            if !store.selectableInFilter.isEmpty || !picked.isEmpty {
                Button { store.reviewCleanup(scope: scope) } label: {
                    if store.isCleaning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).tint(.white)
                            Text("正在清理 \(store.cleanedCount)/\(store.itemsToClean.count)").monospacedDigit()
                        }
                    } else {
                        Text(picked.isEmpty ? "清理" : "清理 \(ByteFormat.string(ScanStore.sum(picked)))")
                    }
                }
                .buttonStyle(HeroButtonStyle())
                .disabled(picked.isEmpty || store.isCleaning)
                .opacity(picked.isEmpty ? 0.55 : 1)
            }
        }
    }

    private func topBar(_ result: ScanResult) -> some View {
        HStack(spacing: 10) {
            if !store.showingOverview {
                Button { withAnimation(.easeOut(duration: 0.15)) { store.showOverview() } } label: {
                    Label("返回总览", systemImage: "chevron.left")
                }
                .buttonStyle(ToolbarButtonStyle(large: true, tinted: true))
                .keyboardShortcut("[", modifiers: .command)
                .help("回到总览（⌘[）")
            }
            Text(store.showingOverview ? "\(volumeName(result.root))，\(store.scopeTitle)于\(Self.ago(result.scannedAt))" : "\(Self.ago(result.scannedAt))扫描")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
            Spacer()
            Button { store.scan() } label: { Label("重新扫描", systemImage: "arrow.clockwise") }
                .buttonStyle(ToolbarButtonStyle(large: true))
                .help("重新扫描「\(store.scopeTitle)」（⌘R）")
        }
        .disabled(store.isCleaning)
        .padding(.leading, showSidebar ? 22 : 22)
        .padding(.trailing, 18)
        .frame(height: 62)
    }

    /// Below this much free space the dial and the backdrop turn warm. Ratios mislead on big disks.
    static let lowSpaceBytes: Int64 = 10 * 1_073_741_824

    // MARK: Overview

    /// Outcome first (Flighty), one glance at the state (Weather, Activity rings), the one action beside it
    /// (Things), details on demand (Storage settings): the dial, what cleaning gives you, one button, four platters.
    private func overviewPage(_ result: ScanResult) -> some View {
        // Narrow windows get a smaller ring, stacked actions and the platters two by two, so nothing is squeezed.
        GeometryReader { proxy in
            let compact = proxy.size.width < 900
            let margin: CGFloat = compact ? 28 : 40
            VStack(spacing: 0) {
                banners.padding(.horizontal, margin)
                Spacer(minLength: 6)
                HStack(alignment: .center, spacing: compact ? 30 : 48) {
                    // Free space is read live: results go stale as soon as anything is deleted.
                    TimelineView(.periodic(from: .now, by: 30)) { _ in spaceRing(result) }
                        .frame(width: compact ? 220 : 320, height: compact ? 220 : 320)
                    heroCopy(compact: compact)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, margin)
                Spacer(minLength: 14)
                platters(result, compact: compact)
                    .padding(.horizontal, margin)
                    .padding(.bottom, compact ? 20 : 26)
            }
        }
    }

    private func spaceRing(_ result: ScanResult) -> some View {
        let live = volumeCapacity(result.root)
        let free = live?.free ?? result.volumeFreeBytes ?? 0
        return SpaceRing(total: live?.total ?? result.volumeTotalBytes ?? 0, free: free, low: free < Self.lowSpaceBytes)
    }

    private func heroCopy(compact: Bool) -> some View {
        let safe = store.eligibleItems
        let titleSize: CGFloat = compact ? 28 : 36
        let actions = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14)) : AnyLayout(HStackLayout(spacing: 18))
        let selected = store.selectedCleanupBytes
        let count = store.selectedCleanupItems.count
        return VStack(alignment: .leading, spacing: 0) {
            if safe.isEmpty {
                Text("没有可清理的缓存").font(.system(size: titleSize, weight: .bold))
                Text("缓存会在使用中重新产生，可以过段时间再扫描。")
                    .font(.system(size: 14.5)).foregroundStyle(Theme.ink2).padding(.top, 12)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("\(safe.count) 处缓存，均可自动重建").font(.system(size: 13.5)).foregroundStyle(Theme.ink2)
                Text("可清理").font(.system(size: titleSize, weight: .bold)).lineLimit(1).padding(.top, 8)
                Text(ByteFormat.string(selected > 0 ? selected : ScanStore.sum(safe)))
                    .font(.system(size: titleSize, weight: .bold)).monospacedDigit().lineLimit(1).foregroundStyle(Theme.blue)
                Text("只清理可自动重建的缓存，不涉及对话、作品和设置。文件移到废纸篓，可随时恢复。")
                    .font(.system(size: 14.5)).foregroundStyle(Theme.ink2).padding(.top, 12)
                    .fixedSize(horizontal: false, vertical: true)
                actions {
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
                    .keyboardShortcut(.defaultAction)
                    Button("查看这 \(safe.count) 处 ›") { withAnimation(.easeOut(duration: 0.15)) { store.selectCategory(store.mainCleanableCategory) } }
                        .buttonStyle(.plain)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.blue)
                }
                .padding(.top, compact ? 20 : 26)
            }
        }
        .frame(maxWidth: 460, alignment: .leading)
    }

    /// The four categories, coloured like their ticks on the dial.
    private func platters(_ result: ScanResult, compact: Bool) -> some View {
        let chats = result.chatApps.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
        let caches = store.items(in: .caches).filter(\.canTrash)
        let creative = store.items(in: .creative).filter(\.canTrash)
        let large = store.items(in: .large)
        let tools = Set(creative.compactMap { CreativeApp.of($0)?.id }).count
        let grid = compact ? [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
                           : Array(repeating: GridItem(.flexible(), spacing: 14), count: 4)
        return LazyVGrid(columns: grid, spacing: 14) {
            platter(.caches, bytes: ScanStore.sum(caches), note: caches.isEmpty ? "未发现" : "\(caches.count) 处，已全选")
            platter(.creative, bytes: ScanStore.sum(creative), note: creative.isEmpty ? "暂无可清理项" : "\(tools) 个工具的缓存和日志")
            platter(.chat, bytes: chats, note: result.chatApps.isEmpty ? "未发现" : "需在微信中清理 ›", warn: chats >= 2_000_000_000)
            platter(.large, bytes: result.isQuickScan ? nil : ScanStore.sum(large),
                    note: result.isQuickScan ? "完整扫描后显示" : (large.isEmpty ? "未发现" : "\(large.count) 个，需手动确认"))
        }
    }

    private func platter(_ category: ItemFilter, bytes: Int64?, note: String, warn: Bool = false) -> some View {
        let (number, unit) = splitBytes(bytes ?? 0)
        return Button { withAnimation(.easeOut(duration: 0.15)) { store.selectCategory(category) } } label: {
            VStack(alignment: .leading, spacing: 0) {
                IconTile(symbol: Theme.symbol(category), tint: Theme.color(category), size: 30)
                Text(category.title).font(.system(size: 13)).foregroundStyle(Theme.ink2).padding(.top, 12)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(bytes == nil || bytes == 0 ? "—" : number).font(.system(size: 24, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(warn ? Theme.amber : Theme.ink)
                    if let bytes, bytes > 0 { Text(unit).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink2) }
                }
                .padding(.top, 2)
                Text(note).font(.system(size: 12)).foregroundStyle(Theme.ink3).lineLimit(1).padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .glass(radius: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var banners: some View {
        if let report = store.cleanupReport {
            cleanupReportBanner(report)
        }
        if store.cleanupReport == nil, let message = store.message {
            Label(message, systemImage: "info.circle")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Rows sharing a display name (hundreds of __pycache__) collapse into one group row.
    private struct RowGroup: Identifiable {
        let id: String
        let items: [ScanItem]
        let bytes: Int64
    }

    private func grouped(_ items: [ScanItem]) -> [RowGroup] {
        var order: [String] = []
        var buckets: [String: [ScanItem]] = [:]
        for item in items {
            let key = ItemPresentation.info(for: item).title
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }
        return order.map { RowGroup(id: $0, items: buckets[$0]!, bytes: ScanStore.sum(buckets[$0]!)) }
            .sorted { $0.bytes > $1.bytes }
    }

    private var listPanel: some View {
        let items = store.displayedItems
        let groups = grouped(items)
        let maxBytes = max(groups.map(\.bytes).max() ?? 1, 1)
        return Group {
            if items.isEmpty {
                VStack(spacing: 12) {
                    if store.filter == .large && store.isQuickScope {
                        // Quick scan never looks for large files: say so and offer the way forward.
                        IconTile(symbol: Theme.symbol(.large), tint: Theme.violet, size: 44)
                        Text("快速扫描不查找大文件和工程").font(.system(size: 15, weight: .semibold))
                        Text("完整扫描会检查整个用户目录，大约需要几分钟。").font(.system(size: 13)).foregroundStyle(Theme.ink2)
                        Button { store.scanLocation(home) } label: { Label("开始完整扫描", systemImage: "play.fill") }
                            .buttonStyle(HeroButtonStyle())
                            .padding(.top, 4)
                    } else {
                        Image(systemName: "checkmark.circle").font(.system(size: 30)).foregroundStyle(Theme.green)
                        Text(store.filter == .caches ? "未发现可清理的缓存" : "此分类没有内容").font(.system(size: 14)).foregroundStyle(Theme.ink2)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(groups) { group in
                            if group.items.count == 1 {
                                row(group.items[0], maxBytes: maxBytes)
                            } else {
                                groupRow(group, maxBytes: maxBytes)
                                if store.expandedGroups.contains(group.id) {
                                    ForEach(group.items) { item in
                                        row(item, maxBytes: group.items.map(\.bytes).max() ?? 1)
                                            .padding(.leading, 30)
                                            .background(Color.black.opacity(0.12))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glass()
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func row(_ item: ScanItem, maxBytes: Int64) -> some View {
        let expanded = store.selectedID == item.id
        let picked = store.isPicked(item.id)
        let info = ItemPresentation.info(for: item)
        // One fact per line: what to do with it. Folder name and path live in the expanded detail.
        let subtitle = tagText(item)
        let failed = store.failureReasons[item.id] != nil
        let tint = selectionTint(item)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                checkbox(item)
                itemIcon(item, info: info)
                VStack(alignment: .leading, spacing: 3) {
                    Text(info.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(failed ? Theme.amber : Theme.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 12)
                GlowBar(fraction: Double(item.bytes) / Double(maxBytes))
                    .frame(width: 90, height: 4)
                Text(ByteFormat.string(item.bytes))
                    .font(.system(size: 13.5, weight: .medium))
                    .monospacedDigit()
                    .frame(width: 80, alignment: .trailing)
                Button { toggleDetail(item) } label: {
                    Image(systemName: expanded ? "chevron.up.circle.fill" : "info.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(expanded ? Theme.cyan : Theme.ink3)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "收起详情" : "查看详情")
            }
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.note)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let cost = store.decisionNotes[item.id] {
                        Label(cost, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.amber)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 10) {
                        Text(item.url.path)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Theme.ink3)
                            .textSelection(.enabled)
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        Button("在访达中显示") { reveal(item) }.buttonStyle(GhostButtonStyle())
                    }
                }
                .padding(.leading, 74)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(rowBackground(picked: picked, expanded: expanded, tint: tint))
        .background(HoverFill(tracker: store.hover, id: item.id))
        .overlay(alignment: .leading) {
            if picked { Rectangle().fill(tint).frame(width: 3).shadow(color: tint, radius: 4) }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture {
            // Clicking anywhere on a selectable row picks it; other rows open their details.
            if store.isSelectable(item) {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { store.setCleanupSelected(item, selected: !picked) }
            } else {
                toggleDetail(item)
            }
        }
        .onHover { inside in
            store.hover.update(item.id, inside: inside)
        }
        .contextMenu {
            if store.isSelectable(item) {
                Button(picked ? "取消选择" : "选择") { store.setCleanupSelected(item, selected: !picked) }
            }
            Button(expanded ? "收起详情" : "查看详情") { toggleDetail(item) }
            Button("在访达中显示") { reveal(item) }
        }
    }

    private func groupRow(_ group: RowGroup, maxBytes: Int64) -> some View {
        let first = group.items[0]
        let info = ItemPresentation.info(for: first)
        let cleanable = group.items.filter(store.isSelectable)
        let tint = cleanable.allSatisfy(store.isDecidable) ? Theme.amber : Theme.cyan
        let pickedCount = cleanable.filter { store.isPicked($0.id) }.count
        let allPicked = !cleanable.isEmpty && pickedCount == cleanable.count
        let expanded = store.expandedGroups.contains(group.id)
        let parents = group.items.map { $0.url.deletingLastPathComponent().path }
        let common = parents.dropFirst().reduce(parents[0]) { prefix, path in
            var result = prefix
            while !(path == result || path.hasPrefix(result + "/")) { result = (result as NSString).deletingLastPathComponent }
            return result
        }
        let toggleExpanded = {
            withAnimation(.easeOut(duration: 0.18)) {
                if expanded { store.expandedGroups.remove(group.id) } else { store.expandedGroups.insert(group.id) }
            }
        }
        return HStack(spacing: 12) {
            if cleanable.isEmpty {
                Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(Theme.ink3).frame(width: 18, height: 18)
            } else {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(pickedCount > 0 ? checkFill(tint) : AnyShapeStyle(Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(pickedCount > 0 ? .clear : checkStroke(tint), lineWidth: 1.5))
                    .overlay {
                        if pickedCount > 0 {
                            Image(systemName: allPicked ? "checkmark" : "minus").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                        }
                    }
                    .frame(width: 18, height: 18)
                    .shadow(color: pickedCount > 0 ? tint.opacity(0.6) : .clear, radius: 5)
            }
            itemIcon(first, info: info)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(info.title).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                    Text("\(group.items.count) 处")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.ink2)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.fill(0.08)))
                    if pickedCount > 0 && !allPicked {
                        Text("已选 \(pickedCount)").font(.system(size: 11.5)).foregroundStyle(tint)
                    }
                }
                Text(groupLocation(parents: parents, common: common))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            GlowBar(fraction: Double(group.bytes) / Double(maxBytes))
                .frame(width: 90, height: 4)
            Text(ByteFormat.string(group.bytes))
                .font(.system(size: 13.5, weight: .medium))
                .monospacedDigit()
                .frame(width: 80, alignment: .trailing)
            Button(action: toggleExpanded) {
                Image(systemName: expanded ? "chevron.up.circle.fill" : "chevron.down.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(expanded ? Theme.cyan : Theme.ink3)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "收起" : "展开查看每一处")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(allPicked ? tint.opacity(0.08) : .clear)
        .background(HoverFill(tracker: store.hover, id: first.id))
        .overlay(alignment: .leading) {
            if pickedCount > 0 { Rectangle().fill(tint).frame(width: 3).shadow(color: tint, radius: 4) }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture {
            if cleanable.isEmpty {
                toggleExpanded()
            } else {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { store.setGroupSelected(group.items, selected: !allPicked) }
            }
        }
        .onHover { inside in
            store.hover.update(first.id, inside: inside)
        }
        .contextMenu {
            if !cleanable.isEmpty {
                Button(allPicked ? "取消选择这 \(cleanable.count) 处" : "选择这 \(cleanable.count) 处") { store.setGroupSelected(group.items, selected: !allPicked) }
            }
            Button(expanded ? "收起" : "展开查看每一处", action: toggleExpanded)
        }
    }

    /// "都在 ~/Coding 里" when one folder holds them all, otherwise the top folders holding the most.
    private func groupLocation(parents: [String], common: String) -> String {
        guard common == store.policy.home.path || common == "/" else {
            return "都在 \(shortPath(URL(fileURLWithPath: common))) 里"
        }
        var counts: [String: Int] = [:]
        for path in parents {
            let rest = path.dropFirst(common.count).split(separator: "/")
            if let top = rest.first { counts[String(top), default: 0] += 1 }
        }
        let tops = counts.sorted { $0.value > $1.value }.prefix(2).map { shortPath(URL(fileURLWithPath: common).appending(path: $0.key)) }
        return "主要在 \(tops.joined(separator: "、"))\(counts.count > 2 ? " 等处" : " 里")"
    }

    private func rowBackground(picked: Bool, expanded: Bool, tint: Color) -> Color {
        if expanded { return Theme.blue.opacity(0.14) }
        return picked ? tint.opacity(0.08) : .clear
    }

    /// Cyan for regenerable caches, amber for items the user decides about.
    private func selectionTint(_ item: ScanItem) -> Color { store.isDecidable(item) ? Theme.amber : Theme.cyan }

    private func checkFill(_ tint: Color) -> AnyShapeStyle { tint == Theme.amber ? AnyShapeStyle(Theme.amber) : AnyShapeStyle(Theme.accent) }

    private func checkStroke(_ tint: Color) -> Color { tint == Theme.amber ? Theme.amber.opacity(0.8) : Theme.ink3 }

    private func toggleDetail(_ item: ScanItem) {
        withAnimation(.easeOut(duration: 0.18)) { store.selectedID = store.selectedID == item.id ? nil : item.id }
    }

    // MARK: Creative apps

    /// Only what can safely go is listed, one card per tool. Conversations, works, models and settings are not
    /// shown as rows; one line says how much of that there is and that it stays (用户：别让用户判断).
    private func creativeView(_ result: ScanResult) -> some View {
        let items = store.items(in: .creative)
        let cleanableItems = items.filter(\.canTrash).filter { $0.bytes > 0 }
        let found = CreativeApp.allCases.filter { app in cleanableItems.contains { CreativeApp.of($0) == app } }
        let quiet = CreativeApp.allCases.filter { app in
            !found.contains(app) && (app.isInstalled || items.contains { CreativeApp.of($0) == app })
        }
        let cleanable = ScanStore.sum(cleanableItems)
        let kept = ScanStore.sum(items.filter { !$0.canTrash })
        let cards = creativeCards(cleanableItems)
        return ScrollViewReader { proxy in
        ScrollView {
            GlassGroup {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(symbol: Theme.symbol(.creative), tint: Theme.color(.creative), title: ItemFilter.creative.title,
                           subtitle: (cleanable > 0 ? "\(found.count) 个工具的缓存和日志，清理后会在下次打开时自动重建。" : "暂无可清理的内容。")
                            + (kept >= 1_000_000 ? "另有 \(ByteFormat.string(kept)) 为对话、作品和设置，不在清理范围内。" : "")) {
                    cleanActions(scope: .creative)
                }
                .padding(.bottom, 4)
                banners
                ForEach(CreativeApp.Group.allCases, id: \.self) { group in
                    let section = cards.filter { $0.group == group }
                    if !section.isEmpty {
                        HStack(alignment: .firstTextBaseline) {
                            Text(group.rawValue).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink2)
                            Spacer()
                            Text(ByteFormat.string(ScanStore.sum(section.flatMap(\.items))))
                                .font(.system(size: 12.5)).monospacedDigit().foregroundStyle(Theme.ink3)
                        }
                        .padding(.top, 6)
                        ForEach(section, id: \.key) { card in creativeGroup(card).id(card.key) }
                    }
                }
                if !quiet.isEmpty {
                    creativeIdleCard(quiet)
                }
                creativeCoverage
            }
            .padding(.horizontal, 30)
            .padding(.top, 4)
            .padding(.bottom, 24)
            }
        }
        .onAppear {
            if let target = store.creativeScrollTarget { proxy.scrollTo(target, anchor: .top) }
        }
        }
    }

    /// Recognized tools with nothing to clean right now, in one line instead of empty cards.
    private func creativeIdleCard(_ apps: [CreativeApp]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("以下软件暂无可清理的缓存", systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.green)
            FlowLayout(spacing: 8) {
                ForEach(apps) { app in
                    HStack(spacing: 6) {
                        if let icon = ItemPresentation.appIcon(bundleID: app.bundleID) {
                            Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                        }
                        Text(app.title).font(.system(size: 12.5))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Theme.fill(0.06)))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glass()
    }

    /// Everything this page recognizes, so people without these apps still see what is covered.
    private var creativeCoverage: some View {
        let key = "creative:coverage"
        let expanded = store.expandedGroups.contains(key)
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    if expanded { store.expandedGroups.remove(key) } else { store.expandedGroups.insert(key) }
                }
            } label: {
                HStack {
                    Text("能识别的工具").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Theme.ink2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(CreativeApp.Group.allCases, id: \.self) { group in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(group.rawValue).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.ink2).frame(width: 110, alignment: .leading)
                        Text(CreativeApp.allCases.filter { $0.group == group }.map(\.title).joined(separator: "、"))
                            .font(.system(size: 12.5)).foregroundStyle(Theme.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("只清理缓存和日志，下次打开时自动重建。不涉及工程、素材和对话。")
                    .font(.system(size: 12)).foregroundStyle(Theme.ink3).padding(.top, 2)
            }
        }
        .padding(16)
        .glass()
    }

    private func groupTint(_ group: CreativeApp.Group) -> Color {
        switch group {
        case .video: Theme.pink
        case .design: Theme.violet
        case .aiCreate: Theme.amber
        case .aiChat: Theme.green
        case .aiCode: Theme.blue
        case .localModel: Theme.cyan
        }
    }

    // MARK: Chat apps

    private func chatView(_ result: ScanResult) -> some View {
        let chats = result.chatApps
        let total = chats.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
        let selected = chats.first { $0.id == store.selectedChatID } ?? chats.max { ($0.bytes ?? 0) < ($1.bytes ?? 0) }
        return VStack(alignment: .leading, spacing: 18) {
        PageHeader(symbol: Theme.symbol(.chat), tint: Theme.color(.chat), title: ItemFilter.chat.title,
                   subtitle: "聊天数据需在微信中清理，以下是操作路径。") {
            if let selected {
                Button { store.openApp(bundleID: selected.id) } label: { Text("打开\(selected.name)") }
                    .buttonStyle(HeroButtonStyle())
            }
        }
        HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 14) {
                ZStack {
                    UsageRing(segments: chats.map { chat in
                        .init(fraction: Double(chat.bytes ?? 0) / Double(max(total, 1)), style: AnyShapeStyle(chatTint(chat.id)))
                    }, lineWidth: 12)
                    VStack(spacing: 3) {
                        Text(ByteFormat.string(total)).font(.system(size: 24, weight: .bold)).monospacedDigit()
                        Text("聊天软件共占用").font(.system(size: 12)).foregroundStyle(Theme.ink2)
                    }
                }
                .frame(width: 170, height: 170)
                .padding(.vertical, 6)
                ForEach(chats) { chat in chatAppCard(chat, selected: chat.id == selected?.id) }
                Text("小清不会修改微信的数据。")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .frame(width: 290)
            ScrollView {
                if let selected { chatGuide(selected) }
            }
            .frame(maxWidth: .infinity)
        }
        }
        .padding(.horizontal, 30)
        .padding(.top, 4)
        .padding(.bottom, 24)
    }

    private func chatTint(_ id: String) -> Color { id == "com.tencent.xinWeChat" ? Theme.green : Theme.blue }

    private func chatAppCard(_ chat: ChatAppUsage, selected: Bool) -> some View {
        let over = (chat.bytes ?? 0) >= 2_000_000_000
        return Button { withAnimation(.easeOut(duration: 0.15)) { store.selectedChatID = chat.id } } label: {
            HStack(spacing: 12) {
                if let icon = ItemPresentation.appIcon(bundleID: chat.id) {
                    Image(nsImage: icon).resizable().frame(width: 40, height: 40)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(chat.name).font(.system(size: 14.5, weight: .semibold))
                    Text(chat.bytes == nil ? "需要开启权限" : (over ? "占用较多" : "占用正常"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(chat.bytes == nil || over ? Theme.amber : Theme.green)
                }
                Spacer(minLength: 6)
                Text(chat.bytes.map(ByteFormat.string) ?? "—")
                    .font(.system(size: 16, weight: .bold)).monospacedDigit()
                    .foregroundStyle(over ? Theme.amber : Theme.ink)
            }
            .padding(14)
            .overlay(alignment: .leading) {
                if selected { RoundedRectangle(cornerRadius: 2).fill(chatTint(chat.id)).frame(width: 4).padding(.vertical, 14) }
            }
            .glass(highlighted: selected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Right column: how big it is, then where to click in the app and what each step frees. Only the method,
    /// in the app's own words; nothing here deletes anything.
    private func chatGuide(_ chat: ChatAppUsage) -> some View {
        let parts = chat.parts ?? []
        let version = NSWorkspace.shared.urlForApplication(withBundleIdentifier: chat.id)
            .flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }
        return VStack(alignment: .leading, spacing: 16) {
            if let bytes = chat.bytes {
                Text("\(chat.name)占用 \(ByteFormat.string(bytes))").font(.system(size: 22, weight: .bold))
            } else {
                Text("无法读取\(chat.name)的占用").font(.system(size: 22, weight: .bold))
                Text("在系统设置中为小清开启「完全磁盘访问」，重新扫描后显示。")
                    .font(.system(size: 13.5)).foregroundStyle(Theme.ink2)
                Button { store.openFullDiskAccessSettings() } label: { Text("去开启权限") }.buttonStyle(HeroButtonStyle())
            }
            Text("打开\(chat.name)，依次进入").font(.system(size: 15, weight: .semibold)).padding(.top, 4)
            // A menu path, wrapping between steps (never inside one) when the window narrows.
            FlowLayout(spacing: 6) {
                ForEach(Array(ChatGuide.path(for: chat.id).enumerated()), id: \.offset) { index, step in
                    HStack(spacing: 6) {
                        if index > 0 { Text("›").foregroundStyle(Theme.ink3) }
                        Text(step).fixedSize()
                    }
                }
            }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.fill(0.05)))
            Text("在该页面中").font(.system(size: 15, weight: .semibold)).padding(.top, 4)
            ForEach(Array(ChatGuide.steps(for: chat.id).enumerated()), id: \.offset) { index, step in
                let freed = parts.filter { step.kinds.contains($0.kind) }.reduce(Int64(0)) { $0 + $1.bytes }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(index + 1)")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Theme.blueFill))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(step.title).font(.system(size: 14, weight: .semibold))
                            if freed > 0 {
                                Text("大约 \(ByteFormat.string(freed))").font(.system(size: 12.5)).foregroundStyle(Theme.ink2).monospacedDigit()
                            }
                        }
                        Text(step.text).font(.system(size: 13)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let version {
                Text("基于\(chat.name) \(version) 编写，其他版本的菜单位置可能不同。").font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass()
    }

    private struct CreativeCard {
        let key: String
        let title: String
        /// Whose icon the card shows: the member with the most to clean.
        let app: CreativeApp
        let group: CreativeApp.Group
        let items: [ScanItem]
        /// A family card (Adobe) names each row after its app.
        let isFamily: Bool
    }

    private func creativeCards(_ items: [ScanItem]) -> [CreativeCard] {
        var order: [String] = []
        var byKey: [String: [ScanItem]] = [:]
        for item in items {
            guard let app = CreativeApp.of(item) else { continue }
            let key = app.family ?? app.id
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(item)
        }
        return order.compactMap { key -> CreativeCard? in
            guard let members = byKey[key] else { return nil }
            let owners = Dictionary(grouping: members) { CreativeApp.of($0)! }
            guard let lead = owners.max(by: { ScanStore.sum($0.value) < ScanStore.sum($1.value) })?.key else { return nil }
            let family = lead.family != nil
            return CreativeCard(key: key, title: lead.family ?? lead.title, app: lead, group: lead.group,
                                items: members.sorted { $0.bytes > $1.bytes }, isFamily: family)
        }
        .sorted { ScanStore.sum($0.items) > ScanStore.sum($1.items) }
    }

    /// A tool's card: its cleanable parts, several of them as one row with details on demand.
    private func creativeGroup(_ card: CreativeCard) -> some View {
        let key = "creative:\(card.key)"
        let app = card.app
        let items = card.items
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let icon = ItemPresentation.appIcon(bundleID: app.bundleID) {
                    Image(nsImage: icon).resizable().frame(width: 40, height: 40)
                } else {
                    IconTile(symbol: app.group.symbol, tint: groupTint(app.group), size: 40)
                }
                Text(card.title).font(.system(size: 15.5, weight: .semibold))
                Spacer(minLength: 8)
                Text(ByteFormat.string(ScanStore.sum(items))).font(.system(size: 19, weight: .bold)).monospacedDigit()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            if items.count > 1 {
                summaryRow(key: key, items: items)
                if store.expandedGroups.contains(key) {
                    ForEach(items) { item in creativeRow(item, family: card.isFamily).padding(.leading, 30) }
                }
            } else {
                ForEach(items) { item in creativeRow(item, family: card.isFamily) }
            }
        }
        .glass()
    }

    private func creativeRow(_ item: ScanItem, family: Bool = false) -> some View {
        let picked = store.isPicked(item.id)
        let failure = store.failureReasons[item.id].map { "未清理：\($0)" }
        let part = ItemPresentation.partTitle(for: item)
        // In the Adobe card, "日志" alone would not say whose.
        let title = family ? "\(CreativeApp.of(item)?.shortName ?? "") \(part)" : part
        return HStack(spacing: 12) {
            checkbox(item)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(failure ?? shortPath(item.url))
                    .font(.system(size: 12)).foregroundStyle(failure == nil ? Theme.ink3 : Theme.amber).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 10)
            Text(ByteFormat.string(item.bytes))
                .font(.system(size: 14, weight: .medium))
                .monospacedDigit()
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.leading, 70)
        .padding(.trailing, 18)
        .padding(.vertical, 11)
        .background(picked ? Theme.cyan.opacity(0.08) : .clear)
        .background(HoverFill(tracker: store.hover, id: item.id, color: Theme.fill(0.05)))
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { store.setCleanupSelected(item, selected: !picked) }
        }
        .onHover { inside in store.hover.update(item.id, inside: inside) }
        .contextMenu { Button("在访达中显示") { reveal(item) } }
    }

    /// One row for several parts of a tool: "界面缓存、日志、崩溃报告，共 9 处".
    private func summaryRow(key: String, items: [ScanItem]) -> some View {
        let expanded = store.expandedGroups.contains(key)
        let picked = items.filter { store.isPicked($0.id) }.count
        let kinds = items.sorted { $0.bytes > $1.bytes }.reduce(into: [String]()) { names, item in
            // "界面缓存 · Code Cache" and "界面缓存 · GPUCache" are one kind here.
            let kind = ItemPresentation.partTitle(for: item).components(separatedBy: " · ").first ?? ""
            if !names.contains(kind) { names.append(kind) }
        }
        let failed = items.contains { store.failureReasons[$0.id] != nil }
        let toggleExpanded = {
            withAnimation(.easeOut(duration: 0.18)) {
                if expanded { store.expandedGroups.remove(key) } else { store.expandedGroups.insert(key) }
            }
        }
        return HStack(spacing: 12) {
            ToolCheckbox(on: picked > 0, partial: picked > 0 && picked < items.count)
            VStack(alignment: .leading, spacing: 3) {
                Text(kinds.joined(separator: "、")).font(.system(size: 14, weight: .medium)).lineLimit(1).truncationMode(.tail)
                Text(failed ? "部分未清理，展开查看原因" : "共 \(items.count) 处，可自动重建")
                    .font(.system(size: 12)).foregroundStyle(failed ? Theme.amber : Theme.ink3).lineLimit(1)
            }
            Spacer(minLength: 10)
            Text(ByteFormat.string(ScanStore.sum(items)))
                .font(.system(size: 14, weight: .medium))
                .monospacedDigit()
                .frame(width: 84, alignment: .trailing)
            Button(action: toggleExpanded) {
                Image(systemName: expanded ? "chevron.up.circle.fill" : "chevron.down.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(expanded ? Theme.cyan : Theme.ink3)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "收起" : "展开查看每一处")
        }
        .padding(.leading, 70)
        .padding(.trailing, 18)
        .padding(.vertical, 11)
        .background(picked > 0 ? Theme.cyan.opacity(0.08) : .clear)
        .background(HoverFill(tracker: store.hover, id: URL(fileURLWithPath: "/" + key), color: Theme.fill(0.05)))
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { store.setGroupSelected(items, selected: picked < items.count) }
        }
        .onHover { inside in store.hover.update(URL(fileURLWithPath: "/" + key), inside: inside) }
        .contextMenu { Button(expanded ? "收起" : "展开查看每一处", action: toggleExpanded) }
    }

    private func capsuleTag(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.1)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.3)))
    }

    // MARK: Shared row parts

    @ViewBuilder
    private func itemIcon(_ item: ScanItem, info: ItemPresentation.Info) -> some View {
        if let image = info.icon {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
        } else {
            let tint = Theme.color(ItemFilter.allCases.first { $0.contains(item) } ?? .caches)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.32), tint.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(tint.opacity(0.3)))
                .overlay(Image(systemName: info.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint))
                .frame(width: 30, height: 30)
                .padding(1)
        }
    }

    @ViewBuilder
    private func checkbox(_ item: ScanItem) -> some View {
        if store.isSelectable(item) {
            let on = store.isPicked(item.id)
            let tint = selectionTint(item)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(on ? checkFill(tint) : AnyShapeStyle(Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(on ? .clear : checkStroke(tint), lineWidth: 1.5))
                .overlay {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.white)
                        .scaleEffect(on ? 1 : 0.3)
                        .opacity(on ? 1 : 0)
                }
                .frame(width: 18, height: 18)
                .shadow(color: on ? tint.opacity(0.6) : .clear, radius: 5)
        } else {
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink3)
                .frame(width: 18, height: 18)
                .help("此项不可在此清理")
        }
    }

    private func cleanupReportBanner(_ report: CleanupReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: report.movedCount > 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(report.movedCount > 0 ? Theme.green : Theme.amber)
                Text(report.movedCount > 0
                     ? "已清理 \(ByteFormat.string(report.movedBytes))，文件已移到废纸篓"
                     : "未能清理")
                    .font(.system(size: 13.5, weight: .semibold))
                if report.movedCount > 0 {
                    // Open apps keep the space until they restart, so say it once, here, after the fact.
                    Text(report.openApps.isEmpty ? "清空废纸篓后释放空间"
                         : "清空废纸篓后释放空间。\(report.openApps.prefix(3).joined(separator: "、"))\(report.openApps.count > 3 ? "等" : "")正在运行，重新打开后才能完全释放")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if !store.undoable.isEmpty {
                    Button(store.isRestoring ? "正在恢复…" : "撤销") { store.undoLastCleanup() }
                        .buttonStyle(GhostButtonStyle())
                        .disabled(store.isRestoring)
                        .help("恢复刚才清理的项目")
                }
                if report.movedCount > 0 {
                    Button("打开废纸篓") { store.openTrash() }.buttonStyle(GhostButtonStyle())
                }
                Button { store.cleanupReport = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Theme.fill(0.07)))
                }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.ink3)
                    .help("关闭")
            }
            if !report.failures.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(report.failures) { failure in
                            HStack(spacing: 8) {
                                Text(store.result?.items.first { $0.id == failure.id }.map { ItemPresentation.info(for: $0).title } ?? failure.name)
                                    .font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text(failure.reason).font(.system(size: 12)).foregroundStyle(Theme.ink3)
                            }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("\(report.failures.count) 处未清理，展开查看原因")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.ink2)
                }
                .padding(.leading, 24)
            }
        }
        .padding(12)
        .glass(radius: 12)
    }

    // MARK: Helpers

    private func tagText(_ item: ScanItem) -> String {
        if let reason = store.failureReasons[item.id] { return "未清理：\(reason)" }
        if store.isDecidable(item) {
            let cost: String
            switch item.kind {
            case .largeFile: cost = ["dmg", "pkg"].contains(item.url.pathExtension.lowercased()) ? "安装包" : "大文件，需手动确认"
            default: cost = store.policy.modelName(item.url) != nil ? "删除后需重新下载" : "删除后需重新安装依赖"
            }
            return [Self.idle(item.modified), cost].compactMap { $0 }.joined(separator: "，")
        }
        guard item.canTrash else { return item.kind.label }
        return "可自动重建"
    }

    /// "5 个月未修改" once something has sat untouched for a month; nil when recent or unknown.
    static func idle(_ date: Date?) -> String? {
        guard let date else { return nil }
        let days = Int(Date().timeIntervalSince(date) / 86_400)
        if days < 30 { return nil }
        if days < 365 { return "\(days / 30) 个月未修改" }
        return days < 730 ? "超过 1 年未修改" : "超过 \(days / 365) 年未修改"
    }

    /// The top-level place being scanned ("~/.workbuddy", "~/Library/Caches/Google"), not the deep file path.
    private func scanningPlace(_ path: String) -> String {
        let home = store.policy.home.path
        guard path.hasPrefix(home + "/") else { return path }
        let parts = path.dropFirst(home.count + 1).split(separator: "/")
        let depth = parts.first == "Library" ? 3 : 1
        return "~/" + parts.prefix(depth).joined(separator: "/")
    }

    private func shortPath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: store.policy.home.path, with: "~")
    }

    private func reveal(_ item: ScanItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    private func splitBytes(_ bytes: Int64) -> (String, String) {
        let text = ByteFormat.string(bytes)
        guard let space = text.range(of: " ", options: .backwards) else { return (text, "") }
        return (String(text[..<space.lowerBound]), String(text[space.upperBound...]))
    }

    @ViewBuilder
    private func brandIcon(_ size: CGFloat) -> some View {
        if let icon = BrandAsset.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        } else {
            Image(systemName: "externaldrive.fill.badge.checkmark")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        }
    }

    private func volumeName(_ url: URL) -> String {
        (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? "磁盘"
    }

    /// Same "available" figure Finder shows (includes space macOS can purge on demand).
    private func volumeCapacity(_ url: URL) -> (total: Int64, free: Int64)? {
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity,
              let free = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return (Int64(total), free)
    }

    private var otherVolumes: [URL] {
        let volumes = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Volumes"),
            includingPropertiesForKeys: [.volumeIsBrowsableKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return volumes.filter { volume in
            guard volume.lastPathComponent != "Recovery" else { return false }
            let values = try? volume.resourceValues(forKeys: [.isSymbolicLinkKey, .volumeIsBrowsableKey])
            return values?.isSymbolicLink != true && values?.volumeIsBrowsable != false
        }
    }

    // MARK: Confirmation sheet

    private var cleanupReviewSheet: some View {
        // Items the user decides about go first, each with what deleting it costs.
        let decided = store.itemsToClean.filter(store.isDecidable)
        let items = decided + store.itemsToClean.filter { !store.isDecidable($0) }
        let quit = store.runningOwners
        let listHeight = items.reduce(CGFloat(0)) { $0 + (store.isDecidable($1) ? 72 : 52) }
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.accent)
                    .shadow(color: Theme.cyan.opacity(0.5), radius: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text("移到废纸篓").font(.system(size: 20, weight: .bold))
                    Text("共 \(items.count) 项，\(ByteFormat.string(ScanStore.sum(items)))。移到废纸篓后可随时恢复。")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.ink2)
                }
            }
            if !quit.isEmpty {
                Label("\(quit.prefix(4).joined(separator: "、"))\(quit.count > 4 ? " 等" : "")正在运行，重新打开后才能完全释放空间", systemImage: "info.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink2)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        let info = ItemPresentation.info(for: item)
                        HStack(spacing: 10) {
                            itemIcon(item, info: info).scaleEffect(0.85)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(info.title).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                                Text(shortPath(item.url))
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(Theme.ink3)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                if let cost = store.decisionNotes[item.id] {
                                    Text(cost).font(.system(size: 12)).foregroundStyle(Theme.amber).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 8)
                            Text(ByteFormat.string(item.bytes)).font(.system(size: 13.5, weight: .medium)).monospacedDigit()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
                    }
                }
            }
            .frame(height: min(listHeight, 320))
            .glass(radius: 12)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            if !decided.isEmpty {
                Toggle(isOn: $store.confirmDecided) {
                    Text("我已确认可以删除标黄的 \(decided.count) 项").font(.system(size: 13, weight: .medium))
                }
                .toggleStyle(.checkbox)
            }
            HStack {
                Text("小清不会自动清空废纸篓。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink3)
                Spacer()
                Button("返回") { store.showTrashConfirmation = false }
                    .buttonStyle(GhostButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("移到废纸篓") { store.trashSelectedItems() }
                    .buttonStyle(HeroButtonStyle())
                    .disabled(items.isEmpty || (!decided.isEmpty && !store.confirmDecided))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(Theme.ink)
        .background(Backdrop())
    }
}

/// Which list row the pointer is over. Kept out of `ScanStore`: publishing it there redrew the whole window
/// for every row the pointer crossed while scrolling. Only `HoverFill` views observe it.
@MainActor
final class HoverTracker: ObservableObject {
    @Published private(set) var id: URL?

    func update(_ row: URL, inside: Bool) {
        if inside { id = row } else if id == row { id = nil }
    }
}

struct HoverFill: View {
    @ObservedObject var tracker: HoverTracker
    let id: URL
    var color: Color = Theme.fill(0.07)

    var body: some View { Rectangle().fill(tracker.id == id ? color : .clear) }
}

/// Lets the borderless-looking window be dragged from any empty background area.
struct WindowDragEnabler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isMovableByWindowBackground = true
            // Transparent window so the behind-window blur in Backdrop shows the desktop.
            window.isOpaque = false
            window.backgroundColor = .clear
            // `--window-size=960x640`: open at that size (screenshots of narrow layouts without touching the mouse).
            if let size = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--window-size=") })?
                .dropFirst("--window-size=".count).split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
                window.setContentSize(NSSize(width: size[0], height: size[1]))
            }
            // `--snapshot=<file.png>`: draw the window's own views to a PNG after a few seconds
            // (works while the screen is locked, when screencapture only returns black).
            if let path = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--snapshot=") })?
                .dropFirst("--snapshot=".count) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    guard let root = window.contentView?.superview ?? window.contentView,
                          let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
                    root.cacheDisplay(in: root.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: String(path)))
                    // Second rendering path (Core Animation), in case some views skip cacheDisplay.
                    if let layer = root.layer, let ctx = CGContext(data: nil, width: Int(root.bounds.width * 2), height: Int(root.bounds.height * 2),
                                                                     bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                        ctx.scaleBy(x: 2, y: 2)
                        layer.render(in: ctx)
                        if let image = ctx.makeImage() {
                            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                                .write(to: URL(fileURLWithPath: String(path) + ".ca.png"))
                        }
                    }
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
