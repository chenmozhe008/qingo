import AppKit
import SwiftUI

// MARK: Shared parts

/// Checkbox in the two cleanup colors: cyan for regenerable, amber for items the user decides about.
struct ToolCheckbox: View {
    let on: Bool
    var amber = false
    var partial = false

    var body: some View {
        let tint = amber ? Theme.amber : Theme.cyan
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(on ? (amber ? AnyShapeStyle(Theme.amber) : AnyShapeStyle(Theme.accent)) : AnyShapeStyle(Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(on ? .clear : (amber ? Theme.amber.opacity(0.8) : Theme.ink3), lineWidth: 1.5))
            .overlay {
                if on { Image(systemName: partial ? "minus" : "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white) }
            }
            .frame(width: 18, height: 18)
            .shadow(color: on ? tint.opacity(0.6) : .clear, radius: 5)
    }
}

struct ToolTag: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.1)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.3)))
            .fixedSize()
    }
}

/// Result line after a cleanup: what moved, undo, open the Trash; or a plain message.
struct ToolResultBanner: View {
    let report: CleanupReport?
    let message: String?
    let canUndo: Bool
    let undo: () -> Void
    let close: () -> Void

    var body: some View {
        if let report {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: report.movedCount > 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(report.movedCount > 0 ? Theme.green : Theme.amber)
                    Text(report.movedCount > 0 ? "清掉了 \(ByteFormat.string(report.movedBytes))，都在废纸篓里" : "这次没清掉")
                        .font(.system(size: 13.5, weight: .semibold))
                    if report.movedCount > 0 {
                        Text("清空废纸篓后才真正腾出空间").font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                    }
                    Spacer()
                    if canUndo { Button("撤销", action: undo).buttonStyle(GhostButtonStyle()).help("把刚才移走的放回原处") }
                    if report.movedCount > 0 {
                        Button("打开废纸篓") { NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash")) }
                            .buttonStyle(GhostButtonStyle())
                    }
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Theme.fill(0.07)))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.ink3)
                }
                if !report.failures.isEmpty {
                    ForEach(report.failures) { failure in
                        HStack(spacing: 8) {
                            Text(failure.name).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(failure.reason).font(.system(size: 12)).foregroundStyle(Theme.amber)
                        }
                        .padding(.leading, 24)
                    }
                }
            }
            .padding(12)
            .glass(radius: 12)
        } else if let message {
            Label(message, systemImage: "info.circle")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ConfirmRow: Identifiable {
    let id: URL
    let title: String
    let detail: String
    let bytes: Int64
    /// What deleting this costs; amber rows need the "我已确认" box.
    let warning: String?
}

/// Confirmation before moving things to the Trash, shared by the tool pages.
struct TrashConfirmSheet: View {
    let title: String
    let subtitle: String
    let rows: [ConfirmRow]
    @Binding var confirmed: Bool
    let actionTitle: String
    let appearance: AppearanceMode
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        let warned = rows.filter { $0.warning != nil }.count
        let height = rows.reduce(CGFloat(0)) { $0 + ($1.warning == nil ? 52 : 72) }
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.accent)
                    .shadow(color: Theme.cyan.opacity(0.5), radius: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 20, weight: .bold))
                    Text(subtitle).font(.system(size: 13.5)).foregroundStyle(Theme.ink2)
                }
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                                Text(row.detail)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(Theme.ink3)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                if let warning = row.warning {
                                    Text(warning).font(.system(size: 12)).foregroundStyle(Theme.amber).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 8)
                            Text(ByteFormat.string(row.bytes)).font(.system(size: 13.5, weight: .medium)).monospacedDigit()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
                    }
                }
            }
            .frame(height: min(height, 320))
            .glass(radius: 12)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            if warned > 0 {
                Toggle(isOn: $confirmed) {
                    Text("我已确认标黄的 \(warned) 项可以删").font(.system(size: 13, weight: .medium))
                }
                .toggleStyle(.checkbox)
            }
            HStack {
                Text("本应用不会清空废纸篓，什么时候清空由你决定。").font(.system(size: 12)).foregroundStyle(Theme.ink3)
                Spacer()
                Button("返回", action: onCancel).buttonStyle(GhostButtonStyle()).keyboardShortcut(.cancelAction)
                Button(actionTitle, action: onConfirm)
                    .buttonStyle(HeroButtonStyle())
                    .disabled(rows.isEmpty || (warned > 0 && !confirmed))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(Theme.ink)
        .background(Backdrop())
        .preferredColorScheme(appearance.colorScheme)
    }
}

