import AppKit
import Foundation
import SwiftUI

@MainActor
final class ScanStore: ObservableObject {
    @Published var root = FileManager.default.homeDirectoryForCurrentUser
    @Published var result: ScanResult? {
        didSet {
            decisionNotes = Self.decisionNotes(for: result, policy: policy)
            // Sidebar, cards and list all ask per category on every redraw; sort items once per result.
            var buckets: [ItemFilter: [ScanItem]] = [:]
            for category in ItemFilter.allCases { buckets[category] = result?.items.filter { category.contains($0) } ?? [] }
            itemsByCategory = buckets
        }
    }
    private var itemsByCategory: [ItemFilter: [ScanItem]] = [:]
    /// Items the user may delete after confirming, with what deleting costs (see `SafetyPolicy.decisionNote`).
    @Published private(set) var decisionNotes: [URL: String] = [:]
    /// Why an item could not be moved in the last cleanup; shown on its row until the next scan.
    @Published var failureReasons: [URL: String] = [:]
    /// What the last cleanup moved, so it can be put back. Dropped on rescan or switching location.
    @Published private(set) var undoable: [TrashedItem] = []
    @Published var isRestoring = false
    /// The "我已确认" box in the cleanup sheet, required when the selection holds items the user decides about.
    @Published var confirmDecided = false
    @Published var isScanning = false
    @Published var progress = ScanProgress(scannedCount: 0, currentFolder: "")
    @Published var message: String?
    @Published var cleanupReport: CleanupReport?
    @Published var selectedID: URL?
    @Published var selectedCleanupIDs: Set<URL> = []
    @Published var showTrashConfirmation = false
    @Published var showAbout = false
    @Published var aboutTab: AboutTab = .intro
    @Published var appearance: AppearanceMode = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "appearance")
            appearance.apply()
        }
    }
    @Published var isCleaning = false
    @Published var cleanedCount = 0
    @Published var filter: ItemFilter = .caches {
        didSet { UserDefaults.standard.set(filter.rawValue, forKey: Keys.lastFilter) }
    }
    /// Sidebar folder row under the pointer (shows its remove button). List rows use `hover` instead.
    @Published var hoveredID: URL?
    let hover = HoverTracker()
    /// Tool id the creative page scrolls to when it appears (launch argument, for screenshots).
    var creativeScrollTarget: String?
    /// Items found so far in the running scan, newest last.
    @Published var liveFound: [ScanItem] = []
    @Published var savedFolders: [URL] = []
    @Published var hasFullDiskAccess = false
    /// Same-name rows (e.g. hundreds of __pycache__) that the user expanded.
    @Published var expandedGroups: Set<String> = []
    /// Chat app shown on the right of the WeChat page.
    @Published var selectedChatID: String?
    /// Text just copied from the About page; its button reads "已复制" briefly.
    @Published var copiedText: String?

    func copy(_ text: String) {
        AppInfo.copy(text)
        copiedText = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            if self?.copiedText == text { self?.copiedText = nil }
        }
    }

    enum ToolPage { case uninstall, dev }
    /// A tool page shown instead of the scan result; nil shows the scan result.
    @Published var tool: ToolPage?
    let dev = DevStore()
    let uninstaller = UninstallStore()

    func openTool(_ page: ToolPage) {
        guard !isScanning, !isCleaning else { return }
        tool = page
        selectedID = nil
        if page == .uninstall { uninstaller.loadIfNeeded() }
    }

    let policy = SafetyPolicy()
    private var scanID = UUID()
    private var scanTask: Task<Void, Never>?
    private var quickMode = false

    private enum Keys {
        static let savedFolders = "savedFolders"
        static let scanSizes = "scanSizes"
        static let lastFilter = "lastFilter"
        static let lastScope = "lastScope"
        static let scanDates = "scanDates"
    }

    init() {
        savedFolders = (UserDefaults.standard.stringArray(forKey: Keys.savedFolders) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        refreshFullDiskAccess()
        appearance.apply()
        loadLastResult()
        // For screenshots without touching the mouse: `open -a … --args --show-about[=反馈]` / `--scan`.
        let arguments = ProcessInfo.processInfo.arguments
        if let about = arguments.first(where: { $0.hasPrefix("--show-about") }) {
            showAbout = true
            aboutTab = AboutTab(rawValue: String(about.drop { $0 != "=" }.dropFirst())) ?? .intro
        }
        if arguments.contains("--scan") { scan() }
        // `--creative-app=workbuddy`: open the creative page scrolled to that tool.
        creativeScrollTarget = arguments.first { $0.hasPrefix("--creative-app=") }.map { String($0.dropFirst("--creative-app=".count)) }
        // `--tool=uninstall` / `--tool=dev` (add `--dev-scan` to rescan the dev folder).
        if let page = arguments.first(where: { $0.hasPrefix("--tool=") }) {
            uninstaller.pendingSelection = arguments.first { $0.hasPrefix("--select-app=") }.map { String($0.dropFirst("--select-app=".count)) }
            if arguments.contains("--orphans") { uninstaller.selectOrphans() }
            openTool(page.hasSuffix("dev") ? .dev : .uninstall)
            if arguments.contains("--dev-scan") { dev.scan() }
        }
    }

    // MARK: Derived data

    var displayedItems: [ScanItem] { items(in: filter) }

    func items(in category: ItemFilter) -> [ScanItem] {
        itemsByCategory[category] ?? []
    }

    var scopeTitle: String {
        if quickMode { return "快速扫描" }
        if root.path == policy.home.path { return "完整扫描" }
        return root.lastPathComponent
    }

    var isQuickScope: Bool { quickMode }

    /// "正在快速扫描" / "正在完整扫描" / "正在扫描「Coding」"
    var scanningTitle: String {
        if quickMode { return "正在快速扫描" }
        if root.path == policy.home.path { return "正在完整扫描" }
        return "正在扫描「\(root.lastPathComponent)」"
    }

    var notScannedTitle: String {
        if quickMode { return "还没做过快速扫描" }
        if root.path == policy.home.path { return "还没做过完整扫描" }
        return "还没扫描过「\(root.lastPathComponent)」"
    }

    var selectedItem: ScanItem? { displayedItems.first { $0.id == selectedID } }

    /// Regenerable caches: the ones "全选" and the free-space card count.
    var eligibleItems: [ScanItem] {
        result?.items.filter { $0.kind == .cache && $0.canTrash } ?? []
    }

    /// Cleanable items in the current category (footer actions work per category).
    var eligibleInFilter: [ScanItem] {
        displayedItems.filter { $0.kind == .cache && $0.canTrash }
    }

    func isDecidable(_ item: ScanItem) -> Bool { decisionNotes[item.id] != nil }

    /// Caches, plus items the user may delete after confirming. Never picked by "全选".
    func isSelectable(_ item: ScanItem) -> Bool { (item.kind == .cache && item.canTrash) || isDecidable(item) }

    var selectableInFilter: [ScanItem] { displayedItems.filter(isSelectable) }

    var selectedCleanupItems: [ScanItem] {
        result?.items.filter { selectedCleanupIDs.contains($0.id) && isSelectable($0) } ?? []
    }

    var selectedDecidedItems: [ScanItem] { selectedCleanupItems.filter(isDecidable) }

    private static func decisionNotes(for result: ScanResult?, policy: SafetyPolicy) -> [URL: String] {
        var notes: [URL: String] = [:]
        for item in result?.items ?? [] {
            if let note = policy.decisionNote(for: item) { notes[item.id] = note }
        }
        return notes
    }

    var selectedCleanupBytes: Int64 { Self.sum(selectedCleanupItems) }

    /// Apps to quit before cleaning the current selection.
    var appsToQuit: [String] {
        var names: [String] = []
        for item in selectedCleanupItems {
            let name: String?
            if let app = CreativeApp.of(item) {
                name = app.title
            } else if item.risk == .b {
                name = ItemPresentation.info(for: item).title
            } else {
                name = nil
            }
            if let name, !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// Fraction of the last scan of the same scope, when one is known.
    var estimatedProgress: Double? {
        guard let expected = scanSizes[scopeKey], expected > 0 else { return nil }
        return min(Double(progress.scannedCount) / Double(expected), 0.99)
    }

    nonisolated static func sum(_ items: [ScanItem]) -> Int64 {
        items.reduce(0) { sum, item in
            let addition = sum.addingReportingOverflow(item.bytes)
            return addition.overflow ? Int64.max : addition.partialValue
        }
    }

    // MARK: Selection

    func setCleanupSelected(_ item: ScanItem, selected: Bool) {
        guard !isCleaning, isSelectable(item), result?.items.contains(where: { $0.id == item.id }) == true else { return }
        if selected {
            selectedCleanupIDs.insert(item.id)
        } else {
            selectedCleanupIDs.remove(item.id)
        }
    }

    func selectAllEligible() {
        guard !isCleaning else { return }
        selectedCleanupIDs.formUnion(eligibleInFilter.map(\.id))
    }

    /// Regenerable caches (risk A, outside creative apps) need no app to be quit: the safe one-click pick.
    func selectReusable() {
        guard !isCleaning else { return }
        selectedCleanupIDs = Set(eligibleItems.filter { $0.risk == .a && CreativeApp.of($0) == nil }.map(\.id))
    }

    func setGroupSelected(_ items: [ScanItem], selected: Bool) {
        guard !isCleaning else { return }
        let ids = items.filter(isSelectable).map(\.id)
        if selected { selectedCleanupIDs.formUnion(ids) } else { selectedCleanupIDs.subtract(ids) }
    }

    func clearCleanupSelection() {
        guard !isCleaning else { return }
        selectedCleanupIDs.subtract(selectableInFilter.map(\.id))
    }

    func reviewCleanup() {
        guard !selectedCleanupItems.isEmpty, !isCleaning else { return }
        hoveredID = nil
        confirmDecided = false
        showTrashConfirmation = true
    }

    var isOverview: Bool { filter != .creative && filter != .chat }

    func showOverview() {
        tool = nil
        if !isOverview { filter = .caches }
        selectedID = nil
    }

    func selectCategory(_ category: ItemFilter) {
        tool = nil
        filter = category
        selectedID = nil
    }

    // MARK: Locations

    func chooseFolder() {
        guard !isCleaning else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "添加"
        if panel.runModal() == .OK, let url = panel.url {
            addSavedFolder(url)
            selectLocation(url, quick: false)
        }
    }

    func addSavedFolder(_ url: URL) {
        let url = url.standardizedFileURL
        guard url.path != policy.home.path, !savedFolders.contains(url) else { return }
        savedFolders.append(url)
        persistSavedFolders()
    }

    func removeSavedFolder(_ url: URL) {
        savedFolders.removeAll { $0 == url }
        persistSavedFolders()
    }

    private func persistSavedFolders() {
        UserDefaults.standard.set(savedFolders.map(\.path), forKey: Keys.savedFolders)
    }

    func setRoot(_ url: URL) {
        guard !isCleaning else { return }
        scanTask?.cancel()
        scanTask = nil
        scanID = UUID()
        root = url.standardizedFileURL
        result = nil
        selectedID = nil
        selectedCleanupIDs.removeAll()
        message = nil
        cleanupReport = nil
        failureReasons = [:]
        undoable = []
        isScanning = false
        progress = ScanProgress(scannedCount: 0, currentFolder: "")
    }

    /// Switch to a location and show its last result. Scanning only starts from the scan button.
    func selectLocation(_ url: URL, quick: Bool) {
        guard !isScanning, !isCleaning else { return }
        // Coming back from a tool page shows the location as it was.
        if tool != nil, isCurrentScope(url, quick: quick) {
            tool = nil
            return
        }
        tool = nil
        // Clicking the location you're already on goes back to its overview.
        if isCurrentScope(url, quick: quick), result != nil {
            showOverview()
            return
        }
        setRoot(quick ? policy.home : url)
        quickMode = quick
        showSavedResult()
    }

    func isCurrentScope(_ url: URL, quick: Bool) -> Bool {
        quick ? quickMode : (!quickMode && root.path == url.standardizedFileURL.path)
    }

    func lastScanDate(_ url: URL, quick: Bool) -> Date? {
        scanDates[Self.scopeKey(root: url.standardizedFileURL, quick: quick)].map(Date.init(timeIntervalSince1970:))
    }

    var hasHistory: Bool { !scanDates.isEmpty }

    func scanLocation(_ url: URL) {
        setRoot(url)
        quickMode = false
        scan()
    }

    func scanKnownCaches() {
        setRoot(policy.home)
        quickMode = true
        scan()
    }

    // MARK: Permissions

    /// ~/Library/Safari is readable only with Full Disk Access, so it is a reliable probe.
    func refreshFullDiskAccess() {
        let probe = policy.home.appending(path: "Library/Safari").path
        hasFullDiskAccess = (try? FileManager.default.contentsOfDirectory(atPath: probe)) != nil
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func openApp(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Scanning

    private var scopeKey: String { Self.scopeKey(root: root, quick: quickMode) }

    private static func scopeKey(root: URL, quick: Bool) -> String { quick ? "quick" : root.path }

    private var scanDates: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: Keys.scanDates) as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Keys.scanDates) }
    }

    private var scanSizes: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: Keys.scanSizes) as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Keys.scanSizes) }
    }

    func scan(clearMessage: Bool = true) {
        guard !isScanning, !isCleaning else { return }
        tool = nil
        isScanning = true
        liveFound = []
        progress = ScanProgress(scannedCount: 0, currentFolder: root.path)
        if clearMessage {
            message = nil
            cleanupReport = nil
        }
        failureReasons = [:]
        undoable = []
        let thisScan = UUID()
        scanID = thisScan
        let scanRoot = root
        let scanPolicy = policy
        let isQuick = quickMode
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let store = self
            let onProgress: @Sendable (ScanProgress) -> Void = { update in
                Task { @MainActor in
                    guard let store, store.scanID == thisScan, store.isScanning else { return }
                    if update.scannedCount >= store.progress.scannedCount { store.progress = update }
                }
            }
            var scanner = DiskScanner(policy: scanPolicy)
            scanner.onFound = { item in
                Task { @MainActor in
                    guard let store, store.scanID == thisScan, store.isScanning else { return }
                    // A cache folder replaces anything already listed inside it, same as the final result.
                    if item.kind == .cache || item.kind == .review {
                        let prefix = item.url.path + "/"
                        store.liveFound.removeAll { $0.url.path.hasPrefix(prefix) }
                    }
                    store.liveFound.append(item)
                }
            }
            let output = Result {
                var value = try isQuick ? scanner.scanKnownCaches(onProgress: onProgress) : scanner.scan(scanRoot, onProgress: onProgress)
                value.chatApps = scanner.chatAppUsage()
                return value
            }
            await MainActor.run {
                guard let self, self.scanID == thisScan else { return }
                self.scanTask = nil
                self.isScanning = false
                switch output {
                case .success(let value):
                    self.result = value
                    self.selectedCleanupIDs.removeAll()
                    // Stay on the category being viewed; a rescan should not move the user elsewhere.
                    self.selectedID = nil
                    self.scanSizes[self.scopeKey] = value.scannedCount
                    self.saveResult(value)
                case .failure(let error):
                    self.message = error is CancellationError ? "扫描已取消。" : error.localizedDescription
                }
            }
        }
    }

    func cancelScan() {
        guard isScanning else { return }
        scanTask?.cancel()
        scanTask = nil
        scanID = UUID()
        isScanning = false
        message = "扫描已取消。"
        // Return to this location's previous result instead of an empty screen.
        showSavedResult()
    }

    // MARK: Saved results (one per location)

    private var resultsDirectory: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Qingo/results")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func resultURL(for key: String) -> URL {
        let name = Data(key.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return resultsDirectory.appending(path: "\(name).json")
    }

    private func saveResult(_ value: ScanResult) {
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: resultURL(for: scopeKey), options: .atomic) }
        scanDates[scopeKey] = value.scannedAt.timeIntervalSince1970
        UserDefaults.standard.set(scopeKey, forKey: Keys.lastScope)
    }

    /// Shows the current location's previous scan. Cleanup still re-checks each path's identity before moving.
    private func showSavedResult() {
        UserDefaults.standard.set(scopeKey, forKey: Keys.lastScope)
        guard let data = try? Data(contentsOf: resultURL(for: scopeKey)),
              let value = try? JSONDecoder().decode(ScanResult.self, from: data) else {
            result = nil
            return
        }
        let checkedItems = value.items.map { item in
            guard item.canTrash, policy.cacheDescription(for: item.url, isDirectory: true) == nil else { return item }
            return ScanItem(id: item.id, url: item.url, kind: .review, risk: .c, bytes: item.bytes,
                            note: "清理规则已更新，此位置仅显示占用。重新扫描可更新结果。", canTrash: false, identity: item.identity,
                            modified: item.modified)
        }
        result = ScanResult(root: value.root, isQuickScan: value.isQuickScan, items: checkedItems,
                            totalBytes: value.totalBytes, volumeTotalBytes: value.volumeTotalBytes,
                            volumeFreeBytes: value.volumeFreeBytes, skippedCount: value.skippedCount,
                            scannedCount: value.scannedCount, scannedAt: value.scannedAt, chatApps: value.chatApps)
        // Reopen on the category last viewed.
        if let saved = UserDefaults.standard.string(forKey: Keys.lastFilter).flatMap(ItemFilter.init(rawValue:)) {
            filter = saved
        } else {
            filter = ItemFilter.allCases.first { category in value.items.contains { category.contains($0) } } ?? .caches
        }
    }

    /// On launch: reopen the location viewed last (migrating the old single last-scan file once).
    private func loadLastResult() {
        let legacy = resultsDirectory.deletingLastPathComponent().appending(path: "last-scan.json")
        if let data = try? Data(contentsOf: legacy), let value = try? JSONDecoder().decode(ScanResult.self, from: data) {
            root = value.root
            quickMode = value.isQuickScan
            saveResult(value)
            try? FileManager.default.removeItem(at: legacy)
        }
        guard let key = UserDefaults.standard.string(forKey: Keys.lastScope) else { return }
        quickMode = key == "quick"
        root = quickMode ? policy.home : URL(fileURLWithPath: key)
        showSavedResult()
    }

    // MARK: Cleanup

    func trashSelectedItems() {
        let items = selectedCleanupItems
        guard !items.isEmpty, !isCleaning else { return }
        showTrashConfirmation = false
        isCleaning = true
        cleanedCount = 0
        message = nil
        cleanupReport = nil
        let scanPolicy = policy
        failureReasons = [:]
        undoable = []
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = await TrashService.moveAll(items, policy: scanPolicy) { count in
                await MainActor.run { self?.cleanedCount = count }
            }
            await MainActor.run {
                guard let self else { return }
                self.isCleaning = false
                let movedIDs = Set(outcome.moved.map(\.item.id))
                self.selectedCleanupIDs.subtract(movedIDs)
                // No rescan: drop what moved and keep the user where they were. Failed items stay, with the reason.
                self.updateResult(removing: movedIDs, adding: [])
                self.failureReasons = Dictionary(outcome.failures.map { ($0.id, $0.reason) }, uniquingKeysWith: { first, _ in first })
                self.undoable = outcome.moved
                self.cleanupReport = outcome.report
            }
        }
    }

    /// Puts the last cleanup back where it was. Skips anything whose original place is taken again.
    func undoLastCleanup() {
        let entries = undoable
        guard !entries.isEmpty, !isCleaning, !isRestoring else { return }
        isRestoring = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let back = TrashService.putBack(entries.map { ($0.item.url, $0.trashed) })
            let restored = zip(entries, back).filter(\.1).map(\.0.item)
            let skipped = entries.count - restored.count
            await MainActor.run {
                guard let self else { return }
                self.isRestoring = false
                self.undoable = []
                self.cleanupReport = nil
                self.updateResult(removing: [], adding: restored)
                self.message = skipped == 0 ? "已放回原处 \(restored.count) 项" : "已放回 \(restored.count) 项，\(skipped) 项原位置已有新文件或已不在废纸篓，没有放回"
            }
        }
    }

    func openTrash() {
        NSWorkspace.shared.open(policy.home.appending(path: ".Trash"))
    }

    /// Edits the shown result in place after a cleanup or undo, and saves it as this location's result.
    private func updateResult(removing ids: Set<URL>, adding items: [ScanItem]) {
        guard let value = result, !(ids.isEmpty && items.isEmpty) else { return }
        let kept = value.items.filter { !ids.contains($0.id) }
        let removedBytes = Self.sum(value.items.filter { ids.contains($0.id) })
        let all = (kept + items.filter { item in !kept.contains { $0.id == item.id } }).sorted { $0.bytes > $1.bytes }
        let total = max(value.totalBytes - removedBytes, 0).addingReportingOverflow(Self.sum(items))
        let updated = ScanResult(root: value.root, isQuickScan: value.isQuickScan, items: all,
                                 totalBytes: total.overflow ? Int64.max : total.partialValue, volumeTotalBytes: value.volumeTotalBytes,
                                 volumeFreeBytes: value.volumeFreeBytes, skippedCount: value.skippedCount,
                                 scannedCount: value.scannedCount, scannedAt: value.scannedAt, chatApps: value.chatApps)
        result = updated
        saveResult(updated)
    }
}

