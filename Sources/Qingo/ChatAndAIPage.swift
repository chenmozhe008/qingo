import AppKit
import SwiftUI

/// Dedicated 「社交与影视创作」 page focused exclusively on consumer chat apps (WeChat / WeCom / Feishu)
/// and video/design creator software (Jianying / DaVinci / Final Cut / Adobe / Blender / Figma).
/// Developer AI coding & local models live in 「开发与 AI 工具」.
struct ChatAndAIPage: View {
    @ObservedObject var store: ScanStore

    private struct ToolBucket: Identifiable {
        let app: CreativeApp
        let cleanable: [ScanItem]
        let readOnly: [ScanItem]
        var id: String { app.id }
        var totalBytes: Int64 { cleanableBytes + readOnlyBytes }
        var cleanableBytes: Int64 { ScanStore.cleanupSum(cleanable) }
        var readOnlyBytes: Int64 { readOnly.reduce(0) { $0 + $1.bytes } }
    }

    private var creativeBuckets: [ToolBucket] {
        var map: [CreativeApp: (cleanable: [ScanItem], readOnly: [ScanItem])] = [:]
        let allowed: Set<CreativeApp.Group> = [.video, .design]
        for item in store.shownItems {
            guard let app = CreativeApp.of(item), allowed.contains(app.group) else { continue }
            var current = map[app] ?? ([], [])
            if item.kind == .cache && item.canTrash {
                current.cleanable.append(item)
            } else {
                current.readOnly.append(item)
            }
            map[app] = current
        }
        return map.map { ToolBucket(app: $0.key, cleanable: $0.value.cleanable, readOnly: $0.value.readOnly) }
            .sorted { $0.totalBytes > $1.totalBytes }
    }

    private var activeCleanableItems: [ScanItem] {
        guard store.chatAITab == .creative else { return [] }
        return creativeBuckets.flatMap(\.cleanable).filter { store.isPicked($0.id) }
    }