enum ToolText {
    static func short(_ url: URL) -> String {
        url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    /// "今天打开 / 昨天打开 / 3 天前打开 / 5 个月没打开 / 一年多没打开"
    static func lastUsed(_ date: Date?) -> String? {
        guard let date else { return nil }
        if Calendar.current.isDateInToday(date) { return "今天打开" }
        if Calendar.current.isDateInYesterday(date) { return "昨天打开" }
        let days = Int(Date().timeIntervalSince(date) / 86_400)
        if days < 30 { return "\(max(days, 2)) 天前打开" }
        if days < 365 { return "\(days / 30) 个月没打开" }
        return days < 730 ? "一年多没打开" : "\(days / 365) 年多没打开"
    }

    /// Untouched for half a year or more: worth pointing out.
    static func isStale(_ date: Date?) -> Bool {
        guard let date else { return false }
        return Date().timeIntervalSince(date) > 180 * 86_400
    }

}

private struct ToolTopBar<Trailing: View>: View {
    let title: String
    let meta: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 17, weight: .bold))
            Text(meta).font(.system(size: 12.5)).foregroundStyle(Theme.ink3).lineLimit(1).truncationMode(.middle)
            Spacer()
            trailing
        }
        .padding(.leading, 12)
        .padding(.trailing, 18)
        .frame(height: 62)
    }
}

// MARK: Uninstall

struct UninstallView: View {
    @ObservedObject var store: UninstallStore
    let appearance: AppearanceMode

    var body: some View {
        VStack(spacing: 0) {
            ToolTopBar(title: "卸载应用", meta: store.apps.isEmpty && store.isLoading ? "正在读取…" : "\(store.apps.count) 个应用") {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.ink3)
                    TextField("搜索应用", text: $store.search).textFieldStyle(.plain).font(.system(size: 13))
                }
                .padding(.horizontal, 10)
                .frame(width: 210, height: 32)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.fill(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.line))
                Picker("排序", selection: $store.sort) {
                    ForEach(UninstallStore.Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
            }
            // Narrow windows give the list less room, so the details keep enough to read.
            GeometryReader { proxy in
                HStack(alignment: .top, spacing: 14) {
                    appList.frame(width: proxy.size.width < 760 ? 260 : 330)
                    detail.frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 18)
        }
        .sheet(isPresented: $store.showConfirm) { confirmSheet }
        .onAppear { store.loadIfNeeded() }
    }

    // MARK: List

