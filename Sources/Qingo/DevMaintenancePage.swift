import AppKit
import SwiftUI

/// Dedicated 「开发与 AI 工具」 hub unifying:
/// 1) AI Coding & Local LLM Models (Cursor, Claude Code, Codex, WorkBuddy, Ollama, LM Studio, HuggingFace)
/// 2) Code Project Build Artifacts (~/Coding `.build`, `target`, `DerivedData`, `.next/cache`, etc.)
/// 3) Package Managers & Simulators (Homebrew, pnpm, uv, Docker, Xcode Simulators)
struct DevMaintenancePage: View {
    @ObservedObject var store: ScanStore
    @ObservedObject private var storageTools: StorageToolsStore

    init(store: ScanStore) {
        self.store = store
        self.storageTools = store.storageTools
    }

    private struct AIBucket: Identifiable {
        let app: CreativeApp
        let cleanable: [ScanItem]
        let readOnly: [ScanItem]
        var id: String { app.id }
        var totalBytes: Int64 { cleanableBytes + readOnlyBytes }
        var cleanableBytes: Int64 { ScanStore.cleanupSum(cleanable) }
        var readOnlyBytes: Int64 { readOnly.reduce(0) { $0 + $1.bytes } }
    }

    private var aiBuckets: [AIBucket] {
        let groups: Set<CreativeApp.Group> = [.aiCode, .aiChat, .aiCreate, .localModel]
        var map: [CreativeApp: (cleanable: [ScanItem], readOnly: [ScanItem])] = [:]
        for item in store.shownItems {
            guard let app = CreativeApp.of(item), groups.contains(app.group) else { continue }
            var current = map[app] ?? ([], [])
            if item.kind == .cache && item.canTrash {
                current.cleanable.append(item)
            } else {
                current.readOnly.append(item)
            }
            map[app] = current
        }
        return map.map { AIBucket(app: $0.key, cleanable: $0.value.cleanable, readOnly: $0.value.readOnly) }
            .sorted { $0.totalBytes > $1.totalBytes }
    }

    private var selectedAICleanable: [ScanItem] {
        aiBuckets.flatMap(\.cleanable).filter { store.isPicked($0.id) }
    }

    private var subtitleText: String {
        switch store.devMaintenanceTab {
        case .ai:
            "集中清理 Cursor、Claude Code、Codex 等 AI 编程缓存，并盘点 Ollama / HuggingFace 本地模型占用。"
        case .projects:
            "在「\(ToolText.short(store.dev.root))」中查找可安全清理的项目构建产物，源代码与依赖配置保持不动。"
        case .cli:
            "用各工具自带的安全命令清理旧包缓存与不可用模拟器，系统快照与基础维护已归入「应用与系统维护」。"
        }
    }

    var body: some View {
        let probes = storageTools.cliProbes
        let ordered = probes.map(\.id).filter { storageTools.selectedCLIAdapters.contains($0) }
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    IconTile(symbol: "hammer.fill", tint: Theme.amber, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("开发与 AI 工具").font(.system(size: 21, weight: .bold))
                        Text(subtitleText)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.ink2)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    headerActions(ordered: ordered)
                }

                subTabBar

                if store.devMaintenanceTab == .cli || store.isCleaning {
                    statusBanner
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 20)
            .padding(.bottom, 12)

            switch store.devMaintenanceTab {
            case .ai:
                aiToolsView
            case .projects:
                DevProjectsView(store: store.dev, appearance: store.appearance, embedded: true)
            case .cli:
                cliToolsView
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
    }

    @ViewBuilder
    private func headerActions(ordered: [CLICleanerAdapters.AdapterID]) -> some View {
        switch store.devMaintenanceTab {
        case .ai:
            let bytes = ScanStore.cleanupSum(selectedAICleanable)
            if bytes > 0 {
                Button {
                    store.reviewCleanup(only: Set(selectedAICleanable.map(\.id)))
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
        case .projects:
            Button("更换文件夹…") { store.dev.chooseRoot() }
                .buttonStyle(ToolbarButtonStyle(tinted: false))
                .disabled(store.dev.isScanning || store.dev.isCleaning)
            Button { store.dev.scan() } label: {
                Label(store.dev.result == nil ? "开始扫描" : "重新扫描", systemImage: "arrow.clockwise")
            }
            .buttonStyle(ToolbarButtonStyle(tinted: true))
            .disabled(store.dev.isScanning || store.dev.isCleaning)
        case .cli:
            Button {
                storageTools.confirmation = .cliBatch(ordered)
            } label: {
                if storageTools.activity != nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(.white)
                        Text("正在清理…")
                    }
                } else {
                    Text(ordered.isEmpty ? "请先勾选工具" : "开始清理（\(ordered.count) 项）")
                }
            }
            .buttonStyle(HeroButtonStyle())
            .disabled(ordered.isEmpty || storageTools.activity != nil)
        }
    }

