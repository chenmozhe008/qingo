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
        .background(Backdrop())
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(store.appearance.colorScheme)
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
            Text("看看磁盘空间都去哪了")
                .font(.system(size: 34, weight: .bold))
                .padding(.top, 10)
            Text("扫描只读不改。能清的由你勾选，拿不准的只做提示。")
                .font(.system(size: 14))
                .foregroundStyle(Theme.ink2)
                .padding(.top, 10)
            Button { store.scanKnownCaches() } label: {
                Text("快速扫描")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 132, height: 132)
                    .background(
                        Circle().fill(RadialGradient(colors: [Color(red: 0.5, green: 0.69, blue: 1.0), Color(red: 0.23, green: 0.43, blue: 1.0), Color(red: 0.36, green: 0.24, blue: 0.96)],
                                                     center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: 100))
                    )
                    .background(Circle().fill(Theme.blue.opacity(0.12)).padding(-10))
                    .background(Circle().fill(Theme.blue.opacity(0.06)).padding(-22))
                    .shadow(color: Theme.blue.opacity(0.8), radius: 26, y: 14)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 40)
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
            Image(systemName: quick ? "bolt.fill" : "folder.fill")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 104, height: 104)
                .background(Circle().fill(Theme.panel))
                .overlay(Circle().strokeBorder(Theme.line))
                .shadow(color: Theme.blue.opacity(0.4), radius: 24)
            Text(store.notScannedTitle)
                .font(.system(size: 24, weight: .bold))
                .padding(.top, 24)
            Text(quick ? "只检查常见的缓存位置，几秒钟就能完成。" : "可能需要几分钟。扫描只读取，不改动任何文件。")
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.ink2)
                .padding(.top, 8)
            Button { store.scan() } label: { Label("开始扫描", systemImage: "play.fill") }
                .buttonStyle(CTAButtonStyle())
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
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        let angle = context.date.timeIntervalSinceReferenceDate * 150
                        ZStack {
                            Ticks(count: 72, range: 0..<72, length: 26, width: 5).fill(Theme.fill(0.1))
                            Ticks(count: 72, range: 0..<72, length: 26, width: 5)
                                .fill(AngularGradient(colors: [.clear, .clear, Theme.indigo.opacity(0.6), Theme.blue, Theme.cyan], center: .center))
                                .rotationEffect(.degrees(angle))
                                .shadow(color: Theme.blue.opacity(0.45), radius: 8)
                        }
                    }
                    Group {
                        if #available(macOS 26.0, *) {
                            Circle().fill(Color.clear).glassEffect(.regular, in: Circle())
                        } else {
                            Circle().fill(Theme.panel)
                        }
                    }
                    .padding(44)
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
        let notable = store.liveFound.filter { $0.bytes >= 5_000_000 }
        let recent = Array(notable.suffix(7).reversed())
        let caches = store.liveFound.filter { ItemFilter.caches.contains($0) }
        let creative = store.liveFound.filter { ItemFilter.creative.contains($0) }
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
                        Text("扫描到的内容会显示在这里").font(.system(size: 13)).foregroundStyle(Theme.ink3)
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
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            HStack(spacing: 10) {
                liveTotal("可清理缓存", ByteFormat.string(ScanStore.sum(caches)), Theme.cyan)
                liveTotal("创作与 AI 工具", ByteFormat.string(ScanStore.sum(creative)), Theme.pink)
                liveTotal("大文件与工程", store.isQuickScope ? "完整扫描才查" : "\(large.count) 项", Theme.violet)
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

    private func liveTotal(_ title: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.ink2)
            Text(value).font(.system(size: 19, weight: .bold)).monospacedDigit().foregroundStyle(tint)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glass(radius: 12)
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
                    locationRow("完整扫描", icon: "house.fill", url: home, quick: false)
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
                    toolRow("开发工程", icon: "chevron.left.forwardslash.chevron.right", tint: Theme.indigo, page: .dev)

                    if store.result != nil {
                        sectionHeader("分类").padding(.top, 12)
                    }
                    ForEach(store.result == nil ? [] : ItemFilter.allCases) { category in
                        let items = store.items(in: category)
                        switch category {
                        case .chat:
                            if let chats = store.result?.chatApps, !chats.isEmpty {
                                categoryRow(category, bytes: chats.reduce(0) { $0 + ($1.bytes ?? 0) })
                            }
                        case .creative:
                            if !items.isEmpty {
                                categoryRow(category, bytes: ScanStore.sum(items))
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
                    Label(mode.rawValue, systemImage: mode.symbol)
                        .labelStyle(.iconOnly)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(on ? Theme.ink : Theme.ink3)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Theme.fill(0.12) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("外观：\(mode.rawValue)")
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.fill(0.05)))
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
        let active = store.isOverview && store.tool == nil
        return Button { withAnimation(.easeOut(duration: 0.15)) { store.showOverview() } } label: {
            HStack(spacing: 10) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 24)
                    .foregroundStyle(active ? Theme.cyan : Theme.ink2)
                Text("总览").font(.system(size: 14.5, weight: .semibold))
                Spacer(minLength: 4)
            }
            .foregroundStyle(active ? Theme.ink : Theme.ink2)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
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
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 24)
                    .foregroundStyle(active ? Theme.cyan : Theme.ink2)
                Text(title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if hovered {
                    Button { store.removeSavedFolder(url) } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(Theme.ink3)
                    }
                    .buttonStyle(.plain)
                    .help("从列表移除（文件夹本身不会动）")
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
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(active ? Theme.fill(0.08) : .clear))
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
                Image(systemName: "plus").font(.system(size: 13, weight: .medium)).frame(width: 24)
                Text("添加文件夹")
                Spacer(minLength: 4)
            }
            .font(.system(size: 14))
            .foregroundStyle(Theme.ink3)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
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
        let selected = store.tool == nil && store.filter == category
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
            if store.filter == .creative {
                creativeView(result)
            } else if store.filter == .chat {
                chatView(result)
            } else {
                VStack(spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        // Free space is read live (scan results go stale as soon as anything is deleted).
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            diskCard(result)
                        }
                        .frame(width: 236)
                        .frame(maxHeight: .infinity)
                        statsGrid(result)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 18)
                    banners
                    listPanel
                }
                .padding(.horizontal, 26)
                .padding(.bottom, showFooter ? 0 : 22)
            }
            if showFooter { footer }
        }
    }

    private var showFooter: Bool { !store.selectableInFilter.isEmpty }

    private func topBar(_ result: ScanResult) -> some View {
        HStack(spacing: 10) {
            if !store.isOverview {
                Button { withAnimation(.easeOut(duration: 0.15)) { store.showOverview() } } label: {
                    Label("返回总览", systemImage: "chevron.left")
                }
                .buttonStyle(ToolbarButtonStyle(large: true, tinted: true))
                .keyboardShortcut("[", modifiers: .command)
                .help("回到总览（⌘[）")
            }
            Text(store.isOverview ? store.scopeTitle : store.filter.title)
                .font(.system(size: 17, weight: .bold))
            Text(scanMeta(result))
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink3)
                .lineLimit(1)
            Spacer()
            Button { store.scan() } label: { Label("重新扫描", systemImage: "arrow.clockwise") }
                .buttonStyle(ToolbarButtonStyle(prominent: true, large: true))

                .help("重新扫描「\(store.scopeTitle)」（⌘R）")
        }
        .disabled(store.isCleaning)
        .padding(.leading, showSidebar ? 12 : 22)
        .padding(.trailing, 18)
        .frame(height: 62)
    }

    private func scanMeta(_ result: ScanResult) -> String {
        return "\(Self.ago(result.scannedAt))扫描"
    }

    /// Disk card: the ring shows only what is free; name and capacity sit underneath so nothing gets clipped.
    private func diskCard(_ result: ScanResult) -> some View {
        let live = volumeCapacity(result.root)
        let totalBytes = live?.total ?? result.volumeTotalBytes ?? 0
        let total = Double(max(totalBytes, 1))
        let free = live?.free ?? result.volumeFreeBytes ?? 0
        let used = Double(max(totalBytes - free, 0))
        let low = free < Self.lowSpaceBytes
        return VStack(spacing: 10) {
            DiskRing(usedFraction: used / total, low: low, free: ByteFormat.string(free), caption: low ? "剩余空间较少" : "可用")
                .frame(width: 150, height: 150)
            VStack(spacing: 2) {
                Text(volumeName(result.root)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("共 \(ByteFormat.string(totalBytes))，已用 \(Int((used / total * 100).rounded()))%")
                    .font(.system(size: 12)).foregroundStyle(Theme.ink2).lineLimit(1)
            }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glass()
    }

    /// Below this much free space the ring and disk card turn amber. Ratios mislead on big disks.
    static let lowSpaceBytes: Int64 = 10 * 1_073_741_824

    private func statsGrid(_ result: ScanResult) -> some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                statCard(.caches)
                statCard(.creative)
                chatStatCard(result)
            }
            GridRow {
                statCard(.review)
                statCard(.large, unavailable: result.isQuickScan)
                cleanableSummaryCard
            }
        }
    }

    private func statCard(_ category: ItemFilter, unavailable: Bool = false) -> some View {
        let items = store.items(in: category)
        let (number, unit) = splitBytes(ScanStore.sum(items))
        let selected = store.filter == category
        let detail: String
        if unavailable {
            detail = "完整扫描后显示"
        } else if items.isEmpty {
            detail = "没有发现"
        } else if category == .creative {
            let here = ScanStore.sum(items.filter(\.canTrash))
            detail = here > 0 ? "\(unit) · \(ByteFormat.string(here)) 可以清理" : "\(unit) · 只统计，不删除"
        } else {
            detail = "\(unit) · \(items.count) 项"
        }
        return Button { withAnimation(.easeOut(duration: 0.15)) { store.selectCategory(category) } } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    IconTile(symbol: Theme.symbol(category), tint: Theme.color(category), size: 18)
                    Text(category.title)
                }
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink2)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(unavailable || items.isEmpty ? "—" : number).font(.system(size: 22, weight: .bold)).monospacedDigit()
                    if !(unavailable || items.isEmpty) {
                        Text(unit).font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                    }
                }
                Text(unavailable || items.isEmpty ? detail : detail.replacingOccurrences(of: unit + " · ", with: ""))
                    .font(.system(size: 12)).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .glass(highlighted: selected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Third card, same position as in the sidebar. Turns amber over 2 GB; opens the how-to page.
    private func chatStatCard(_ result: ScanResult) -> some View {
        let chats = result.chatApps
        let unreadable = chats.contains { $0.bytes == nil }
        let total = chats.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
        let over = chats.contains { ($0.bytes ?? 0) >= 2_000_000_000 }
        let (number, unit) = splitBytes(total)
        let selected = store.filter == .chat
        let detail: String = {
            if chats.isEmpty { return "没有发现" }
            if unreadable && total == 0 { return "开启权限后显示 ›" }
            return over ? "\(unit) · 超过 2 GB ›" : "\(unit) · 不到 2 GB"
        }()
        return Button { withAnimation(.easeOut(duration: 0.15)) { store.selectCategory(.chat) } } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    IconTile(symbol: Theme.symbol(.chat), tint: Theme.green, size: 18)
                    Text(ItemFilter.chat.title)
                }
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink2)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(chats.isEmpty || (unreadable && total == 0) ? "—" : number)
                        .font(.system(size: 22, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(over ? Theme.amber : Theme.ink)
                    Text(unit).font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                }
                Text(detail.replacingOccurrences(of: unit + " · ", with: ""))
                    .font(.system(size: 12)).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(over ? AnyShapeStyle(LinearGradient(colors: [Theme.amber.opacity(selected ? 0.24 : 0.16), Theme.amber.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing)) : AnyShapeStyle(Theme.panel))
            )
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(over ? Theme.amber.opacity(selected ? 0.6 : 0.35) : (selected ? Theme.blue.opacity(0.5) : Theme.line)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// What this app itself can free: every cleanable item, across categories.
    private var cleanableSummaryCard: some View {
        let (number, unit) = splitBytes(ScanStore.sum(store.eligibleItems))
        return VStack(alignment: .leading, spacing: 6) {
            Label("可释放空间", systemImage: "sparkles")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.softInk)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(number).font(.system(size: 22, weight: .bold)).monospacedDigit()
                Text(unit).font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
            }
            Text("清空废纸篓后释放")
                .font(.system(size: 12)).foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(LinearGradient(colors: [Theme.blue.opacity(0.22), Theme.indigo.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(red: 0.55, green: 0.59, blue: 1.0).opacity(0.35)))
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
                            .buttonStyle(ToolbarButtonStyle(prominent: true, large: true))
                            .padding(.top, 4)
                    } else {
                        Image(systemName: "checkmark.circle").font(.system(size: 30)).foregroundStyle(Theme.green)
                        Text(store.filter == .caches ? "没有发现可清理的缓存" : "这一类没有发现内容").font(.system(size: 14)).foregroundStyle(Theme.ink2)
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
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func row(_ item: ScanItem, maxBytes: Int64) -> some View {
        let expanded = store.selectedID == item.id
        let picked = store.selectedCleanupIDs.contains(item.id)
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
        let pickedCount = cleanable.filter { store.selectedCleanupIDs.contains($0.id) }.count
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

    private func creativeView(_ result: ScanResult) -> some View {
        let items = store.items(in: .creative).filter { $0.bytes > 0 || CreativeApp.isReviewCache($0.url) }
        let found = CreativeApp.allCases.filter { app in items.contains { CreativeApp.of($0) == app } }
        let idle = CreativeApp.allCases.filter { $0.isInstalled && !found.contains($0) }
        let cleanable = ScanStore.sum(items.filter(\.canTrash))
        let decided = ScanStore.sum(items.filter(store.isDecidable))
        let readOnly = ScanStore.sum(items.filter { !$0.canTrash && !store.isDecidable($0) })
        let headline: String = {
            if found.isEmpty { return "没有发现创作和 AI 工具的占用" }
            if cleanable == 0 { return "\(found.count) 个工具共占用 \(ByteFormat.string(readOnly))" }
            return "\(ByteFormat.string(cleanable)) 可以在这里清理"
        }()
        var notes: [String] = []
        if cleanable > 0, readOnly > 0 { notes.append("另有 \(ByteFormat.string(readOnly)) 是工程、模型和对话等数据，只统计、不删除。") }
        if cleanable == 0, readOnly > 0 { notes.append("都是工程、模型和对话等数据，只统计、不删除，要清理请在各自软件里操作。") }
        if decided > 0 { notes.append("下载的模型有 \(ByteFormat.string(decided)) 可以挑着删，删了要重新下载。") }
        if result.isQuickScan { notes.append("Final Cut 渲染文件和达芬奇 CacheClip 需要完整扫描才能找到。") }
        return ScrollViewReader { proxy in
        ScrollView {
            GlassGroup {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(headline).font(.system(size: 24, weight: .bold))
                    if !notes.isEmpty {
                        Text(notes.joined(separator: ""))
                            .font(.system(size: 13)).foregroundStyle(Theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.bottom, 4)
                banners
                ForEach(CreativeApp.Group.allCases, id: \.self) { group in
                    let apps = found.filter { $0.group == group }
                    if !apps.isEmpty {
                        HStack(alignment: .firstTextBaseline) {
                            Text(group.rawValue).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink2)
                            Spacer()
                            Text(ByteFormat.string(ScanStore.sum(items.filter { app in apps.contains { CreativeApp.of(app) == $0 } })))
                                .font(.system(size: 12.5)).monospacedDigit().foregroundStyle(Theme.ink3)
                        }
                        .padding(.top, 6)
                        ForEach(apps) { app in creativeGroup(app, items: items.filter { CreativeApp.of($0) == app }).id(app.id) }
                    }
                }
                if !idle.isEmpty {
                    creativeIdleCard(idle)
                }
                creativeCoverage
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
            }
        }
        .onAppear {
            if let target = store.creativeScrollTarget { proxy.scrollTo(target, anchor: .top) }
        }
        }
    }

    /// Installed tools with nothing on disk worth a row, in one line instead of empty cards.
    private func creativeIdleCard(_ apps: [CreativeApp]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("这些软件已安装，没发现明显占用", systemImage: "checkmark.circle.fill")
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
                Text("各软件的缓存可以清理，Hugging Face 和 LM Studio 的模型可以挑着删；工程、素材和对话只统计，不提供删除。")
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
        return HStack(alignment: .top, spacing: 18) {
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
                Text("这里只读大小，不会删除聊天记录或文件。")
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
        .padding(.horizontal, 26)
        .padding(.vertical, 22)
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
                    Text(chat.bytes == nil ? "需要开启权限" : (over ? "建议清理" : "暂时不用清"))
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

    /// Right column: verdict, a one-line step strip (details on demand), and what is safe to delete.
    private func chatGuide(_ chat: ChatAppUsage) -> some View {
        let version = NSWorkspace.shared.urlForApplication(withBundleIdentifier: chat.id)
            .flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }
        let tint = chatTint(chat.id)
        let over = (chat.bytes ?? 0) >= 2_000_000_000
        let key = "chat:\(chat.id)"
        let expanded = store.expandedGroups.contains(key)
        let verdict: String = {
            guard let bytes = chat.bytes else { return "还读不到\(chat.name)占了多少" }
            return over ? "\(chat.name)占了 \(ByteFormat.string(bytes))，建议清理" : "\(chat.name)占了 \(ByteFormat.string(bytes))，暂时不用清"
        }()
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verdict).font(.system(size: 20, weight: .bold))
                    Text(chat.bytes == nil
                         ? "在系统设置里给本应用开启「完全磁盘访问」，重新扫描后就能显示。"
                         : "聊天记录只能在\(chat.name)里清理。先清缓存，不影响聊天记录；还不够再删大视频和文件。")
                        .font(.system(size: 13)).foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 8) {
                    if chat.bytes == nil {
                        Button { store.openFullDiskAccessSettings() } label: { Label("去开启权限", systemImage: "lock.open") }
                            .buttonStyle(ToolbarButtonStyle(prominent: true, large: true))
                    }
                    Button { store.openApp(bundleID: chat.id) } label: {
                        Label("打开\(chat.name)", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(ToolbarButtonStyle(prominent: chat.bytes != nil, large: true))
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glass()

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("在\(chat.name)里这样清").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) {
                            if expanded { store.expandedGroups.remove(key) } else { store.expandedGroups.insert(key) }
                        }
                    } label: {
                        Label(expanded ? "收起说明" : "详细说明", systemImage: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.blue)
                    }
                    .buttonStyle(.plain)
                }
                FlowLayout(spacing: 6) {
                    ForEach(Array(ChatGuide.shortSteps(for: chat.id).enumerated()), id: \.offset) { index, step in
                        HStack(spacing: 6) {
                            if index > 0 {
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.ink3)
                            }
                            HStack(spacing: 6) {
                                Text("\(index + 1)")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 18, height: 18)
                                    .background(Circle().fill(tint))
                                Text(step).font(.system(size: 13, weight: .medium))
                            }
                            .padding(.leading, 5)
                            .padding(.trailing, 11)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(tint.opacity(0.1)))
                        }
                    }
                }
                if expanded {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(ChatGuide.steps(for: chat.id).enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("\(index + 1).").font(.system(size: 13, weight: .semibold)).foregroundStyle(tint).frame(width: 18, alignment: .trailing)
                                Text(step).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Text(version.map { "按\(chat.name) \($0) 写的，其他版本菜单位置可能略有不同。" } ?? "不同版本菜单位置可能略有不同。")
                            .font(.system(size: 12)).foregroundStyle(Theme.ink3)
                    }
                    .padding(.top, 4)
                    .transition(.opacity)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glass()

            VStack(alignment: .leading, spacing: 12) {
                Text("哪些能删").font(.system(size: 14, weight: .semibold))
                ForEach(ChatGuide.tips, id: \.text) { tip in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: tip.symbol)
                            .foregroundStyle(tip.tint == "green" ? Theme.green : (tip.tint == "amber" ? Theme.amber : Theme.pink))
                        Text(tip.text).font(.system(size: 13)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glass()
        }
    }

    private func creativeGroup(_ app: CreativeApp, items: [ScanItem]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let icon = ItemPresentation.appIcon(bundleID: app.bundleID) {
                    Image(nsImage: icon).resizable().frame(width: 40, height: 40)
                } else {
                    IconTile(symbol: app.group.symbol, tint: groupTint(app.group), size: 40)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.title).font(.system(size: 15.5, weight: .semibold))
                    Text(items.contains(where: { store.policy.modelName($0.url) != nil }) ? "下载的模型可以挑着删，删了要重新下载"
                         : items.contains(where: \.canTrash) || app.cleanHow != nil ? app.hint : "\(app.group.dataNote)只统计、不删除")
                        .font(.system(size: 12)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(ByteFormat.string(ScanStore.sum(items))).font(.system(size: 19, weight: .bold)).monospacedDigit()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            // Several parts of one kind read as one row, details on demand: the regenerable caches, logs and
            // crash reports together; items to decide about per kind ("30 天前的对话记录"). Models stay one per row.
            ForEach(rowGroups(app, items: items), id: \.key) { group in
                if group.items.count > 1 {
                    summaryRow(app, group: group)
                    if store.expandedGroups.contains(group.key) {
                        ForEach(group.items) { item in creativeRow(item, app: app).padding(.leading, 30) }
                    }
                } else {
                    creativeRow(group.items[0], app: app)
                    if store.expandedGroups.contains(store.breakdownKey(group.items[0])) {
                        breakdownPanel(group.items[0], app: app)
                    }
                }
            }
        }
        .glass()
    }

    private func creativeRow(_ item: ScanItem, app: CreativeApp) -> some View {
        let picked = store.selectedCleanupIDs.contains(item.id)
        let selectable = store.isSelectable(item)
        let failure = store.failureReasons[item.id]
        let tint = selectionTint(item)
        return HStack(spacing: 12) {
            checkbox(item)
            VStack(alignment: .leading, spacing: 3) {
                Text(ItemPresentation.partTitle(for: item)).font(.system(size: 14, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(failure.map { "没清掉：\($0)" } ?? (store.isDecidable(item) ? tagText(item) : shortPath(item.url)))
                    .font(.system(size: 12)).foregroundStyle(failure == nil ? Theme.ink3 : Theme.amber).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 10)
            if item.canTrash {
                capsuleTag("可在此清理", tint: Theme.cyan)
            } else if store.isDecidable(item) {
                capsuleTag("确认后可删", tint: Theme.amber)
            } else {
                // Read-only data: explain what is inside and what to do about each part, not just open a folder.
                let open = store.expandedGroups.contains(store.breakdownKey(item))
                Button { withAnimation(.easeOut(duration: 0.18)) { store.toggleBreakdown(item) } } label: {
                    capsuleTag(open ? "收起" : "里面有什么", tint: Theme.blue)
                }
                .buttonStyle(.plain)
                .help("看看里面都是什么、哪些能删、怎么删")
            }
            Text(ByteFormat.string(item.bytes))
                .font(.system(size: 14, weight: .medium))
                .monospacedDigit()
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.leading, 70)
        .padding(.trailing, 18)
        .padding(.vertical, 11)
        .background(picked ? tint.opacity(0.08) : .clear)
        .background(HoverFill(tracker: store.hover, id: item.id, color: Theme.fill(0.05)))
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture {
            if selectable {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { store.setCleanupSelected(item, selected: !picked) }
            } else if !item.canTrash {
                withAnimation(.easeOut(duration: 0.18)) { store.toggleBreakdown(item) }
            }
        }
        .onHover { inside in
            store.hover.update(item.id, inside: inside)
        }
        .contextMenu { Button("在访达中显示") { reveal(item) } }
    }

    /// "里面有什么": each part of a read-only data folder in plain words, with what to do about it.
    private func breakdownPanel(_ item: ScanItem, app: CreativeApp) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let parts = store.breakdowns[item.id] {
                ForEach(parts) { part in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(part.label).font(.system(size: 13.5, weight: .medium))
                                if part.label != part.name, part.name != "其他" {
                                    Text(part.name).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.ink3)
                                }
                            }
                            Text(part.advice).font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 10)
                        Text(ByteFormat.string(part.bytes)).font(.system(size: 13, weight: .medium)).monospacedDigit()
                            .frame(width: 84, alignment: .trailing)
                    }
                    .padding(.vertical, 8)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
                    .contextMenu { Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([part.id]) } }
                }
                HStack(spacing: 8) {
                    Text("这里不直接删这些数据，免得误删你的对话和作品。").font(.system(size: 12)).foregroundStyle(Theme.ink3)
                    Spacer()
                    if app.isInstalled, !app.bundleID.isEmpty {
                        Button("打开\(app.shortName)") { store.openApp(bundleID: app.bundleID) }.buttonStyle(GhostButtonStyle())
                    }
                    Button("在访达中显示") { reveal(item) }.buttonStyle(GhostButtonStyle())
                }
                .padding(.top, 10)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在看里面有什么…").font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                }
                .padding(.vertical, 10)
            }
        }
        .padding(.leading, 100)
        .padding(.trailing, 18)
        .padding(.bottom, 12)
        .background(Theme.fill(0.03))
    }

    private struct CreativeRowGroup {
        let key: String
        /// "可以清理", or the kind of the items to decide about.
        let title: String
        let decided: Bool
        let items: [ScanItem]
    }

    /// Cleanable parts first as one group, then items to decide about grouped by kind, then read-only data.
    private func rowGroups(_ app: CreativeApp, items: [ScanItem]) -> [CreativeRowGroup] {
        var groups: [CreativeRowGroup] = []
        let cleanable = items.filter(\.canTrash)
        if !cleanable.isEmpty { groups.append(CreativeRowGroup(key: "creative:\(app.id)", title: "可以清理", decided: false, items: cleanable)) }
        var kinds: [String] = []
        var byKind: [String: [ScanItem]] = [:]
        for item in items where store.isDecidable(item) {
            let kind = ItemPresentation.partTitle(for: item).components(separatedBy: " · ").first ?? ""
            if byKind[kind] == nil { kinds.append(kind) }
            byKind[kind, default: []].append(item)
        }
        groups += kinds.map { CreativeRowGroup(key: "creative:\(app.id):\($0)", title: $0, decided: true, items: byKind[$0]!) }
        groups += items.filter { !$0.canTrash && !store.isDecidable($0) }
            .map { CreativeRowGroup(key: $0.url.path, title: "", decided: false, items: [$0]) }
        return groups
    }

    /// One row for several parts: "界面缓存、日志、崩溃报告，共 9 处", or "30 天前的对话记录，共 18 处".
    private func summaryRow(_ app: CreativeApp, group: CreativeRowGroup) -> some View {
        let items = group.items
        let key = group.key
        let expanded = store.expandedGroups.contains(key)
        let picked = items.filter { store.selectedCleanupIDs.contains($0.id) }.count
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
        let tint = group.decided ? Theme.amber : Theme.cyan
        let detail = group.decided ? "共 \(items.count) 处，" + (store.decisionNotes[items[0].id] ?? "")
            : kinds.joined(separator: "、") + "，共 \(items.count) 处"
        return HStack(spacing: 12) {
            ToolCheckbox(on: picked > 0, amber: group.decided, partial: picked > 0 && picked < items.count)
            VStack(alignment: .leading, spacing: 3) {
                Text(group.title).font(.system(size: 14, weight: .medium))
                Text(failed ? "有的没清掉，展开看原因" : detail)
                    .font(.system(size: 12)).foregroundStyle(failed ? Theme.amber : Theme.ink3).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 10)
            capsuleTag(group.decided ? "确认后可删" : "可在此清理", tint: tint)
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
        .background(picked > 0 ? tint.opacity(0.08) : .clear)
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
            let on = store.selectedCleanupIDs.contains(item.id)
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
                .help("仅作提示，不能在这里清理")
        }
    }

    private var footer: some View {
        let inFilter = store.eligibleInFilter
        let allSelected = inFilter.allSatisfy { store.selectedCleanupIDs.contains($0.id) }
        let empty = store.selectedCleanupItems.isEmpty
        let quit = store.appsToQuit
        let decided = store.selectedDecidedItems.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                if store.isCleaning { ProgressView().controlSize(.small) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.isCleaning
                         ? "正在检查并移入废纸篓 \(store.cleanedCount)/\(store.selectedCleanupItems.count)"
                         : empty ? "选择要清理的项目" : "已选 \(store.selectedCleanupItems.count) 项，共 \(ByteFormat.string(store.selectedCleanupBytes))")
                        .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                    Text(empty ? "点一下列表里的项目就能选中"
                         : !quit.isEmpty ? "清理前请先退出 \(quit.joined(separator: "、"))"
                         : decided > 0 ? "其中 \(decided) 项删了有影响，确认时会逐条列出"
                         : "移入废纸篓后仍可恢复；清空后才会释放空间。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(!quit.isEmpty ? Theme.amber : Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                // "全选" only covers regenerable caches; items the user decides about are picked one by one.
                if !inFilter.isEmpty {
                    Button(allSelected ? "取消全选" : "全选") {
                        withAnimation(.easeOut(duration: 0.15)) { allSelected ? store.clearCleanupSelection() : store.selectAllEligible() }
                    }
                    .keyboardShortcut("a", modifiers: .command)
                } else if !empty {
                    Button("取消选择") { withAnimation(.easeOut(duration: 0.15)) { store.clearCleanupSelection() } }
                }
                if store.filter == .caches {
                    Button("只选可再生缓存") {
                        withAnimation(.easeOut(duration: 0.15)) { store.selectReusable() }
                    }
                    .help("选择无需退出应用、下次使用时可重新生成或下载的缓存")
                }
                Spacer(minLength: 8)
                Button("移入废纸篓…") { store.reviewCleanup() }
                .buttonStyle(ToolbarButtonStyle(prominent: !empty, large: true))
                .disabled(empty || store.isCleaning)
                .opacity(empty ? 0.6 : 1)
            }
            .buttonStyle(ToolbarButtonStyle())
            .disabled(store.isCleaning)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func cleanupReportBanner(_ report: CleanupReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: report.movedCount > 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(report.movedCount > 0 ? Theme.green : Theme.amber)
                Text(report.movedCount > 0
                     ? "已移入废纸篓 \(report.movedCount.formatted()) 项，共 \(ByteFormat.string(report.movedBytes))"
                     : "没有项目被移动")
                    .font(.system(size: 13.5, weight: .semibold))
                if report.movedCount > 0 {
                    Text("清空废纸篓后才会真正释放空间").font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if !store.undoable.isEmpty {
                    Button(store.isRestoring ? "正在放回…" : "撤销") { store.undoLastCleanup() }
                        .buttonStyle(GhostButtonStyle())
                        .disabled(store.isRestoring)
                        .help("把刚才移走的放回原处")
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
                                Text(failure.name).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text(failure.reason).font(.system(size: 12)).foregroundStyle(Theme.ink3)
                            }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("\(report.failures.count) 项没清掉，原因也写在列表里")
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

    private func actionHint(_ item: ScanItem) -> String {
        if CreativeApp.of(item) != nil { return item.canTrash ? "可在此清理" : "只统计，不删除" }
        return tagText(item)
    }

    private func tagText(_ item: ScanItem) -> String {
        if let reason = store.failureReasons[item.id] { return "没清掉：\(reason)" }
        if store.isDecidable(item) {
            let cost: String
            switch item.kind {
            case .largeFile: cost = ["dmg", "pkg"].contains(item.url.pathExtension.lowercased()) ? "安装包，可以删" : "大文件，删不删由你决定"
            default: cost = store.policy.modelName(item.url) != nil ? "删了要重新下载" : "删了要重新安装依赖"
            }
            return [Self.idle(item.modified), cost].compactMap { $0 }.joined(separator: "，")
        }
        guard item.canTrash else { return item.kind.label }
        return item.risk == .a ? "可重新生成" : "应用缓存，需先退出应用"
    }

    /// "5 个月没动过" once something has sat untouched for a month; nil when recent or unknown.
    static func idle(_ date: Date?) -> String? {
        guard let date else { return nil }
        let days = Int(Date().timeIntervalSince(date) / 86_400)
        if days < 30 { return nil }
        if days < 365 { return "\(days / 30) 个月没动过" }
        return days < 730 ? "一年多没动过" : "\(days / 365) 年多没动过"
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
        let decided = store.selectedDecidedItems
        let items = decided + store.selectedCleanupItems.filter { !store.isDecidable($0) }
        let quit = store.appsToQuit
        let listHeight = items.reduce(CGFloat(0)) { $0 + (store.isDecidable($1) ? 72 : 52) }
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.accent)
                    .shadow(color: Theme.cyan.opacity(0.5), radius: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text("移入废纸篓").font(.system(size: 20, weight: .bold))
                    Text("共 \(items.count) 项，\(ByteFormat.string(store.selectedCleanupBytes))。放进废纸篓后随时可以恢复。")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.ink2)
                }
            }
            if !quit.isEmpty {
                Label("请先退出这些应用：\(quit.prefix(4).joined(separator: "、"))\(quit.count > 4 ? " 等" : "")", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.amber)
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
                    Text("我已确认标黄的 \(decided.count) 项可以删").font(.system(size: 13, weight: .medium))
                }
                .toggleStyle(.checkbox)
            }
            HStack {
                Text("本应用不会清空废纸篓，什么时候清空由你决定。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink3)
                Spacer()
                Button("返回") { store.showTrashConfirmation = false }
                    .buttonStyle(GhostButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("确认移入废纸篓") { store.trashSelectedItems() }
                    .buttonStyle(CTAButtonStyle())
                    .disabled(items.isEmpty || (!decided.isEmpty && !store.confirmDecided))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(Theme.ink)
        .background(Backdrop())
        .preferredColorScheme(store.appearance.colorScheme)
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
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