    private var appList: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.visibleApps) { app in appRow(app) }
                }
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            orphanRow
        }
        .frame(maxHeight: .infinity)
        .glass()
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func appRow(_ app: InstalledApp) -> some View {
        let selected = store.selectedID == app.id
        let used = ToolText.lastUsed(app.lastUsed)
        return Button { withAnimation(.easeOut(duration: 0.15)) { store.select(app) } } label: {
            HStack(spacing: 12) {
                Image(nsImage: ItemPresentation.icon(forPath: app.appURL.path)).resizable().interpolation(.high).frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name).font(.system(size: 14, weight: selected ? .semibold : .medium)).lineLimit(1)
                    if let used {
                        Text(used).font(.system(size: 12)).foregroundStyle(ToolText.isStale(app.lastUsed) ? Theme.amber : Theme.ink3)
                    }
                }
                Spacer(minLength: 8)
                if let total = app.totalBytes {
                    Text(ByteFormat.string(total)).font(.system(size: 13.5, weight: .medium)).monospacedDigit()
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(selected ? Theme.blue.opacity(0.12) : .clear)
            .overlay(alignment: .leading) { if selected { Rectangle().fill(Theme.blue).frame(width: 3) } }
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var orphanRow: some View {
        let groups = store.orphans ?? []
        return Button { withAnimation(.easeOut(duration: 0.15)) { store.selectOrphans() } } label: {
            HStack(spacing: 12) {
                IconTile(symbol: "trash.slash.fill", tint: Theme.amber, size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text("已删除应用的残留").font(.system(size: 14, weight: .semibold))
                    Text(store.orphans == nil ? "正在查找…" : groups.isEmpty ? "没有发现" : "\(groups.count) 项，没有对应的 App 了")
                        .font(.system(size: 12)).foregroundStyle(Theme.ink3)
                }
                Spacer(minLength: 8)
                if !groups.isEmpty {
                    Text(ByteFormat.string(groups.reduce(0) { $0 + $1.bytes })).font(.system(size: 13.5, weight: .medium)).monospacedDigit()
                }
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ink3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(store.showOrphans ? Theme.amber.opacity(0.1) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 12) {
            ToolResultBanner(report: store.report, message: store.message, canUndo: !store.undoable.isEmpty,
                             undo: store.undo, close: { store.report = nil; store.message = nil })
            Group {
                if store.showOrphans {
                    orphanDetail
                } else if let app = store.selectedApp {
                    appDetail(app)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "app.badge.checkmark").font(.system(size: 34)).foregroundStyle(Theme.ink3)
                        Text("选一个应用，看看它在 Mac 上留了什么").font(.system(size: 14)).foregroundStyle(Theme.ink2)
                        Text("卸载时连同它的缓存、设置和后台程序一起放进废纸篓。").font(.system(size: 12.5)).foregroundStyle(Theme.ink3)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            .glass()
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private func appDetail(_ app: InstalledApp) -> some View {
        let traces = store.traces[app.id]
        let leftovers = (traces ?? []).filter { $0.kind != .app }.reduce(Int64(0)) { $0 + $1.bytes }
        return ScrollView {
            VStack(spacing: 0) {
                // Side by side when there is room; otherwise the button goes under the name, never squeezed.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 16) {
                        appIdentity(app, fitsWhole: true)
                        Spacer(minLength: 8)
                        uninstallButton(app, leftovers: leftovers, alignment: .trailing)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        appIdentity(app, fitsWhole: false)
                        uninstallButton(app, leftovers: leftovers, alignment: .leading)
                    }
                }
                .padding(18)
                if let traces {
                    // The bundle, then all small leftovers as one row (details on demand), then a tool's own data.
                    let related = traces.filter { $0.kind != .app && $0.kind != .toolData }
                    ForEach(traces.filter { $0.kind == .app }) { trace in traceRow(trace) }
                    if related.count > 1 {
                        mergedRow("相关文件", traces: related, amber: false, open: $store.showRelated)
                        if store.showRelated {
                            ForEach(related) { trace in traceRow(trace).padding(.leading, 30) }
                        }
                    } else {
                        ForEach(related) { trace in traceRow(trace) }
                    }
                    let toolData = traces.filter { $0.kind == .toolData }
                    if toolData.count > 1 {
                        mergedRow("工具数据", traces: toolData, amber: false, open: $store.showToolData)
                        if store.showToolData {
                            ForEach(toolData) { trace in traceRow(trace).padding(.leading, 30) }
                        }
                    } else {
                        ForEach(toolData) { trace in traceRow(trace) }
                    }
                } else {
                    ProgressView().padding(30)
                }
                VStack(alignment: .leading, spacing: 6) {
                    if store.isRunning(app) {
                        Label("\(app.name) 正在运行，请先退出再卸载。", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.amber)
                    }
                    if store.hasContainer(app) {
                        Text("它还有沙盒数据在 ~/Library/Containers，系统不允许其他应用读取。要彻底删，请在访达里手动删除。")
                            .font(.system(size: 12)).foregroundStyle(Theme.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
        }
    }

    /// Several traces as one row: "相关文件：缓存、偏好设置，共 5 处", or a tool's own data, unpicked by default.
    private func mergedRow(_ title: String, traces: [AppTrace], amber: Bool, open: Binding<Bool>) -> some View {
        let picked = traces.filter { store.picked.contains($0.id) }.count
        let kinds = traces.reduce(into: [String]()) { names, trace in
            if !names.contains(trace.kind.title) { names.append(trace.kind.title) }
        }
        let detail = traces.contains { $0.kind == .toolData } ? "它的对话、模型和设置，一起删除，共 \(traces.count) 处"
            : kinds.joined(separator: "、") + "，共 \(traces.count) 处"
        return HStack(spacing: 12) {
            ToolCheckbox(on: picked > 0, amber: amber, partial: picked > 0 && picked < traces.count)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13.5, weight: .medium))
                Text(detail)
                    .font(.system(size: 12)).foregroundStyle(amber ? Theme.amber : Theme.ink3).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Text(ByteFormat.string(traces.reduce(0) { $0 + $1.bytes })).font(.system(size: 13.5, weight: .medium)).monospacedDigit()
                .frame(width: 80, alignment: .trailing)
            Button { withAnimation(.easeOut(duration: 0.18)) { open.wrappedValue.toggle() } } label: {
                Image(systemName: open.wrappedValue ? "chevron.up.circle.fill" : "chevron.down.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(open.wrappedValue ? Theme.cyan : Theme.ink3)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(open.wrappedValue ? "收起" : "展开查看每一处")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { store.toggle(traces) }
    }

    private func traceRow(_ trace: AppTrace) -> some View {
        let on = trace.kind == .app || store.picked.contains(trace.id)
        return HStack(spacing: 12) {
            ToolCheckbox(on: on)
                .opacity(trace.kind == .app ? 0.6 : 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(trace.kind.title).font(.system(size: 13.5, weight: .medium))
                Text(ToolText.short(trace.url)).font(.system(size: 12)).foregroundStyle(Theme.ink3).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(ByteFormat.string(trace.bytes)).font(.system(size: 13.5, weight: .medium)).monospacedDigit().frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { store.toggle(trace) }
        .contextMenu { Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([trace.url]) } }
        .help(trace.kind == .app ? "卸载就是把 App 本身放进废纸篓" : "")
    }

    private var orphanDetail: some View {
        let groups = store.orphans ?? []
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("已删除应用的残留").font(.system(size: 20, weight: .bold))
                        Text("这些 App 已经删掉了，留下的设置和缓存没用了，可以放心清。")
                            .font(.system(size: 13)).foregroundStyle(Theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    let picked = groups.filter { store.pickedOrphans.contains($0.id) }
                    if !groups.isEmpty {
                        Button(picked.isEmpty ? "清理" : "清理 \(ByteFormat.string(picked.reduce(0) { $0 + $1.bytes }))") { store.reviewCleanup() }
                            .buttonStyle(HeroButtonStyle())
                            .disabled(picked.isEmpty || store.isWorking)
                            .opacity(picked.isEmpty ? 0.55 : 1)
                    }
                }
                .padding(18)
                if store.orphans == nil {
                    ProgressView().frame(maxWidth: .infinity).padding(30)
                } else if groups.isEmpty {
                    Label("没有发现残留", systemImage: "checkmark.circle").font(.system(size: 14)).foregroundStyle(Theme.green).padding(18)
                }
                ForEach(groups) { group in
                    HStack(spacing: 12) {
                        ToolCheckbox(on: store.pickedOrphans.contains(group.id))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(group.id).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                            Text(Array(Set(group.traces.map(\.kind.title))).sorted().joined(separator: "、") + "，共 \(group.traces.count) 处")
                                .font(.system(size: 12)).foregroundStyle(Theme.ink3).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text(ByteFormat.string(group.bytes)).font(.system(size: 13.5, weight: .medium)).monospacedDigit()
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
                    .contentShape(Rectangle())
                    .onTapGesture { store.toggleOrphan(group) }
                    .contextMenu {
                        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting(group.traces.map(\.url)) }
                    }
                }
            }
        }
    }

    // MARK: Footer & confirm

    /// The page's one action, beside the app it removes; size and what is left behind underneath.
    /// `fitsWhole`: the side-by-side layout needs the full name to fit; stacked, a long name shrinks instead.
    private func appIdentity(_ app: InstalledApp, fitsWhole: Bool) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Image(nsImage: ItemPresentation.icon(forPath: app.appURL.path)).resizable().interpolation(.high).frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name).font(.system(size: 20, weight: .bold)).lineLimit(1)
                    .minimumScaleFactor(fitsWhole ? 1 : 0.6)
                    .fixedSize(horizontal: fitsWhole, vertical: false)
                if let used = ToolText.lastUsed(app.lastUsed) {
                    Text(used).font(.system(size: 12.5)).foregroundStyle(ToolText.isStale(app.lastUsed) ? Theme.amber : Theme.ink2)
                }
                if let version = app.version { Text("版本 \(version)").font(.system(size: 12.5)).foregroundStyle(Theme.ink3) }
            }
        }
    }

    private func uninstallButton(_ app: InstalledApp, leftovers: Int64, alignment: HorizontalAlignment) -> some View {
        let bytes = (store.traces[app.id] ?? []).filter { $0.kind == .app || store.picked.contains($0.id) }.reduce(Int64(0)) { $0 + $1.bytes }
        let running = store.isRunning(app)
        return VStack(alignment: alignment, spacing: 8) {
            Button(store.isWorking ? "正在卸载…" : "卸载 \(ByteFormat.string(bytes))") { store.reviewCleanup() }
                .buttonStyle(HeroButtonStyle())
                .disabled(store.isWorking || running || store.traces[app.id] == nil)
                .opacity(running ? 0.55 : 1)
            Text(running ? "请先退出 \(app.name)" : leftovers > 0 ? "其中残留文件 \(ByteFormat.string(leftovers))" : "放进废纸篓，随时可以拖回来")
                .font(.system(size: 12)).foregroundStyle(running ? Theme.amber : Theme.ink3)
        }
    }

    @ViewBuilder
    private var confirmSheet: some View {
        if store.showOrphans {
            let groups = (store.orphans ?? []).filter { store.pickedOrphans.contains($0.id) }
            TrashConfirmSheet(title: "删除残留", subtitle: "共 \(groups.count) 项，\(ByteFormat.string(groups.reduce(0) { $0 + $1.bytes }))。放进废纸篓后随时可以恢复。",
                              rows: groups.map { ConfirmRow(id: URL(fileURLWithPath: "/" + $0.id), title: $0.id,
                                                            detail: $0.traces.map { ToolText.short($0.url) }.joined(separator: "，"),
                                                            bytes: $0.bytes, warning: nil) },
                              confirmed: $store.confirmDecided, actionTitle: "放进废纸篓", appearance: appearance,
                              onConfirm: store.removeOrphans, onCancel: { store.showConfirm = false })
        } else if let app = store.selectedApp {
            let traces = (store.traces[app.id] ?? []).filter { $0.kind == .app || store.picked.contains($0.id) }
            TrashConfirmSheet(title: "卸载 \(app.name)",
                              subtitle: "共 \(traces.count) 项，\(ByteFormat.string(traces.reduce(0) { $0 + $1.bytes }))"
                                + (traces.contains { $0.kind == .toolData } ? "，包括它的对话和设置" : "") + "。放进废纸篓后随时可以恢复。",
                              rows: traces.map { ConfirmRow(id: $0.url, title: $0.kind.title, detail: ToolText.short($0.url), bytes: $0.bytes,
                                                            warning: nil) },
                              confirmed: $store.confirmDecided, actionTitle: "卸载", appearance: appearance,
                              onConfirm: store.uninstall, onCancel: { store.showConfirm = false })
        }
    }
}

// MARK: Dev projects

struct DevProjectsView: View {
    @ObservedObject var store: DevStore
    let appearance: AppearanceMode

    var body: some View {
        VStack(spacing: 0) {
            ToolTopBar(title: "开发工程", meta: meta) {
                Button("更换文件夹…") { store.chooseRoot() }
                    .buttonStyle(ToolbarButtonStyle(large: true))
                    .disabled(store.isScanning || store.isCleaning)
                Button { store.scan() } label: { Label(store.result == nil ? "开始扫描" : "重新扫描", systemImage: "arrow.clockwise") }
                    .buttonStyle(ToolbarButtonStyle(large: true))
                    .disabled(store.isScanning || store.isCleaning)
            }
            if store.isScanning {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text("正在查找工程").font(.system(size: 18, weight: .semibold))
                    Text("已检查 \(store.scannedCount.formatted()) 项").font(.system(size: 13)).foregroundStyle(Theme.ink2).monospacedDigit()
                    Button("停止扫描") { store.cancelScan() }.buttonStyle(ToolbarButtonStyle(large: true, tinted: true))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let result = store.result {
                content(result)
            } else {
                VStack(spacing: 12) {
                    IconTile(symbol: "chevron.left.forwardslash.chevron.right", tint: Theme.blue, size: 56)
                    Text("找出工程里能清的构建缓存").font(.system(size: 22, weight: .bold)).padding(.top, 8)
                    Text("会在「\(ToolText.short(store.root))」里找。代码和依赖一个不碰，只找构建缓存。")
                        .font(.system(size: 13.5)).foregroundStyle(Theme.ink2)
                    if let message = store.message { Text(message).font(.system(size: 12.5)).foregroundStyle(Theme.amber) }
                    Button { store.scan() } label: { Label("开始扫描", systemImage: "play.fill") }
                        .buttonStyle(HeroButtonStyle())
                        .padding(.top, 14)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $store.showConfirm) { confirmSheet }
    }

    private var meta: String {
        guard let result = store.result, !store.isScanning else { return ToolText.short(store.root) }
        return "在 \(ToolText.short(result.root)) 里找到 \(result.projects.count) 个工程"
    }

    private func content(_ result: DevScanResult) -> some View {
        let total = ScanStore.sum(result.projects.flatMap(\.artifacts))
        return ScrollView {
            GlassGroup {
            VStack(alignment: .leading, spacing: 12) {
                PageHeader(symbol: "hammer.fill", tint: Theme.indigo, title: result.projects.isEmpty ? "没有需要清理的构建缓存" : "\(ByteFormat.string(total)) 构建缓存",
                           subtitle: "工程编译、运行时自动生成的缓存，删了下次会重新生成。代码、依赖和设置一个不碰。") {
                    devActions
                }
                .padding(.bottom, 4)
                ToolResultBanner(report: store.report, message: store.message, canUndo: !store.undoable.isEmpty,
                                 undo: store.undo, close: { store.report = nil; store.message = nil })
                ForEach(result.projects) { project in projectCard(project) }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 6)
            .padding(.bottom, 16)
            }
        }
    }

    private struct ArtifactGroup: Identifiable {
        let id: String
        let items: [ScanItem]
    }

    private func groups(_ project: DevProject) -> [ArtifactGroup] {
        var order: [String] = []
        var buckets: [String: [ScanItem]] = [:]
        for item in project.artifacts {
            let key = artifactTitle(item)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }
        return order.map { ArtifactGroup(id: project.id.path + "|" + $0, items: buckets[$0]!) }
            .sorted { ScanStore.sum($0.items) > ScanStore.sum($1.items) }
    }

    private func projectCard(_ project: DevProject) -> some View {
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                IconTile(symbol: "chevron.left.forwardslash.chevron.right", tint: Theme.blue, size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(project.name).font(.system(size: 14.5, weight: .semibold))
                    Text(ToolText.short(project.id)).font(.system(size: 12)).foregroundStyle(Theme.ink3).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(ByteFormat.string(project.bytes)).font(.system(size: 15, weight: .bold)).monospacedDigit()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            ForEach(groups(project)) { group in artifactRow(group, project: project) }
        }
        .glass()
    }

    private func artifactRow(_ group: ArtifactGroup, project: DevProject) -> some View {
        let first = group.items[0]
        let pickedCount = group.items.filter { store.selected.contains($0.id) }.count
        let failure = group.items.compactMap { store.failureReasons[$0.id] }.first
        let relative = { (item: ScanItem) in String(item.url.path.dropFirst(project.id.path.count + 1)) }
        // Where the copies sit: "packages/ui、apps/web 等", or the path itself for a single one.
        let places = group.items.map { item in
            let parent = (relative(item) as NSString).deletingLastPathComponent
            return parent.isEmpty ? "工程根目录" : parent
        }
        let detail = failure.map { "没清掉：\($0)" }
            ?? (group.items.count == 1 ? relative(first) : "在 " + places.prefix(2).joined(separator: "、") + (places.count > 2 ? " 等处" : ""))
        return HStack(spacing: 12) {
            ToolCheckbox(on: pickedCount > 0, partial: pickedCount > 0 && pickedCount < group.items.count)
            VStack(alignment: .leading, spacing: 3) {
                Text(group.items.count > 1 ? "\(artifactTitle(first)) \(group.items.count) 处" : artifactTitle(first))
                    .font(.system(size: 13.5, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(failure == nil ? Theme.ink3 : Theme.amber).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(ByteFormat.string(ScanStore.sum(group.items))).font(.system(size: 13.5, weight: .medium)).monospacedDigit()
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.leading, 62)
        .padding(.trailing, 18)
        .padding(.vertical, 9)
        .background(pickedCount > 0 ? Theme.cyan.opacity(0.07) : .clear)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { store.toggle(group.items) } }
        .contextMenu { Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting(group.items.map(\.url)) } }
        .help(first.note)
    }

    private func artifactTitle(_ item: ScanItem) -> String {
        let name = item.name
        switch name {
        case "node_modules": return "Node 依赖 node_modules"
        case ".venv", "venv": return "Python 虚拟环境 \(name)"
        case ".build": return "Swift 构建产物 .build"
        case "target": return "Rust 构建产物 target"
        case "__pycache__": return "Python 缓存"
        case ".pytest_cache": return "pytest 缓存"
        case ".mypy_cache": return "mypy 缓存"
        case ".ruff_cache": return "Ruff 缓存"
        case ".gradle": return "Gradle 缓存"
        case "cache" where item.url.deletingLastPathComponent().lastPathComponent == ".next": return "Next.js 构建缓存"
        default:
            if let tool = SafetyPolicy.frontEndCaches[name] { return "\(tool) 缓存 \(name)" }
            return name
        }
    }

    private var devActions: some View {
        let items = store.selectedItems
        let all = store.allArtifacts
        let allPicked = !all.isEmpty && items.count == all.count
        return HStack(spacing: 16) {
            if !all.isEmpty {
                Button(allPicked ? "取消全选" : "全选") { withAnimation(.easeOut(duration: 0.15)) { allPicked ? store.clearSelection() : store.selectAll() } }
                    .buttonStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.blue)
                    .keyboardShortcut("a", modifiers: .command)
                Button(store.isCleaning ? "正在清理…" : items.isEmpty ? "清理" : "清理 \(ByteFormat.string(ScanStore.sum(items)))") { store.reviewCleanup() }
                    .buttonStyle(HeroButtonStyle())
                    .disabled(items.isEmpty || store.isCleaning)
                    .opacity(items.isEmpty ? 0.55 : 1)
            }
        }
    }

    private var confirmSheet: some View {
        let items = store.selectedDecided + store.selectedItems.filter { !store.isDecidable($0) }
        return TrashConfirmSheet(title: "放进废纸篓",
                                 subtitle: "共 \(items.count) 项，\(ByteFormat.string(ScanStore.sum(items)))。放进废纸篓后随时可以恢复。",
                                 rows: items.map { ConfirmRow(id: $0.id, title: artifactTitle($0), detail: ToolText.short($0.url), bytes: $0.bytes,
                                                              warning: store.decisionNotes[$0.id]) },
                                 confirmed: $store.confirmDecided, actionTitle: "放进废纸篓", appearance: appearance,
                                 onConfirm: store.trashSelected, onCancel: { store.showConfirm = false })
    }
}