    private var subTabBar: some View {
        HStack(spacing: 4) {
            ForEach(DevMaintenanceTab.allCases) { tab in
                let active = store.devMaintenanceTab == tab
                Button {
                    store.devMaintenanceTab = tab
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

    // MARK: - Tab 1: AI Coding & Local LLM Models

    private var aiToolsView: some View {
        ScrollView {
            GlassGroup {
                VStack(alignment: .leading, spacing: 14) {
                    if aiBuckets.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "cpu")
                                .font(.system(size: 28))
                                .foregroundStyle(Theme.ink3)
                            Text("尚未扫描到 AI 编程工具或本地大模型占用").font(.system(size: 15, weight: .semibold))
                            Text("点击右上角「全盘深度体检」以识别 Cursor、Claude Code、Codex、WorkBuddy 与 Ollama / HuggingFace 模型。")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.ink2)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 500)
                        }
                        .frame(maxWidth: .infinity, minHeight: 240)
                        .glass(radius: 16)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 14, alignment: .top)], spacing: 14) {
                            ForEach(aiBuckets) { bucket in
                                aiBucketCard(bucket)
                            }
                        }
                    }
                }
                .padding(.horizontal, 30)
                .padding(.top, 6)
                .padding(.bottom, 28)
            }
        }
    }

    private func aiBucketCard(_ bucket: AIBucket) -> some View {
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
                    IconTile(symbol: bucket.app.group.symbol, tint: Theme.indigo, size: 30)
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

    // MARK: - Tab 3: Package Managers & Xcode Simulators

    @ViewBuilder
    private var statusBanner: some View {
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
        } else if let activeText = storageTools.activity {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(activeText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.blue)
                Spacer(minLength: 10)
                ScanProgressBar(fraction: nil, fill: Theme.accent, glow: Theme.cyan)
                    .frame(width: 120, height: 5)
            }
            .padding(12)
            .glass(radius: 12)
        } else if let msg = storageTools.message {
            let isWarning = msg.contains("失败") || msg.contains("未能") || msg.contains("跳过") || msg.contains("未成功") || msg.contains("未移除")
            HStack(spacing: 10) {
                Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isWarning ? Theme.amber : Theme.green)
                Text(msg).font(.system(size: 13, weight: .medium))
                Spacer()
                Button { storageTools.clearMessage() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.ink3)
            }
            .padding(12)
            .glass(radius: 12)
        }
    }

    private var cliToolsView: some View {
        let probes = storageTools.cliProbes
        return ScrollView {
            GlassGroup {
                VStack(alignment: .leading, spacing: 18) {
                    if storageTools.isProbingCLI {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在检测本机已安装的开发工具…").font(.system(size: 13)).foregroundStyle(Theme.ink2)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glass(radius: 14)
                    } else if probes.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "terminal").font(.system(size: 26)).foregroundStyle(Theme.ink3)
                            Text("暂未发现可清理的开发工具缓存").font(.system(size: 14.5, weight: .semibold))
                            Button("重新检测") { storageTools.refreshCLIAdapters() }
                                .buttonStyle(ToolbarButtonStyle(tinted: true))
                        }
                        .frame(maxWidth: .infinity, minHeight: 160)
                        .glass(radius: 16)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 14, alignment: .top)], spacing: 14) {
                            ForEach(probes) { probe in
                                cliAdapterCard(probe)
                            }
                        }
                    }
                }
                .padding(.horizontal, 30)
                .padding(.top, 6)
                .padding(.bottom, 28)
            }
        }
        .onAppear {
            if storageTools.cliProbes.isEmpty && !storageTools.isProbingCLI {
                storageTools.refreshCLIAdapters()
            }
        }
    }

    private func cliAdapterCard(_ probe: CLICleanerAdapters.ProbeResult) -> some View {
        let picked = storageTools.selectedCLIAdapters.contains(probe.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                IconTile(symbol: probe.id.symbol, tint: picked ? Theme.blue : Theme.ink3, size: 26)
                Text(probe.id.title)
                    .font(.system(size: 13.5, weight: .bold))
                    .lineLimit(1)
                Spacer()
                ToolCheckbox(on: picked)
            }
            Text(probe.estimatedBytes.map(ByteFormat.string) ?? "可安全清理")
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(picked ? Theme.blue : Theme.ink)
                .monospacedDigit()
            Text(probe.summary)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink2)
                .lineLimit(2, reservesSpace: true)
            Spacer(minLength: 0)
        }
        .padding(15)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(picked ? Theme.blue.opacity(0.08) : .clear)
        )
        .glass(radius: 15)
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(picked ? Theme.blue.opacity(0.5) : .clear, lineWidth: 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .onTapGesture {
            if storageTools.activity == nil {
                storageTools.toggleCLIAdapter(probe.id)
            }
        }
    }
}
