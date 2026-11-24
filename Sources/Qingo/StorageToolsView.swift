import AppKit
import SwiftUI

enum StorageTool: String, Identifiable {
    case cliAdapters = "系统与工具维护"
    case duplicates = "重复文件"
    case cloud = "iCloud 下载项"
    case snapshots = "时间机器本地快照"
    case playwright = "Playwright 浏览器"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .cliAdapters: "wrench.and.screwdriver"
        case .duplicates: "doc.on.doc"
        case .cloud: "icloud.and.arrow.down"
        case .snapshots: "clock.arrow.circlepath"
        case .playwright: "globe"
        }
    }

    var subtitle: String {
        switch self {
        case .cliAdapters: "自动识别本机已安装工具，勾选后一次安全清理。未安装的工具不会显示。"
        case .duplicates: "在所选文件夹查找内容一致、大小至少 50 MB 的文件。"
        case .cloud: "移除已同步文件的本机副本，云端文件仍可重新下载。"
        case .snapshots: "本地快照用于恢复文件的早期版本。释放空间只处理启动盘的本地快照。"
        case .playwright: "查看默认缓存中的浏览器版本和项目登记状态。"
        }
    }
}

@MainActor
final class StorageToolsStore: ObservableObject {
    enum Confirmation: Identifiable {
        case duplicate(DuplicateFiles.File, keeper: DuplicateFiles.File, group: DuplicateFiles.Group)
        case smartDeduplicate([DuplicateFiles.Group])
        case cloud(URL, FileIdentity)
        case cloudBatch([CloudDownloads.LocalItem])
        case snapshots(Set<String>)
        case cliBatch([CLICleanerAdapters.AdapterID])

        var id: String {
            switch self {
            case .duplicate(let file, _, _): file.url.path
            case .smartDeduplicate: "smart-dedup"
            case .cloud(let url, _): url.path
            case .cloudBatch: "cloud-batch"
            case .snapshots: "snapshots"
            case .cliBatch: "cli-batch"
            }
        }

        var action: String {
            switch self {
            case .duplicate: "移到废纸篓"
            case .smartDeduplicate: "移走多余副本"
            case .cloud, .cloudBatch: "释放本机空间"
            case .snapshots: "释放空间"
            case .cliBatch: "清理所选"
            }
        }

        var detail: String {
            switch self {
            case .duplicate(let file, let keeper, _):
                "移到废纸篓：\(ToolText.short(file.url))\n保留：\(ToolText.short(keeper.url))"
            case .smartDeduplicate(let groups):
                "每组自动保留修改时间最早的一份，将多余副本移到废纸篓（共 \(groups.reduce(0) { $0 + max(0, $1.files.count - 1) }) 个文件），可在废纸篓恢复。"
            case .cloud(let url, _):
                "将移除「\(url.lastPathComponent)」的本机副本。再次使用时需要从 iCloud 下载。"
            case .cloudBatch(let items):
                "将移除这 \(items.count) 个已同步 iCloud 文件的本机副本（约 \(ByteFormat.string(items.reduce(0) { $0 + $1.bytes }))），云端文件完整保留。"
            case .snapshots:
                "将请求 macOS 释放约 10 GB。被移除的本地快照将无法用于恢复早期版本。"
            case .cliBatch(let adapters):
                "将依次安全清理所选的 \(adapters.count) 项：\(adapters.map(\.title).joined(separator: "、"))。"
            }
        }
    }

    @Published var presented: StorageTool?
    @Published var confirmation: Confirmation?
    @Published private(set) var results: DuplicateFiles.Result?
    @Published private(set) var folder: URL?
    @Published private(set) var cloudItems: [CloudDownloads.LocalItem]?
    @Published private(set) var isScanningCloud = false
    @Published private(set) var snapshots: Set<String>?
    @Published private(set) var playwright: PlaywrightPreview.Result?
    @Published private(set) var cliProbes: [CLICleanerAdapters.ProbeResult] = []
    @Published private(set) var isProbingCLI = false
    @Published var selectedCLIAdapters: Set<CLICleanerAdapters.AdapterID> = []
    @Published private(set) var message: String?
    @Published private(set) var activity: String?

    func clearMessage() {
        message = nil
    }

    let scanner: DuplicateFiles
    let ignoredPaths: () -> Set<String>
    private let onMoved: (URL) -> Void
    private var cancelScan: (() -> Void)?
    private let snapshotsService = TimeMachineSnapshots()

