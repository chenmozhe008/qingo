import AppKit
import SwiftUI

/// Dedicated 「应用与系统维护」 page combining:
/// 1) App Uninstall & Slimming (with search, sort, app-trash sentinel toggle)
/// 2) Uninstalled App Leftovers + Login/Background LaunchAgents
/// 3) macOS Local Snapshots + DNS/Icon Repair + Deep Hidden System Space Check
struct AppsAndSystemPage: View {
    @ObservedObject var store: ScanStore
    @ObservedObject private var uninstaller: UninstallStore
    @ObservedObject private var storageTools: StorageToolsStore
    @ObservedObject private var reconciler: ReconcilerStore

    init(store: ScanStore) {
        self.store = store
        self.uninstaller = store.uninstaller
        self.storageTools = store.storageTools
        self.reconciler = store.reconciler
    }

    private var subtitleText: String {
        switch store.appsSystemTab {
        case .apps:
            "连根卸载软件及其后台残留，或仅清空单个应用的缓存而保留账号设置（共 \(uninstaller.apps.count) 个应用）。"
        case .leftovers:
            "清理卸载软件后遗留在资源库的无用文件，以及不再需要的开机自启后台服务。"
        case .system:
            "释放时间机器本地快照、刷新 DNS 与文件缩略图，并排查系统深层隐藏占用。"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    IconTile(symbol: "slider.horizontal.3", tint: Theme.orange, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("应用与系统维护").font(.system(size: 21, weight: .bold))
                        Text(subtitleText)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.ink2)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    headerActions
                }

                subTabBar

                if store.appsSystemTab == .system
                    || uninstaller.isWorking
                    || uninstaller.removingLaunchAgentID != nil
                    || reconciler.activeTaskLabel != nil
                    || reconciler.isProbingAdmin
                    || storageTools.activity != nil {
                    systemStatusBanner
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 20)
            .padding(.bottom, 12)

            switch store.appsSystemTab {
            case .apps:
                UninstallView(
                    store: uninstaller,
                    appearance: store.appearance,
                    sentinelEnabled: Binding(
                        get: { store.sentinelEnabled },
                        set: { store.setSentinelEnabled($0) }
                    ),
                    embedded: true
                )
            case .leftovers:
                leftoversAndAgentsView
            case .system:
                systemMaintenanceView
            }
        }
        .onAppear {
            uninstaller.loadIfNeeded()
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
                .alert("移除后台启动项", isPresented: Binding(
                    get: { uninstaller.pendingLaunchAgent != nil },
                    set: { if !$0 { uninstaller.pendingLaunchAgent = nil } }
                ), presenting: uninstaller.pendingLaunchAgent) { agent in
                    Button("取消", role: .cancel) {}
                    Button("移到废纸篓", role: .destructive) { uninstaller.removeLaunchAgent(agent) }
                } message: { agent in
                    Text("将尝试停用后台服务「\(agent.label)」并把配置文件移到废纸篓，可在访达中随时恢复。")
                }
        }
    }

    @ViewBuilder
    private var headerActions: some View {
        switch store.appsSystemTab {
        case .apps:
            Toggle("卸载残留提醒", isOn: Binding(
                get: { store.sentinelEnabled },
                set: { store.setSentinelEnabled($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.ink2)
            .help("把应用拖入废纸篓时自动提醒清理其关联残留")

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.ink3)
                TextField("搜索应用", text: $uninstaller.search).textFieldStyle(.plain).font(.system(size: 13))
            }
            .padding(.horizontal, 10)
            .frame(minWidth: 110, maxWidth: 180, minHeight: 30, maxHeight: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.fill(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line))

            Picker("排序", selection: $uninstaller.sort) {
                ForEach(UninstallStore.Sort.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        case .leftovers:
            let pickedGroups = (uninstaller.orphans ?? []).filter { uninstaller.pickedOrphans.contains($0.id) }
            let orphanBytes = pickedGroups.reduce(Int64(0)) { $0 + $1.bytes }
            if !pickedGroups.isEmpty {
                Button {
                    uninstaller.selectOrphans()
                    uninstaller.showConfirm = true
                } label: {
                    if uninstaller.isWorking {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small).tint(.white)
                            Text("正在清理…")
                        }
                    } else {
                        Text("清理所选残留（\(ByteFormat.string(orphanBytes))）")
                    }
                }
                .buttonStyle(HeroButtonStyle())
                .disabled(uninstaller.isWorking)
            } else {
                Button("刷新检测") { uninstaller.reload() }
                    .buttonStyle(ToolbarButtonStyle(tinted: true))
                    .disabled(uninstaller.isLoading || uninstaller.isWorking)
            }
        case .system:
            Button("查看系统更新") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!)
            }
            .buttonStyle(ToolbarButtonStyle(tinted: false))
        }
    }

    private var subTabBar: some View {
        HStack(spacing: 4) {
            ForEach(AppsSystemTab.allCases) { tab in
                let active = store.appsSystemTab == tab
                Button {
                    store.appsSystemTab = tab
                    if tab == .apps {
                        uninstaller.showOrphans = false
                        uninstaller.showLaunchAgents = false
                    }
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

    // MARK: - Tab 2: Leftovers & LaunchAgents

    private var leftoversAndAgentsView: some View {
        ScrollView {
            GlassGroup {
                VStack(alignment: .leading, spacing: 18) {
                    if let message = uninstaller.message {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                            Text(message).font(.system(size: 13, weight: .medium))
                            Spacer()
                            Button { uninstaller.message = nil } label: {
                                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.ink3)
                        }
                        .padding(12)
                        .glass(radius: 12)
                    }

                    // Section 1: Orphans
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            IconTile(symbol: "archivebox.fill", tint: Theme.orange, size: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("已卸载软件遗留文件").font(.system(size: 15, weight: .bold))
                                Text("对应应用程序已删除，以下残留的缓存与支持目录可安全移到废纸篓。")
                                    .font(.system(size: 12)).foregroundStyle(Theme.ink2)
                            }
                            Spacer()
                        }
                        .padding(16)

                        InsetHairlineDivider(leading: 16)

                        if uninstaller.isLoading && uninstaller.orphans == nil {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在比对已删除应用的残留目录…").font(.system(size: 13)).foregroundStyle(Theme.ink2)
                            }
                            .padding(16)
                        } else if let orphans = uninstaller.orphans, !orphans.isEmpty {
                            ForEach(Array(orphans.enumerated()), id: \.element.id) { idx, group in
                                if idx > 0 { InsetHairlineDivider(leading: 48) }
                                let picked = uninstaller.pickedOrphans.contains(group.id)
                                let sensitive = SensitiveApps.matches(group.id)
                                HStack(spacing: 12) {
                                    ToolCheckbox(on: picked)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 8) {
                                            Text(group.id).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                                            if sensitive {
                                                ToolTag(text: "可能包含订阅或密码配置", tint: Theme.amber)
                                            }
                                        }
                                        Text(group.traces.map { ToolText.short($0.url) }.joined(separator: "、"))
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(Theme.ink3)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer(minLength: 10)
                                    Text(ByteFormat.string(group.bytes))
                                        .font(.system(size: 13.5, weight: .semibold))
                                        .monospacedDigit()
                                    Button("在访达中显示", systemImage: "folder") {
                                        NSWorkspace.shared.activateFileViewerSelecting(group.traces.map(\.url))
                                    }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Theme.ink2)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                                .onTapGesture { uninstaller.toggleOrphan(group) }
                            }
                        } else {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.green)
                                Text("暂未发现已卸载软件的残留目录").font(.system(size: 13)).foregroundStyle(Theme.ink2)
                            }
                            .padding(16)
                        }
                    }
                    .appleGroupedCard(radius: 14)

                    // Section 2: LaunchAgents
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            IconTile(symbol: "gearshape.2.fill", tint: Theme.indigo, size: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("开机自启与后台服务").font(.system(size: 15, weight: .bold))
                                Text("移除前会尝试通知系统停用，再将配置文件移到废纸篓，随时可恢复。")
                                    .font(.system(size: 12)).foregroundStyle(Theme.ink2)
                            }
                            Spacer()
                        }
                        .padding(16)

                        InsetHairlineDivider(leading: 16)

                        if uninstaller.launchAgents.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.green)
                                Text("当前没有第三方后台自启服务").font(.system(size: 13)).foregroundStyle(Theme.ink2)
                            }
                            .padding(16)
                        } else {
                            ForEach(Array(uninstaller.launchAgents.enumerated()), id: \.element.id) { idx, agent in
                                if idx > 0 { InsetHairlineDivider(leading: 54) }
                                HStack(spacing: 12) {
                                    IconTile(symbol: agent.orphaned ? "exclamationmark.triangle.fill" : "bolt.fill",
                                             tint: agent.orphaned ? Theme.amber : Theme.indigo, size: 28)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(agent.label).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                                        HStack(spacing: 8) {
                                            if agent.orphaned {
                                                ToolTag(text: "原应用已卸载", tint: Theme.amber)
                                            }
                                            Text(agent.program ?? ToolText.short(agent.url))
                                                .font(.system(size: 11.5, design: .monospaced))
                                                .foregroundStyle(Theme.ink3)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                    }
                                    Spacer(minLength: 10)
                                    Button("在访达中显示", systemImage: "folder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([agent.url])
                                    }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Theme.ink2)
                                    Button("移到废纸篓…") {
                                        uninstaller.pendingLaunchAgent = agent
                                    }
                                    .buttonStyle(ToolbarButtonStyle(tinted: agent.orphaned))
                                    .disabled(uninstaller.isWorking || uninstaller.removingLaunchAgentID != nil)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                            }
                        }
                    }
                    .appleGroupedCard(radius: 14)
                }
                .padding(.horizontal, 30)
                .padding(.top, 6)
                .padding(.bottom, 28)
            }
        }
        .sheet(isPresented: $uninstaller.showConfirm) {
            let groups = (uninstaller.orphans ?? []).filter { uninstaller.pickedOrphans.contains($0.id) }
            TrashConfirmSheet(
                title: "删除残留",
                subtitle: "共 \(groups.count) 项，\(ByteFormat.string(groups.reduce(0) { $0 + $1.bytes }))。移到废纸篓后可随时恢复。",
                rows: groups.map {
                    ConfirmRow(
                        id: URL(fileURLWithPath: "/" + $0.id),
                        title: $0.id,
                        detail: $0.traces.map { ToolText.short($0.url) }.joined(separator: "，"),
                        bytes: $0.bytes,
                        warning: nil
                    )
                },
                confirmed: $uninstaller.confirmDecided,
                actionTitle: "移到废纸篓",
                appearance: store.appearance,
                onConfirm: uninstaller.removeOrphans,
                onCancel: { uninstaller.showConfirm = false }
            )
        }
    }

    // MARK: - Tab 3: System Snapshots & Deep Repair

    @ViewBuilder
    private var systemStatusBanner: some View {
        let uninstallTask: String? = uninstaller.isWorking
            ? "正在将所选文件移到废纸篓…"
            : (uninstaller.removingLaunchAgentID != nil ? "正在停用并移除后台启动项…" : nil)
        if let activeText = uninstallTask ?? reconciler.activeTaskLabel ?? (reconciler.isProbingAdmin ? "正在核查深层系统目录…" : nil) ?? storageTools.activity {
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
        } else if let msg = reconciler.message ?? storageTools.message {
            let isWarning = msg.contains("失败") || msg.contains("未能") || msg.contains("取消") || msg.contains("未获得") || msg.contains("未移除")
            HStack(spacing: 10) {
                Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isWarning ? Theme.amber : Theme.green)
                Text(msg).font(.system(size: 13, weight: .medium))
                Spacer()
                Button {
                    reconciler.clearMessage()
                    storageTools.clearMessage()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.ink3)
            }
            .padding(12)
            .glass(radius: 12)
        }
    }

    private var systemMaintenanceView: some View {
        ScrollView {
            GlassGroup {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 14) {
                        snapshotsCard
                        systemMaintenanceCard
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    ReconcilerInlineSection(store: reconciler)
                }
                .padding(.horizontal, 30)
                .padding(.top, 6)
                .padding(.bottom, 28)
            }
        }
        .onAppear {
            if reconciler.report == nil && !reconciler.isScanning {
                reconciler.refreshUserBlackHoles()
            }
            if storageTools.snapshots == nil {
                storageTools.refreshSnapshots()
            }
        }
    }

    private var snapshotsCard: some View {
        let snapshots = storageTools.snapshots
        let count = snapshots?.count ?? 0
        let runningSnapshots = storageTools.activity?.contains("快照") == true
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                IconTile(symbol: "clock.arrow.circlepath", tint: Theme.green, size: 28)
                Text("时间机器本地备份快照")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
            }
            Text(snapshots == nil
                 ? "正在检查时间机器本地快照…"
                 : (count > 0 ? "检测到 \(count) 份本地备份快照，释放后只清理旧快照，不影响外接备份盘与常规时间线。" : "当前启动盘没有可释放的本地快照占用。"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                if let snaps = snapshots, !snaps.isEmpty {
                    storageTools.confirmation = .snapshots(snaps)
                } else {
                    storageTools.refreshSnapshots()
                }
            } label: {
                if runningSnapshots {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在释放…")
                    }
                } else {
                    Text(snapshots == nil ? "正在检查…" : (count > 0 ? "释放快照空间…" : "重新检查快照"))
                }
            }
            .buttonStyle(ToolbarButtonStyle(tinted: count > 0))
            .disabled(snapshots == nil || storageTools.activity != nil || reconciler.activeTaskLabel != nil)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glass(radius: 15)
    }

    private var systemMaintenanceCard: some View {
        let running = reconciler.activeTaskLabel != nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                IconTile(symbol: "bolt.shield.fill", tint: Theme.indigo, size: 28)
                Text("网络与图标修复")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
            }
            Text("清理网页访问缓存（DNS）并刷新访达缩略图，解决网页打不开或文件图标异常，不影响个人文件。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                reconciler.runQuickMaintenance()
            } label: {
                if running {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在修复…")
                    }
                } else {
                    Text("开始修复")
                }
            }
            .buttonStyle(ToolbarButtonStyle(tinted: true))
            .disabled(running || storageTools.activity != nil)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glass(radius: 15)
    }
}