struct TrashedItem: Sendable {
    let item: ScanItem
    /// Where macOS put it in the Trash.
    let trashed: URL
}

enum ItemFilter: String, CaseIterable, Identifiable {
    case caches = "可清理缓存"
    case creative = "剪辑与设计软件"
    case chat = "微信与企业微信"
    case review = "需要判断"
    case large = "大文件与工程"
    var id: String { rawValue }
    var title: String { self == .creative ? "创作与 AI 工具" : rawValue }

    func contains(_ item: ScanItem) -> Bool {
        let creative = CreativeApp.of(item) != nil
        switch self {
        case .caches: return item.kind == .cache && !creative
        case .creative: return creative
        case .chat: return false
        case .review: return item.kind == .review && !creative
        case .large: return (item.kind == .project || item.kind == .largeFile) && !creative
        }
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "跟随系统"
    case light = "浅色"
    case dark = "深色"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// AppKit views (window blur, dynamic NSColors) follow NSApp.appearance, not SwiftUI's scheme.
    @MainActor func apply() {
        guard let application = NSApp else { return }
        switch self {
        case .system: application.appearance = nil
        case .light: application.appearance = NSAppearance(named: .aqua)
        case .dark: application.appearance = NSAppearance(named: .darkAqua)
        }
    }
}


/// One-time carry-over from the app's previous identity (Mac 清理管家, com.forwardyan.MacSpaceKeeper):
/// settings, saved folders and per-location results, so renaming does not look like a reset.
enum LegacyMigration {
    private static let doneKey = "migratedFromMacSpaceKeeper"
    private static let keys = ["appearance", "savedFolders", "scanSizes", "lastFilter", "lastScope", "scanDates"]

    static func run() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: doneKey) {
            defaults.set(true, forKey: doneKey)
            if let old = UserDefaults(suiteName: "com.forwardyan.MacSpaceKeeper") {
                for key in keys where defaults.object(forKey: key) == nil {
                    if let value = old.object(forKey: key) { defaults.set(value, forKey: key) }
                }
            }
        }
        // Results: copy any location the new folder does not have yet (the folder itself may already exist).
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldResults = support.appending(path: "MacSpaceKeeper/results")
        let newResults = support.appending(path: "Qingo/results")
        guard let files = try? FileManager.default.contentsOfDirectory(at: oldResults, includingPropertiesForKeys: nil) else { return }
        try? FileManager.default.createDirectory(at: newResults, withIntermediateDirectories: true)
        for file in files where !FileManager.default.fileExists(atPath: newResults.appending(path: file.lastPathComponent).path) {
            try? FileManager.default.copyItem(at: file, to: newResults.appending(path: file.lastPathComponent))
        }
    }
}