    init(policy: SafetyPolicy, ignoredPaths: @escaping () -> Set<String>, onMoved: @escaping (URL) -> Void) {
        scanner = DuplicateFiles(policy: policy)
        self.ignoredPaths = ignoredPaths
        self.onMoved = onMoved
    }

    func applyUnifiedFindings(cli: [CLICleanerAdapters.ProbeResult],
                              duplicates: DuplicateFiles.Result?,
                              cloud: [CloudDownloads.LocalItem]?,
                              snapshots: Set<String>?) {
        guard activity == nil else { return }
        cliProbes = cli
        if selectedCLIAdapters.isEmpty {
            selectedCLIAdapters = Set(cli.map(\.id))
        }
        if let duplicates {
            results = duplicates
        }
        if let cloud {
            cloudItems = cloud
        }
        if let snapshots {
            self.snapshots = snapshots
        }
    }

    func open(_ tool: StorageTool) {
        guard activity == nil else { return }
        message = nil
        presented = tool
        if tool == .cliAdapters { refreshCLIAdapters() }
        if tool == .snapshots { refreshSnapshots() }
        if tool == .playwright { refreshPlaywright() }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = folder ?? scanner.policy.home
        panel.prompt = "扫描"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url
        results = nil
        let scanner = scanner
        let ignoredPaths = ignoredPaths()
        perform("正在查找重复文件…", cancellable: true, work: { try scanner.scan(url, ignoring: ignoredPaths) }) {
            self.results = $0
        }
    }

    func scanDefaultDuplicatesIfNeeded(force: Bool = false) {
        guard force || results == nil, activity == nil else { return }
        let folders = DuplicateFiles.defaultUserFolders(home: scanner.policy.home)
        guard !folders.isEmpty else {
            results = DuplicateFiles.Result(groups: [], unreadable: 0)
            return
        }
        let scanner = scanner
        let ignored = ignoredPaths()
        perform("正在检查常见目录重复文件…", cancellable: true, work: {
            try scanner.scan(folders: folders, minimumBytes: 10_000_000, ignoring: ignored)
        }) {
            self.results = $0
        }
    }

    func rescanDuplicates() {
        guard activity == nil else { return }
        if let url = folder {
            results = nil
            let scanner = scanner
            let ignoredPaths = ignoredPaths()
            perform("正在查找重复文件…", cancellable: true, work: { try scanner.scan(url, ignoring: ignoredPaths) }) {
                self.results = $0
            }
        } else {
            scanDefaultDuplicatesIfNeeded(force: true)
        }
    }

    func refreshCloudItems(force: Bool = false) {
        guard force || cloudItems == nil, !isScanningCloud else { return }
        isScanningCloud = true
        let home = scanner.policy.home
        Task.detached(priority: .utility) { [weak self] in
            let items = CloudDownloads.scanLocalCopies(home: home, minBytes: 20_000_000)
            await MainActor.run {
                guard let self else { return }
                self.cloudItems = items
                self.isScanningCloud = false
            }
        }
    }

    func requestSmartDeduplicate() {
        guard let groups = results?.groups, !groups.isEmpty else { return }
        confirmation = .smartDeduplicate(groups)
    }

    func requestEvict(_ item: CloudDownloads.LocalItem) {
        confirmation = .cloud(item.url, item.identity)
    }

    func requestEvictAllCloud() {
        guard let items = cloudItems, !items.isEmpty else { return }
        confirmation = .cloudBatch(items)
    }