    var body: some View {
        ScrollView {
            GlassGroup {
                VStack(alignment: .leading, spacing: 18) {
                    // Header
                    HStack(alignment: .center, spacing: 12) {
                        IconTile(symbol: "bubble.left.and.bubble.right.fill", tint: Theme.green, size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("社交与影视创作").font(.system(size: 21, weight: .bold))
                            Text("聊天记录与剪辑工程严格保护；外围渲染缓存可安全释放，并提供微信、飞书等应用内清理指引。")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.ink2)
                        }
                        Spacer(minLength: 12)
                        if store.chatAITab == .chat {
                            Button(store.isMeasuringChatUsage ? "正在刷新…" : "全盘深度体检") {
                                store.scanOverview()
                            }
                            .buttonStyle(ToolbarButtonStyle(tinted: true))
                            .disabled(store.isScanning || store.isCleaning || store.isMeasuringChatUsage)
                        } else {
                            let bytes = ScanStore.cleanupSum(activeCleanableItems)
                            if bytes > 0 {
                                Button {
                                    store.reviewCleanup(only: Set(activeCleanableItems.map(\.id)))
                                } label: {
                                    if store.isCleaning {
                                        HStack(spacing: 6) {
                                            ProgressView().controlSize(.small).tint(.white)
                                            Text("正在清理…")
                                        }
                                    } else {
                                        Text("释放已选缓存 \(ByteFormat.string(bytes))")
                                    }
                                }
                                .buttonStyle(HeroButtonStyle())
                                .disabled(store.isCleaning)
                            } else {
                                Button("全盘深度体检") { store.scanOverview() }
                                    .buttonStyle(ToolbarButtonStyle(tinted: true))
                                    .disabled(store.isScanning || store.isCleaning)
                            }
                        }
                    }

                    if store.isCleaning {
                        HStack(spacing: 12) {
                            ProgressView().controlSize(.small)
                            Text("正在清理（\(store.cleanedCount)/\(max(store.cleaningTotalCount, 1))）：\(store.cleaningCurrentItem.isEmpty ? "请稍候…" : store.cleaningCurrentItem)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 10)
                            ScanProgressBar(fraction: store.cleaningTotalCount > 0 ? max(0.06, Double(store.cleanedCount) / Double(store.cleaningTotalCount)) : nil,
                                            fill: Theme.accent, glow: Theme.cyan)
                                .frame(width: 120, height: 5)
                        }
                        .padding(12)
                        .glass(radius: 12)
                    }

                    // Segmented Tabs
                    HStack(spacing: 4) {
                        ForEach(ChatAITab.allCases) { tab in
                            let active = store.chatAITab == tab
                            Button {
                                store.chatAITab = tab
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

                    switch store.chatAITab {
                    case .chat:
                        chatAppsSection
                    case .creative:
                        creativeSection
                    }
                }
                .padding(.horizontal, 30)
                .padding(.top, 22)
                .padding(.bottom, 28)
            }
        }
    }

    // MARK: - Tab 1: Chat Apps + Step-by-Step Guides

    @ViewBuilder
    private var chatAppsSection: some View {
        let apps = store.result?.chatApps ?? []
        if !store.hasFullDiskAccess {
            HStack(spacing: 12) {
                IconTile(symbol: "lock.shield.fill", tint: Theme.amber, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("开启「完全磁盘访问权限」以查看微信、企业微信真实占用")
                        .font(.system(size: 13, weight: .semibold))
                    Text("macOS 默认限制读取微信等聊天软件目录；开启后小清只做统计并提供清理步骤，绝不误删聊天记录。")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ink2)
                }
                Spacer()
                Button("前往开启") { store.openFullDiskAccessSettings() }
                    .buttonStyle(ToolbarButtonStyle(tinted: true))
            }
            .padding(14)
            .glass(radius: 14)
        }

        if apps.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.ink3)
                Text(store.isMeasuringChatUsage ? "正在统计社交软件占用…" : "暂无社交应用统计数据")
                    .font(.system(size: 15, weight: .semibold))
                Text("运行一次「全盘深度体检」后，这里会展示微信、企业微信和飞书的分项大小及安全清理指引。")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink2)
            }
            .frame(maxWidth: .infinity, minHeight: 240)
            .glass(radius: 16)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14, alignment: .top)], spacing: 14) {
                ForEach(apps) { app in
                    chatCard(app)
                }
            }
        }
    }

    private func chatCard(_ app: ChatAppUsage) -> some View {
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.id)
        let appIcon = appURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let appIcon {
                    Image(nsImage: appIcon).resizable().frame(width: 32, height: 32)
                } else {
                    IconTile(symbol: "message.fill", tint: Theme.green, size: 32)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).font(.system(size: 15, weight: .bold))
                    Text("聊天记录受保护").font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
                }
                Spacer()
                Text(app.bytes.map(ByteFormat.string) ?? "需授权")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(app.bytes == nil ? Theme.amber : Theme.ink)
                    .monospacedDigit()
            }

            if let parts = app.parts, !parts.isEmpty {
                let sum = max(parts.reduce(0) { $0 + $1.bytes }, 1)
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(parts) { part in
                            if part.bytes > 0 {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(partColor(part.kind))
                                    .frame(width: max(6, geo.size.width * CGFloat(part.bytes) / CGFloat(sum)))
                            }
                        }
                    }
                }
                .frame(height: 8)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                FlowLayout(spacing: 10) {
                    ForEach(parts) { part in
                        HStack(spacing: 5) {
                            Circle().fill(partColor(part.kind)).frame(width: 7, height: 7)
                            Text("\(partLabel(part.kind)) \(ByteFormat.string(part.bytes))")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.ink2)
                                .monospacedDigit()
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                let path = ChatGuide.path(for: app.id).joined(separator: " → ")
                Text("应用内路径：\(path)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.blue)
                ForEach(ChatGuide.steps(for: app.id), id: \.title) { step in
                    Text(step.text)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fill(0.05)))

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("打开 \(app.name)") { store.openApp(bundleID: app.id) }
                    .buttonStyle(ToolbarButtonStyle(tinted: false))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glass(radius: 16)
    }

    private func partColor(_ kind: ChatPart.Kind) -> Color {
        switch kind {
        case .media: Theme.blue
        case .records: Theme.green
        case .drive: Theme.violet
        case .cache: Theme.amber
        case .other: Theme.ink3
        }
    }

    private func partLabel(_ kind: ChatPart.Kind) -> String {
        switch kind {
        case .media: "图片视频与文件"
        case .records: "聊天记录"
        case .drive: "微盘"
        case .cache: "缓存"
        case .other: "其他"
        }
    }

    // MARK: - Tab 2: Video & Design Creator Apps

    @ViewBuilder
    private var creativeSection: some View {
        if creativeBuckets.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "film.stack")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.ink3)
                Text("尚未扫描到剪辑与设计软件缓存").font(.system(size: 15, weight: .semibold))
                Text("点击右上角「全盘深度体检」以分析剪映、达芬奇、Final Cut Pro、Adobe 与 Figma 占用。")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
            .frame(maxWidth: .infinity, minHeight: 240)
            .glass(radius: 16)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 14, alignment: .top)], spacing: 14) {
                ForEach(creativeBuckets) { bucket in
                    toolBucketCard(bucket)
                }
            }
        }
    }

    private func toolBucketCard(_ bucket: ToolBucket) -> some View {
        let bundleIcon = (bucket.app.iconApp.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            ?? bucket.app.apps.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        let fallbackIcon = (bucket.cleanable.first ?? bucket.readOnly.first).flatMap { ItemPresentation.info(for: $0).icon }
        let icon = bundleIcon ?? fallbackIcon
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if let icon {
                    Image(nsImage: icon).resizable().frame(width: 30, height: 30)
                } else {
                    IconTile(symbol: bucket.app.group.symbol, tint: Theme.pink, size: 30)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(bucket.app.title).font(.system(size: 14.5, weight: .bold))
                    Text(bucket.app.group.rawValue).font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
                }
                Spacer()
                Text(ByteFormat.string(bucket.totalBytes))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }

            if !bucket.cleanable.isEmpty {
                VStack(spacing: 6) {
                    ForEach(bucket.cleanable) { item in
                        let picked = store.isPicked(item.id)
                        HStack(spacing: 8) {
                            ToolCheckbox(on: picked)
                            Text(item.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                            Spacer()
                            Text(ByteFormat.string(item.cleanupBytes))
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Theme.blue)
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.fill(0.05)))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if !store.isCleaning { store.toggleSelection(item) }
                        }
                    }
                }
            }

            if !bucket.readOnly.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(bucket.readOnly.prefix(3)) { item in
                        HStack(spacing: 8) {
                            Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(Theme.ink3)
                            Text(item.name).font(.system(size: 12)).foregroundStyle(Theme.ink2).lineLimit(1)
                            Spacer()
                            Text(ByteFormat.string(item.bytes))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.ink2)
                                .monospacedDigit()
                            Button("在访达中显示", systemImage: "folder") {
                                NSWorkspace.shared.activateFileViewerSelecting([item.url])
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.ink3)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.fill(0.03)))
                        .help(item.url.path)
                    }
                    if bucket.readOnly.count > 3 {
                        Text("其余 \(bucket.readOnly.count - 3) 项请点上方文件夹图标在访达查看")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.ink3)
                            .padding(.horizontal, 4)
                    }
                }
            }

            Spacer(minLength: 0)

            if let how = bucket.app.cleanHow {
                Text(how)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glass(radius: 16)
    }
}
