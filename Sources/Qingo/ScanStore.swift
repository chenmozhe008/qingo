import AppKit
import Foundation
import SwiftUI

@MainActor
final class ScanStore: ObservableObject {
    @Published var root = AppHome.url
    @Published var result: ScanResult? {
        didSet {
            decisionNotes = Self.decisionNotes(for: result, policy: policy)
            // Caches too small to matter are left out everywhere: listing 279 KB of logs only lengthens the list.
            let minimum = minShownBytes
            shownItems = result?.items.filter { !$0.canTrash || $0.bytes >= minimum } ?? []
            // Sidebar, cards and list all ask per category on every redraw; sort items once per result.
            var buckets: [ItemFilter: [ScanItem]] = [:]
            for category in ItemFilter.allCases { buckets[category] = shownItems.filter { category.contains($0) } }
            itemsByCategory = buckets
            spaceGrowth = result.flatMap { current in
                guard current.isQuickScan, let baseline = growthBaseline else { return nil }
                return SpaceGrowth.compare(baseline: baseline, current: current)
            }
        }
    }
    /// What grew since an earlier quick scan (`growthBaseline`); nil unless a quick scan is shown.
    @Published private(set) var spaceGrowth: SpaceGrowth?
    /// The quick scan the report compares against, saved as "quick-baseline" (see `SpaceGrowth.nextBaseline`).
    private var growthBaseline: ScanResult?
    /// Cleanable items below this are not listed or cleaned (tests set 0 for tiny fixtures; set before `result`).
    var minShownBytes: Int64 = 1_000_000
    private(set) var shownItems: [ScanItem] = []
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
    private let resultDismissTimer = ResultDismissTimer()
    @Published var cleanupReport: CleanupReport? {
        didSet {
            resultDismissTimer.cancel()
            if cleanupReport != nil {
                resultDismissTimer.schedule { [weak self] in self?.cleanupReport = nil }
            }
        }
    }
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
    @Published var spaceAlertEnabled = SpaceAlert.isEnabled {
        didSet {
            SpaceAlert.isEnabled = spaceAlertEnabled
            SpaceAlert.sync(userInitiated: spaceAlertEnabled)
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
        // Tools belong to no location. Opened from one never scanned (an external disk), the sidebar would lose
        // its categories, so fall back to the quick scan's result.
        if result == nil {
            setRoot(policy.home)
            quickMode = true
            showSavedResult()
        }
        tool = page
        selectedID = nil
        if page == .uninstall { uninstaller.loadIfNeeded() }
    }

    let policy = SafetyPolicy()
    private var scanID = UUID()
    private var scanTask: Task<Void, Never>?
    private var quickDiscoveryID: UUID?
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
        growthBaseline = loadSaved(key: Self.baselineKey)
        loadLastResult()
        uninstaller.showCachedList()
        SpaceAlert.sync()
        SpaceAlert.onOpen = { [weak self] in self?.quickScanFromAlert() }
        if SpaceAlert.openPending {
            SpaceAlert.openPending = false
            quickScanFromAlert()
        }
        // For screenshots without touching the mouse: `open -a … --args --show-about[=反馈]` / `--scan`.
        let arguments = ProcessInfo.processInfo.arguments
        if let about = arguments.first(where: { $0.hasPrefix("--show-about") }) {
            showAbout = true
            aboutTab = AboutTab(rawValue: String(about.drop { $0 != "=" }.dropFirst())) ?? .intro
        }
        if arguments.contains("--scan") { scan() }
        if arguments.contains("--quick-scan") { scanKnownCaches() }
        // Demo recordings only (QINGO_HOME set): press 清理 by itself after the given seconds.
        if AppHome.isDemo, let delay = arguments.first(where: { $0.hasPrefix("--clean-after=") }).flatMap({ Double($0.dropFirst("--clean-after=".count)) }) {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, self.result != nil else { return }
                self.reviewCleanup()
            }
        }
        // `--switch-appearance=自动|浅色|深色`: switch 3 s after launch, as a click would (checks 深色 → 自动).
        if let raw = arguments.first(where: { $0.hasPrefix("--switch-appearance=") })?.split(separator: "=").last,
           let mode = AppearanceMode.allCases.first(where: { $0.title == raw }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.appearance = mode }
        }
        // `--category=大文件与工程` (an ItemFilter raw value): open that category instead of the overview.
        if let raw = arguments.first(where: { $0.hasPrefix("--category=") }).map({ String($0.dropFirst("--category=".count)) }),
           let category = ItemFilter(rawValue: raw) {
            selectCategory(category)
        }
        // `--growth`: open the space-change report (needs a notable change against the comparison scan).
        if arguments.contains("--growth"), spaceGrowth != nil { showGrowth() }
        // `--scan-detail`: open the shown location's own page instead of the overview.
        if arguments.contains("--scan-detail") { showScanDetail() }
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
        if quickMode { return "尚未进行快速扫描" }
        if root.path == policy.home.path { return "尚未进行完整扫描" }
        return "尚未扫描「\(root.lastPathComponent)」"
    }

    var selectedItem: ScanItem? { displayedItems.first { $0.id == selectedID } }

    /// Regenerable caches: the ones "全选" and the free-space card count.
    var eligibleItems: [ScanItem] {
        shownItems.filter { $0.kind == .cache && $0.canTrash }
    }

    func isDecidable(_ item: ScanItem) -> Bool { decisionNotes[item.id] != nil }

    /// Caches, plus items the user may delete after confirming. Never picked by "全选".
    func isSelectable(_ item: ScanItem) -> Bool { (item.kind == .cache && item.canTrash) || isDecidable(item) }

    var selectableInFilter: [ScanItem] { displayedItems.filter(isSelectable) }

    var selectedCleanupItems: [ScanItem] {
        shownItems.filter { selectedCleanupIDs.contains($0.id) && isSelectable($0) }
    }

    /// Ticked in the list.
    func isPicked(_ id: URL) -> Bool { selectedCleanupIDs.contains(id) }

    var selectedDecidedItems: [ScanItem] { selectedCleanupItems.filter(isDecidable) }

    private static func decisionNotes(for result: ScanResult?, policy: SafetyPolicy) -> [URL: String] {
        var notes: [URL: String] = [:]
        // Only large files and installers are left to the user (大文件与工程). Everything else is either
        // safe to clean or not shown at all.
        for item in result?.items ?? [] where item.kind == .largeFile {
            if let note = policy.decisionNote(for: item) { notes[item.id] = note }
        }
        return notes
    }

    /// Everything safe is picked from the start: one button cleans it ("哗一下就删了").
    private func pickAllSafe() {
        selectedCleanupIDs = Set(eligibleItems.map(\.id))
    }

    var selectedCleanupBytes: Int64 { Self.sum(selectedCleanupItems) }

    /// Apps to quit before cleaning the current selection.
    /// Apps running now whose caches are in the selection; their items are skipped, not a reason to stop.
    /// Measured when the confirmation opens (checking every item on every redraw would be slow).
    @Published private(set) var runningOwners: [String] = []

    private func measureRunningOwners() {
        var names: [String] = []
        for item in itemsToClean {
            if let name = ItemPresentation.runningOwner(of: item), !names.contains(name) { names.append(name) }
        }
        runningOwners = names
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

    /// "全选" covers every safe item, in every category; large files stay the user's call.
    func selectAllEligible() {
        guard !isCleaning else { return }
        selectedCleanupIDs.formUnion(eligibleItems.map(\.id))
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

    /// The page a cleanup was started from; nil from the overview, which cleans everything selected.
    /// A category page's button only cleans that category (picking a large file must not also clean caches).
    @Published private(set) var cleanupScope: ItemFilter?

    /// Items picked from the space-change report: cleaned on their own, whatever else is selected.
    @Published private(set) var cleanupOnly: Set<URL>?

    var itemsToClean: [ScanItem] {
        if let only = cleanupOnly { return shownItems.filter { only.contains($0.id) && $0.kind == .cache && $0.canTrash } }
        guard let scope = cleanupScope else { return selectedCleanupItems }
        return selectedCleanupItems.filter { scope.contains($0) }
    }

    func selectedItems(in category: ItemFilter?) -> [ScanItem] {
        guard let category else { return selectedCleanupItems }
        return selectedCleanupItems.filter { category.contains($0) }
    }

    func reviewCleanup(scope: ItemFilter? = nil, only: Set<URL>? = nil) {
        cleanupScope = scope
        cleanupOnly = only
        guard !itemsToClean.isEmpty, !isCleaning else { return }
        hoveredID = nil
        confirmDecided = false
        // Caches go in one click: they land in the Trash and the banner offers 撤销, so a "确定吗" adds nothing.
        // Only large files, which are the user's own, get the confirmation sheet.
        guard itemsToClean.contains(where: isDecidable) else {
            trashSelectedItems()
            return
        }
        measureRunningOwners()
        showTrashConfirmation = true
    }

    /// The overview page (dial, outcome, one button, category platters), not a category's list.
    @Published var showingOverview = true
    /// The scan's own page: what this scan found, category by category. Opened from its location in the sidebar.
    @Published var showingScanDetail = false

    func showOverview() {
        tool = nil
        showingOverview = true
        showingScanDetail = false
        showingGrowth = false
        selectedID = nil
    }

    /// The space-change report, opened from the overview's card.
    @Published var showingGrowth = false

    /// Free-space samples for the report's chart, read when the report opens.
    @Published private(set) var spaceHistory: [SpaceHistory.Sample] = []

    func showGrowth() {
        spaceHistory = SpaceHistory.load()
        tool = nil
        showingOverview = false
        showingScanDetail = false
        showingGrowth = true
        selectedID = nil
    }

    /// The overview belongs to the whole Mac, so it stays reachable from a location that was never scanned
    /// (an external disk): it then falls back to the home folder's quick scan.
    func goToOverview() {
        guard !isScanning, !isCleaning else { return }
        if result == nil {
            setRoot(policy.home)
            quickMode = true
            showSavedResult()
        }
        showOverview()
    }

    func showScanDetail() {
        tool = nil
        showingOverview = false
        showingGrowth = false
        showingScanDetail = true
        selectedID = nil
    }

    func selectCategory(_ category: ItemFilter) {
        tool = nil
        showingOverview = false
        showingScanDetail = false
        showingGrowth = false
        filter = category
        selectedID = nil
    }

    /// Where "查看这 N 处" leads: the category holding most of what can be cleaned.
    var mainCleanableCategory: ItemFilter {
        items(in: .caches).contains(where: \.canTrash) ? .caches : .creative
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
        // A location opens its own page; the overview is the whole Mac.
        showScanDetail()
        if isCurrentScope(url, quick: quick), result != nil { return }
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

    /// The low-space notification was clicked: bring the window up and start a quick scan,
    /// unless a scan or cleanup is already running.
    func quickScanFromAlert() {
        NSApp.activate()
        guard !isScanning, !isCleaning else { return }
        showAbout = false
        tool = nil
        scanKnownCaches()
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
        quickDiscoveryID = isQuick ? dev.discoverIfNeeded() : nil
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
                    if isQuick { self.rotateGrowthBaseline() }
                    self.result = value
                    self.pickAllSafe()
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
        if let id = quickDiscoveryID { dev.cancelDiscovery(id) }
        quickDiscoveryID = nil
        scanTask?.cancel()
        scanTask = nil
        scanID = UUID()
        isScanning = false
        message = "扫描已取消。"
        // Return to this location's previous result instead of an empty screen.
        showSavedResult()
    }

    // MARK: Saved results (one per location)

    private var resultsDirectory: URL { AppHome.resultsDirectory }

    private func resultURL(for key: String) -> URL {
        let name = Data(key.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return resultsDirectory.appending(path: "\(name).json")
    }

    private static let baselineKey = "quick-baseline"

    private func loadSaved(key: String) -> ScanResult? {
        (try? Data(contentsOf: resultURL(for: key))).flatMap { try? JSONDecoder().decode(ScanResult.self, from: $0) }
    }

    /// Before a new quick scan overwrites the saved one, the saved one may become what the report compares against.
    private func rotateGrowthBaseline() {
        let next = SpaceGrowth.nextBaseline(current: growthBaseline, previous: loadSaved(key: "quick"), now: Date())
        guard let next, next.scannedAt != growthBaseline?.scannedAt else { return }
        growthBaseline = next
        if let data = try? JSONEncoder().encode(next) { try? data.write(to: resultURL(for: Self.baselineKey), options: .atomic) }
    }

    private func saveResult(_ value: ScanResult) {
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: resultURL(for: scopeKey), options: .atomic) }
        scanDates[scopeKey] = value.scannedAt.timeIntervalSince1970
        UserDefaults.standard.set(scopeKey, forKey: Keys.lastScope)
        refreshLargeFileSummary()
    }

    /// Large files from the last full scan of the home folder, for the overview while another scan is shown.
    struct LargeFileSummary {
        let count: Int
        let bytes: Int64
        let scannedAt: Date
    }

    @Published private(set) var largeFileSummary: LargeFileSummary?

    func refreshLargeFileSummary() {
        let value: ScanResult?
        if !quickMode, root.path == policy.home.path, let result {
            value = result
        } else {
            value = (try? Data(contentsOf: resultURL(for: Self.scopeKey(root: policy.home, quick: false))))
                .flatMap { try? JSONDecoder().decode(ScanResult.self, from: $0) }
        }
        guard let value else { largeFileSummary = nil; return }
        let large = value.items.filter { ItemFilter.large.contains($0) && FileManager.default.fileExists(atPath: $0.url.path) }
        largeFileSummary = LargeFileSummary(count: large.count, bytes: Self.sum(large), scannedAt: value.scannedAt)
    }

    /// Shows the current location's previous scan. Cleanup still re-checks each path's identity before moving.
    private func showSavedResult() {
        UserDefaults.standard.set(scopeKey, forKey: Keys.lastScope)
        guard let data = try? Data(contentsOf: resultURL(for: scopeKey)),
              let value = try? JSONDecoder().decode(ScanResult.self, from: data) else {
            result = nil
            return
        }
        // A saved result can be days old: whatever was deleted since (by a quick scan, the app itself or the user)
        // is dropped here, so the totals shown are what is still on disk.
        let present = value.items.filter { TrashService.currentIdentity($0.url) != nil }
        let checkedItems = present.map { item in
            guard item.canTrash, policy.cacheDescription(for: item.url, isDirectory: true) == nil else { return item }
            return ScanItem(id: item.id, url: item.url, kind: .review, risk: .c, bytes: item.bytes,
                            note: "清理规则已更新，此项仅显示大小。重新扫描以更新结果。", canTrash: false, identity: item.identity,
                            modified: item.modified)
        }
        result = ScanResult(root: value.root, isQuickScan: value.isQuickScan, items: checkedItems,
                            totalBytes: max(value.totalBytes - (Self.sum(value.items) - Self.sum(present)), 0), volumeTotalBytes: value.volumeTotalBytes,
                            volumeFreeBytes: value.volumeFreeBytes, skippedCount: value.skippedCount,
                            scannedCount: value.scannedCount, scannedAt: value.scannedAt, chatApps: value.chatApps,
                            availableBytes: value.availableBytes)
        pickAllSafe()
        refreshLargeFileSummary()
        // Reopen on the category last viewed, if it is still shown.
        if let saved = UserDefaults.standard.string(forKey: Keys.lastFilter).flatMap(ItemFilter.init(rawValue:)), ItemFilter.visible.contains(saved) {
            filter = saved
        } else {
            filter = .caches
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
        let items = itemsToClean
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
                let removedIDs = Set(outcome.moved.map(\.item.id) + outcome.gone)
                self.selectedCleanupIDs.subtract(removedIDs)
                // No rescan: drop what moved (or was already gone) and keep the user where they were.
                // Failed items stay, with the reason.
                self.updateResult(removing: removedIDs, adding: [])
                self.failureReasons = Dictionary(outcome.failures.map { ($0.id, $0.reason) }, uniquingKeysWith: { first, _ in first })
                self.undoable = outcome.moved
                if outcome.moved.isEmpty && outcome.failures.isEmpty {
                    self.message = "所选项目已不存在，已从列表中移除"
                } else {
                    self.cleanupReport = outcome.report
                }
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
                self.message = skipped == 0 ? "已恢复 \(restored.count) 项" : "已恢复 \(restored.count) 项，\(skipped) 项因原位置已有文件或已不在废纸篓而未恢复"
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
                                 scannedCount: value.scannedCount, scannedAt: value.scannedAt, chatApps: value.chatApps,
                                 availableBytes: value.availableBytes)
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
    /// Categories shown in the sidebar and cards. "需要判断" is no longer shown: its items asked the user to judge.
    static let visible: [ItemFilter] = [.caches, .creative, .chat, .large]

    case caches = "可清理缓存"
    case creative = "剪辑与设计软件"
    case chat = "微信与企业微信"
    case review = "需要判断"
    case large = "大文件与工程"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .creative: "创作与 AI 工具"
        case .large: "大文件"
        default: rawValue
        }
    }

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

    /// Short label for the sidebar switch; rawValue is persisted, so it stays as is.
    var title: String {
        switch self {
        case .system: "自动"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }


    /// Sets the whole app's look through AppKit only. SwiftUI's preferredColorScheme is not used: once it has
    /// forced dark, setting it back to nil does not let go, so 深色 → 自动 stayed dark (user report).
    @MainActor func apply() {
        guard let application = NSApp else { return }
        let target: NSAppearance?
        switch self {
        case .system: target = nil
        case .light: target = NSAppearance(named: .aqua)
        case .dark: target = NSAppearance(named: .darkAqua)
        }
        guard application.appearance?.name != target?.name || application.windows.contains(where: { $0.appearance != nil }) else { return }
        application.appearance = target
        // Windows inherit from the app; clear anything set on them directly.
        for window in application.windows { window.appearance = nil }
    }

}


/// One-time carry-over from the app's previous identity (Mac 清理管家, com.forwardyan.MacSpaceKeeper):
/// settings, saved folders and per-location results, so renaming does not look like a reset.
enum LegacyMigration {
    private static let doneKey = "migratedFromMacSpaceKeeper"
    private static let keys = ["appearance", "savedFolders", "scanSizes", "lastFilter", "lastScope", "scanDates"]

    static func run() {
        // A demo starts empty: carrying the old settings over would show this Mac's folders and drives.
        if AppHome.isDemo { return }
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