    func chooseCloudFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.directoryURL = CloudDownloads.folder
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform("正在检查同步状态…", work: { try CloudDownloads.candidate(url) }) {
            self.confirmation = .cloud(url, $0)
        }
    }

    func refreshCLIAdapters() {
        guard !isProbingCLI else { return }
        isProbingCLI = true
        let adapters = CLICleanerAdapters(home: scanner.policy.home)
        Task.detached(priority: .utility) { [weak self] in
            let available = adapters.probeAll().filter(\.available)
            await MainActor.run {
                guard let self else { return }
                self.cliProbes = available
                if self.selectedCLIAdapters.isEmpty {
                    self.selectedCLIAdapters = Set(available.map(\.id))
                }
                self.isProbingCLI = false
            }
        }
    }

    func toggleCLIAdapter(_ id: CLICleanerAdapters.AdapterID) {
        if selectedCLIAdapters.contains(id) {
            selectedCLIAdapters.remove(id)
        } else {
            selectedCLIAdapters.insert(id)
        }
    }

    func refreshSnapshots() {
        let service = snapshotsService
        Task.detached(priority: .utility) { [weak self] in
            let found = (try? service.list()) ?? []
            await MainActor.run {
                self?.snapshots = found
            }
        }
    }

    func refreshPlaywright() {
        playwright = nil
        let home = scanner.policy.home
        perform("正在读取浏览器登记…", cancellable: true, work: { try PlaywrightPreview.scan(home: home) }) {
            self.playwright = $0
        }
    }

    func requestMove(_ file: DuplicateFiles.File, in group: DuplicateFiles.Group) {
        guard let keeper = group.files.first(where: { $0.id != file.id }) else { return }
        confirmation = .duplicate(file, keeper: keeper, group: group)
    }

    func confirm(_ operation: Confirmation) {
        confirmation = nil
        switch operation {
        case .duplicate(let file, let keeper, let group):
            let scanner = scanner
            perform("正在复核两份文件…", work: { try scanner.move(file, keeping: keeper, in: group) }) { _ in
                CleanupLog.record("重复文件清理", moved: [(file.url, file.bytes)], failedCount: 0)
                let groups = self.results?.groups.compactMap { saved -> DuplicateFiles.Group? in
                    guard saved.id == group.id else { return saved }
                    let files = saved.files.filter { $0.id != file.id }
                    return files.count > 1 ? .init(digest: saved.digest, files: files) : nil
                } ?? []
                self.results = .init(groups: groups, unreadable: self.results?.unreadable ?? 0)
                self.onMoved(file.url)
                self.message = "已将「\(file.url.lastPathComponent)」移到废纸篓。"
            }
        case .smartDeduplicate(let groups):
            let scanner = scanner
            perform("正在清理多余重复副本…", work: {
                var movedLog: [(URL, Int64)] = []
                var movedURLs: [URL] = []
                var failures = 0
                for group in groups {
                    guard let keeper = DuplicateFiles.earliestKeeper(in: group) else { continue }
                    for file in group.files where file.id != keeper.id {
                        do {
                            _ = try scanner.move(file, keeping: keeper, in: group)
                            movedLog.append((file.url, file.bytes))
                            movedURLs.append(file.url)
                        } catch {
                            failures += 1
                        }
                    }
                }
                return (movedLog, movedURLs, failures)
            }) { movedLog, movedURLs, failures in
                if !movedLog.isEmpty {
                    CleanupLog.record("重复文件清理", moved: movedLog, failedCount: failures)
                }
                for url in movedURLs { self.onMoved(url) }
                let movedSet = Set(movedURLs)
                let remainingGroups = (self.results?.groups ?? []).compactMap { group -> DuplicateFiles.Group? in
                    let left = group.files.filter { !movedSet.contains($0.url) }
                    return left.count > 1 ? DuplicateFiles.Group(digest: group.digest, files: left) : nil
                }
                self.results = .init(groups: remainingGroups, unreadable: self.results?.unreadable ?? 0)
                let bytes = movedLog.reduce(Int64(0)) { $0 + $1.1 }
                self.message = failures == 0
                    ? "已移走 \(movedLog.count) 个多余副本（约 \(ByteFormat.string(bytes))），每组均保留了最早一份。"
                    : "已移走 \(movedLog.count) 个副本，\(failures) 个跳过。"
            }
        case .cloud(let url, let identity):
            perform("正在移除本机副本…", work: { try CloudDownloads.evict(url, identity: identity) }) { evicted in
                self.cloudItems?.removeAll { $0.url == url }
                self.message = evicted ? "已移除本机副本（云端保留）。" : "系统已接受请求，可在访达查看下载状态。"
            }
        case .cloudBatch(let items):
            perform("正在释放 \(items.count) 个 iCloud 本机副本…", work: {
                var count = 0
                var failed = 0
                var evictedURLs: Set<URL> = []
                for item in items {
                    do {
                        if try CloudDownloads.evict(item.url, identity: item.identity) {
                            count += 1
                            evictedURLs.insert(item.url)
                        } else {
                            failed += 1
                        }
                    } catch {
                        failed += 1
                    }
                }
                return (count, failed, evictedURLs)
            }) { count, failed, evictedURLs in
                self.cloudItems?.removeAll { evictedURLs.contains($0.url) }
                if failed == 0 {
                    self.message = "已请求释放 \(count) 个 iCloud 本机副本，云端文件完整保留。"
                } else {
                    self.message = "已请求释放 \(count) 个副本，\(failed) 个未能移除（可能正在使用或尚未同步）。"
                }
            }
        case .snapshots(let confirmed):
            let service = snapshotsService
            perform("正在释放本地快照…", work: { try service.thin(confirmed: confirmed) }) { removed, remaining in
                self.snapshots = remaining
                self.message = removed == 0 ? "系统未移除本地快照。" : "已移除 \(removed) 项本地快照。"
            }
        case .cliBatch(let batch):
            guard activity == nil, !batch.isEmpty else { return }
            let adapters = CLICleanerAdapters(home: scanner.policy.home)
            message = nil
            activity = "正在准备清理所选的 \(batch.count) 项工具…"
            Task { [weak self] in
                guard let self else { return }
                var results: [CLICleanerAdapters.ExecutionResult] = []
                for (index, id) in batch.enumerated() {
                    self.activity = "正在清理 \(id.title)（\(index + 1)/\(batch.count)）…"
                    let outcome = await Task.detached(priority: .utility) {
                        adapters.execute(id)
                    }.value
                    results.append(outcome)
                }
                self.activity = "正在刷新工具缓存大小…"
                let refreshed = await Task.detached(priority: .utility) {
                    adapters.probeAll().filter(\.available)
                }.value
                self.cliProbes = refreshed
                self.activity = nil
                let ok = results.filter(\.succeeded).count
                let failed = results.count - ok
                if failed == 0 {
                    self.message = "已完成 \(ok) 项工具缓存清理。"
                } else {
                    let firstErr = results.first { !$0.succeeded }?.message ?? ""
                    self.message = "完成 \(ok) 项，\(failed) 项未成功：\(firstErr)"
                }
            }
        }
    }

    func cancelDuplicateScan() { cancelScan?() }

    private func perform<Value: Sendable>(_ label: String, cancellable: Bool = false,
                                          work: @escaping @Sendable () throws -> Value,
                                          onSuccess: @escaping (Value) -> Void) {
        guard activity == nil else { return }
        activity = label
        message = nil
        let task = Task.detached(priority: .utility) { try work() }
        if cancellable { cancelScan = { task.cancel() } }
        Task {
            defer {
                activity = nil
                cancelScan = nil
            }
            do {
                onSuccess(try await task.value)
            } catch is CancellationError {
                message = "已取消扫描。"
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

struct StorageToolsView: View {
    @ObservedObject var model: StorageToolsStore
    let tool: StorageTool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                IconTile(symbol: tool.symbol, tint: Theme.indigo, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.rawValue).font(.system(size: 19, weight: .bold))
                    Text(tool.subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
                Button("完成") { model.presented = nil }
                    .buttonStyle(ToolbarButtonStyle(tinted: true))
                    .disabled(model.activity != nil)
            }

            switch tool {
            case .cliAdapters: cliAdapters
            case .duplicates: duplicates
            case .cloud:
                Button("选择 iCloud 文件…", action: model.chooseCloudFile)
                    .buttonStyle(HeroButtonStyle())
                    .disabled(model.activity != nil)
            case .snapshots: snapshots
            case .playwright: playwright
            }

            if let activity = model.activity {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(activity)
                    if tool == .playwright || (tool == .duplicates && model.results == nil) {
                        Button("取消扫描", action: model.cancelDuplicateScan)
                    }
                }
            }
            if let message = model.message {
                Text(message).font(.system(size: 13)).foregroundStyle(Theme.ink2)
            }
        }
        .padding(24)
        .frame(width: 680)
        .interactiveDismissDisabled(model.activity != nil)
        .alert(model.confirmation?.action ?? "", isPresented: Binding(
            get: { model.confirmation != nil },
            set: { if !$0 { model.confirmation = nil } }
        ), presenting: model.confirmation) { operation in
            Button("取消", role: .cancel) {}
            Button(operation.action, role: .destructive) { model.confirm(operation) }
        } message: { operation in
            Text(operation.detail)
        }
    }

    private var cliAdapters: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.cliProbes.isEmpty {
                Text("本机未检测到需要单独维护的工具。").foregroundStyle(Theme.ink2)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.cliProbes) { probe in
                            let picked = model.selectedCLIAdapters.contains(probe.id)
                            HStack(spacing: 12) {
                                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(picked ? Theme.blue : Theme.ink3)
                                    .font(.system(size: 16))
                                Image(systemName: probe.id.symbol)
                                    .foregroundStyle(Theme.blue)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(probe.id.title).fontWeight(.semibold)
                                    Text(probe.summary)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.ink2)
                                        .lineLimit(2)
                                }
                                Spacer()
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(picked ? Theme.selection : Theme.fill(0.05)))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(picked ? Theme.blue.opacity(0.35) : Theme.line))
                            .contentShape(Rectangle())
                            .onTapGesture { model.toggleCLIAdapter(probe.id) }
                        }
                    }
                }
                .frame(height: 280)
            }
            HStack(spacing: 10) {
                let ordered = model.cliProbes.map(\.id).filter { model.selectedCLIAdapters.contains($0) }
                Button("清理所选（\(ordered.count) 项）") {
                    model.confirmation = .cliBatch(ordered)
                }
                .buttonStyle(HeroButtonStyle())
                .disabled(ordered.isEmpty || model.activity != nil)
                Button("重新检测", action: model.refreshCLIAdapters)
                    .buttonStyle(ToolbarButtonStyle(tinted: true))
                    .disabled(model.activity != nil)
            }
        }
        .font(.system(size: 13))
    }

    private var duplicates: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("选择文件夹…", action: model.chooseFolder)
                    .buttonStyle(ToolbarButtonStyle(tinted: true))
                    .disabled(model.activity != nil)
                if let folder = model.folder {
                    Text(ToolText.short(folder)).lineLimit(1).truncationMode(.middle)
                }
            }

            if let result = model.results {
                if result.groups.isEmpty {
                    Text("未找到重复文件。")
                } else {
                    Text("找到 \(result.groups.count) 组。文件内容相同，文件名、位置和标签可能不同。")
                        .foregroundStyle(Theme.ink2)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(result.groups) { group in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("\(group.files.count) 份相同文件，每份 \(ByteFormat.string(group.files[0].bytes))")
                                        .fontWeight(.semibold)
                                    ForEach(group.files) { file in
                                        HStack(spacing: 8) {
                                            Text(ToolText.short(file.url)).lineLimit(1).truncationMode(.middle)
                                                .help(file.url.path)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            Button("在访达中显示", systemImage: "folder") {
                                                NSWorkspace.shared.activateFileViewerSelecting([file.url])
                                            }
                                            .labelStyle(.iconOnly)
                                            Button("移到废纸篓…") { model.requestMove(file, in: group) }
                                                .disabled(model.activity != nil)
                                        }
                                    }
                                }
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fill(0.05)))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
                            }
                        }
                    }
                    .frame(height: 260)
                }
                if result.unreadable > 0 {
                    Text("\(result.unreadable) 项无法读取或在扫描时发生变化。").foregroundStyle(Theme.ink2)
                }
            }
        }
        .font(.system(size: 13))
    }

    private var playwright: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let preview = model.playwright {
                Text("浏览器版本由 Playwright 管理。登记缺失或路径变化时，请在原项目中确认。")
                    .foregroundStyle(Theme.ink2)
                if preview.isInstalling { Text("检测到安装锁，请在安装结束后重新检查。") }
                if preview.customRoot { Text("检测到自定义浏览器目录。此处仅显示默认目录。") }
                if preview.unreadableRegistrations > 0 {
                    Text("\(preview.unreadableRegistrations) 条登记缺失或无法读取。")
                }
                if preview.entries.isEmpty {
                    Text("默认目录中未发现 Playwright 浏览器。")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(preview.entries) { entry in
                                HStack(spacing: 12) {
                                    Text(entry.url.lastPathComponent).fontWeight(.medium)
                                    Spacer()
                                    Text(entry.state.title).foregroundStyle(Theme.ink2)
                                    Text(entry.bytes.map(ByteFormat.string) ?? "无法测量").monospacedDigit()
                                    Button("在访达中显示", systemImage: "folder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                                    }
                                    .labelStyle(.iconOnly)
                                }
                            }
                        }
                        .padding(.trailing, 6)
                    }
                    .frame(height: min(240, CGFloat(preview.entries.count) * 36))
                }
            }
            Button("重新检查", action: model.refreshPlaywright)
                .buttonStyle(ToolbarButtonStyle(tinted: true))
                .disabled(model.activity != nil)
        }
        .font(.system(size: 13))
    }

    private var snapshots: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let snapshots = model.snapshots {
                Text(snapshots.isEmpty ? "启动盘没有 Time Machine 本地快照。" : "启动盘有 \(snapshots.count) 项 Time Machine 本地快照。")
                if !snapshots.isEmpty {
                    Button("释放空间…") { model.confirmation = .snapshots(snapshots) }
                        .buttonStyle(HeroButtonStyle())
                        .disabled(model.activity != nil)
                }
            }
            HStack {
                Button("重新检查", action: model.refreshSnapshots).disabled(model.activity != nil)
                Button("打开 Time Machine 设置") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension")!)
                }
                Link("Apple 使用说明", destination: URL(string: "https://support.apple.com/zh-cn/102154")!)
            }
            .buttonStyle(ToolbarButtonStyle(tinted: true))
        }
        .font(.system(size: 13))
    }
}
