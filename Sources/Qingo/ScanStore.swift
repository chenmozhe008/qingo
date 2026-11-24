import AppKit
import Foundation
import SwiftUI

@MainActor
final class ScanStore: ObservableObject {
    @Published var root = AppHome.url
    @Published var result: ScanResult? {
        didSet {
            if let chats = result?.chatApps, !chats.isEmpty { lastChatUsage = chats }
            decisionNotes = Self.decisionNotes(for: result, cachedLarge: cachedFullLargeItems, policy: policy)
            // Include small items once their combined size meets the display threshold.
            let ignored = Set(ignoredPaths.map { CanonicalPath.url(URL(fileURLWithPath: $0)).path })
            let visible = result?.items.filter { item in
                let path = item.url.path
                return !ignored.contains {
                    path == $0 || path.hasPrefix($0 + "/") || (item.canTrash && $0.hasPrefix(path + "/"))
                }
            } ?? []
            let smallCaches = Self.cleanupSum(visible.filter { $0.canTrash && $0.cleanupBytes < minShownBytes })
            shownItems = smallCaches >= minShownBytes ? visible : visible.filter { !$0.canTrash || $0.cleanupBytes >= minShownBytes }
            // Sidebar, cards and list all ask per category on every redraw; sort items once per result.
            var buckets: [ItemFilter: [ScanItem]] = [:]
            for category in ItemFilter.allCases { buckets[category] = shownItems.filter { category.contains($0) } }
            itemsByCategory = buckets
            refreshBrowserAvailability()
            spaceGrowth = result.flatMap { current in
                guard current.root.path == policy.home.path, let baseline = growthBaseline else { return nil }
                return SpaceGrowth.compare(baseline: baseline, current: current)
            }
        }
    }
    /// What grew since an earlier quick scan (`growthBaseline`); nil unless a quick scan is shown.
    @Published private(set) var spaceGrowth: SpaceGrowth?
    /// Live byte totals aggregated off-main-thread during a scan (avoids O(N) main-thread array filtering).
    @Published var liveCacheBytes: Int64 = 0
    @Published var liveCreativeBytes: Int64 = 0
    @Published var liveLargeBytes: Int64 = 0
    @Published var liveNotableCount: Int = 0
    @Published var liveRecentItems: [ScanItem] = []
    /// The quick scan the report compares against, saved as "quick-baseline" (see `SpaceGrowth.nextBaseline`).
    private var growthBaseline: ScanResult?
    /// 用户说「不再清理」的条目（路径）：之后的扫描结果里不显示、不进一键清理（照 CleanMyMac 的忽略列表）。
    /// 恢复在菜单「扫描 › 恢复已忽略的项目」。
    static let ignoredKey = "ignoredPaths"
    @Published private(set) var ignoredPaths = Set(UserDefaults.standard.stringArray(forKey: ScanStore.ignoredKey) ?? [])

    func ignore(_ items: [ScanItem]) {
        guard !isCleaning, !items.isEmpty else { return }
        ignoredPaths.formUnion(items.map(\.url.path))
        for item in items { selectedCleanupIDs.remove(item.id) }
        saveIgnored()
    }

    func restoreIgnored() {
        guard !isCleaning else { return }
        ignoredPaths.removeAll()
        saveIgnored()
    }

    private func saveIgnored() {
        UserDefaults.standard.set(ignoredPaths.sorted(), forKey: Self.ignoredKey)
        let current = result
        result = current   // 重新筛一遍显示的条目和统计
    }

    /// Small caches are included when they add up to at least this size.
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
    @Published var isPurging = false
    @Published var isQuittingBrowsers = false
    @Published var destination: AppDestination = .overview
    @Published var clutterTab: ClutterTab = .large
    @Published var chatAITab: ChatAITab = .chat
    @Published var devMaintenanceTab: DevMaintenanceTab = .ai
    @Published var appsSystemTab: AppsSystemTab = .apps
    @Published var largeFileScope: LargeFileScope = .all
    @Published var showingSmartCleanDetail = false
    @Published var expandedJunkCategories: Set<String> = ["appCache", "browserCache", "aiCreative", "devBuild", "logsLeftovers"]
    @Published var scanModules: [ScanModuleProgress] = []
    @Published var includeOrphansInSmartClean = true
    @Published var confirmDevIdle = false
    @Published var expandCLITools = false
    @Published var sentinelEnabled: Bool = UserDefaults.standard.object(forKey: TrashSentinel.enabledKey) as? Bool ?? true
    @Published var sentinelAlert: TrashSentinel.TrashedAppAlert?
    private var trashSentinel: TrashSentinel?
    /// The "我已确认" box in the cleanup sheet, required when the selection holds items the user decides about.
    @Published var confirmDecided = false
    @Published var isScanning = false
    @Published var progress = ScanProgress(scannedCount: 0, currentFolder: "")
    /// When the running scan started: the progress bar counts from here (see `estimatedProgress`).
    @Published private(set) var scanStartedAt: Date?
    @Published var message: String?
    private let resultDismissTimer = ResultDismissTimer()
    @Published var cleanupReport: CleanupReport? {
        didSet {
            resultDismissTimer.cancel()
            if cleanupReport?.failures.isEmpty == true {
                resultDismissTimer.schedule { [weak self] in self?.cleanupReport = nil }
            }
        }
    }
    @Published var selectedID: URL?
    @Published var selectedCleanupIDs: Set<URL> = []
    @Published var showTrashConfirmation = false
    @Published var showCleanupHistory = false
    @Published var showingHistory = false
    @Published private(set) var cleanupHistory: [CleanupLog.Entry] = []
    @Published private(set) var historyReadings: [String: VolumeSpaceReading] = [:]
    @Published private(set) var readingHistoryVolumes = false

    func openCleanupHistory() {
        guard !isScanning, !isCleaning else { return }
        cleanupHistory = CleanupLog.load()
        tool = nil
        showingSpaceMap = false
        showingOverview = false
        showingScanDetail = false
        showingGrowth = false
        showingHistory = true
        selectedID = nil
        refreshHistoryVolumes()
    }

    func refreshHistoryVolumes() {
        guard !readingHistoryVolumes else { return }
        let mounts = Set(cleanupHistory.flatMap { ($0.volumes ?? []).map(\.before.mount) })
        guard !mounts.isEmpty else { return }
        readingHistoryVolumes = true
        Task {
            historyReadings = await Task.detached(priority: .utility) {
                mounts.reduce(into: [String: VolumeSpaceReading]()) { values, mount in
                    if let reading = VolumeSpaceReading.read(at: mount) { values[reading.uuid] = reading }
                }
            }.value
            readingHistoryVolumes = false
        }
    }

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
    @Published var cleaningTotalCount = 0
    @Published var cleaningCurrentItem = ""
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
    /// Built when the feedback page opens, so the page shows exactly what gets copied or mailed.
    @Published var diagnosticsText = ""
    @Published var onlineReleases: [HistoryEntry] = []
    @Published var releaseHistoryMessage: String?
    @Published var loadingReleaseHistory = false

    private static let releaseHistoryCacheKey = "qingoReleaseHistory"

    func loadReleaseHistory() {
        guard !loadingReleaseHistory else { return }
        if onlineReleases.isEmpty,
           let cachedData = UserDefaults.standard.data(forKey: Self.releaseHistoryCacheKey),
           let cached = ReleaseHistory.online(cachedData) {
            onlineReleases = cached
        }
        guard !AppHome.isDemo else { return }
        loadingReleaseHistory = true
        releaseHistoryMessage = nil
        Task {
            defer { loadingReleaseHistory = false }
            var request = URLRequest(
                url: URL(string: "https://api.github.com/repos/chenmozhe008/qingo/releases?per_page=100")!,
                timeoutInterval: 15
            )
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await UpdateChecker.fetchGitHubData(request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let rows = ReleaseHistory.online(data) else {
                    throw URLError(.badServerResponse)
                }
                onlineReleases = rows
                UserDefaults.standard.set(data, forKey: Self.releaseHistoryCacheKey)
                releaseHistoryMessage = rows.isEmpty ? "GitHub 暂无正式发布记录，下面显示本机记录。" : nil
            } catch {
                releaseHistoryMessage = "暂时连不上 GitHub，下面显示本机记录。"
            }
        }
    }

    func refreshDiagnostics() { diagnosticsText = Diagnostics.report() }

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
    let updates = UpdateChecker()

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
        showingSpaceMap = false
        showingHistory = false
        showingSmartCleanDetail = false
        selectedID = nil
        if page == .uninstall {
            destination = .apps
            uninstaller.loadIfNeeded()
        }
    }

    func navigate(to dest: AppDestination) {
        guard !isScanning, !isCleaning else { return }
        destination = dest
        showingHistory = false
        showingGrowth = false
        showingScanDetail = false
        showingSmartCleanDetail = false
        selectedID = nil

        switch dest {
        case .overview:
            tool = nil
            showingSpaceMap = false
            showingOverview = true
            if result == nil && hasHistory {
                setRoot(policy.home)
                if FileManager.default.fileExists(atPath: resultURL(for: "overview").path) {
                    unifiedOverviewMode = true
                    quickMode = false
                } else {
                    unifiedOverviewMode = false
                    quickMode = true
                }
                showSavedResult()
            }
            if reconciler.report == nil && !reconciler.isScanning {
                reconciler.refreshUserBlackHoles()
            }
            if storageTools.snapshots == nil { storageTools.refreshSnapshots() }
            if storageTools.cliProbes.isEmpty { storageTools.refreshCLIAdapters() }
        case .spaceLens:
            showSpaceMap()
            if spaceLens.entries.isEmpty && !spaceLens.isLoading {
                spaceLens.navigate(to: policy.home)
            }
        case .clutter:
            tool = nil
            showingSpaceMap = false
            showingOverview = false
            if reconciler.report == nil && !reconciler.isScanning {
                reconciler.refreshUserBlackHoles()
            }
            storageTools.scanDefaultDuplicatesIfNeeded()
            storageTools.refreshCloudItems()
        case .chatAI:
            tool = nil
            showingSpaceMap = false
            showingOverview = false
            if let current = result, current.chatApps.isEmpty, !isMeasuringChatUsage {
                measureChatUsage(policy: policy, scanID: scanID)
            }
        case .devMaintenance:
            tool = nil
            showingSpaceMap = false
            showingOverview = false
            if storageTools.cliProbes.isEmpty { storageTools.refreshCLIAdapters() }
            if storageTools.snapshots == nil { storageTools.refreshSnapshots() }
            _ = dev.discoverIfNeeded()
        case .apps:
            if reconciler.report == nil && !reconciler.isScanning {
                reconciler.refreshUserBlackHoles()
            }
            if storageTools.snapshots == nil { storageTools.refreshSnapshots() }
            openTool(.uninstall)
        }
    }

    func volumeCapacity(for url: URL) -> (total: Int64, free: Int64)? {
        let canonical = CanonicalPath.url(url).path
        if let found = displayVolumes[canonical] {
            return (found.total, found.free)
        }
        // Match longest cached external volume root prefix so drilling into subfolders never hits disk synchronously.
        if let matchedKey = displayVolumes.keys
            .filter({ $0 != "/" && (canonical == $0 || canonical.hasPrefix($0 + "/")) })
            .max(by: { $0.count < $1.count }),
           let found = displayVolumes[matchedKey] {
            return (found.total, found.free)
        }
        if !canonical.hasPrefix("/Volumes/"), let homeVol = displayVolumes[policy.home.path] {
            return (homeVol.total, homeVol.free)
        }
        if let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
           let total = values.volumeTotalCapacity.map(Int64.init),
           let free = values.volumeAvailableCapacityForImportantUsage {
            return (total, free)
        }
        return displayVolumes[policy.home.path].map { ($0.total, $0.free) }
    }

    let policy: SafetyPolicy
    private var scanID = UUID()
    private var scanTask: Task<Void, Never>?
    private var scanFeedTask: Task<Void, Never>?
    private var chatUsageTask: Task<Void, Never>?
    private var lastChatUsage: [ChatAppUsage] = []
    @Published private(set) var isMeasuringChatUsage = false
    @Published private(set) var externalVolumes: [URL] = []
    @Published private(set) var displayVolumes: [String: DisplayVolume] = [:]
    private var volumeRefresh: Task<Void, Never>?

    func refreshDisplayVolumes() {
        guard volumeRefresh == nil else { return }
        let home = AppHome.url
        let root = self.root
        let demo = AppHome.isDemo
        volumeRefresh = Task {
            // Publish the internal volume first so a slow external disk does not delay the overview.
            if let internalVolume = await Task.detached(priority: .utility, operation: {
                DisplayVolume.read(at: home)
            }).value {
                displayVolumes[home.path] = internalVolume
            }
            if !demo {
                let locations = await Task.detached(priority: .utility, operation: DisplayVolume.externalLocations).value
                externalVolumes = locations
                let extra = Set(locations + [root]).filter { $0.path != home.path }
                let external = await Task.detached(priority: .utility) {
                    extra.reduce(into: [String: DisplayVolume]()) { volumes, url in
                        if let value = DisplayVolume.read(at: url) { volumes[url.path] = value }
                    }
                }.value
                displayVolumes = displayVolumes.filter { $0.key == home.path }
                displayVolumes.merge(external) { _, updated in updated }
            }
            volumeRefresh = nil
        }
    }
    private var quickMode = false
    private var unifiedOverviewMode = false

    private enum Keys {
        static let savedFolders = "savedFolders"
        static let scanSizes = "scanSizes"
        static let scanDurations = "scanDurations"
        static let lastFilter = "lastFilter"
        static let lastScope = "lastScope"
        static let scanDates = "scanDates"
    }

    init(policy: SafetyPolicy = SafetyPolicy()) {
        self.policy = policy
        savedFolders = (UserDefaults.standard.stringArray(forKey: Keys.savedFolders) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        refreshFullDiskAccess()
        appearance.apply()
        growthBaseline = loadSaved(key: Self.baselineKey)
        loadLastResult()
        uninstaller.showCachedList()
        SpaceAlert.sync()
        updates.checkIfDue()
        startTrashSentinel()
        if hasHistory {
            reconciler.refreshUserBlackHoles()
        }
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
        // `--category=chat` (an ItemFilter id, or its old label): open that category instead of the overview.
        if let raw = arguments.first(where: { $0.hasPrefix("--category=") }).map({ String($0.dropFirst("--category=".count)) }),
           let category = ItemFilter.fromStored(raw) {
            selectCategory(category)
        }
        // `--chat=com.tencent.WeWorkMac`: show that app on the chat page (the second one is otherwise never shown).
        if let raw = arguments.first(where: { $0.hasPrefix("--chat=") }).map({ String($0.dropFirst("--chat=".count)) }) {
            selectedChatID = raw
        }
        // `--growth`: open the space-change report (needs a notable change against the comparison scan).
        if arguments.contains("--growth"), spaceGrowth != nil { showGrowth() }
        if arguments.contains("--space-map") { navigate(to: .spaceLens) }
        if let tabArg = arguments.first(where: { $0.hasPrefix("--space-tab=") }) {
            let key = String(tabArg.dropFirst("--space-tab=".count))
            switch key {
            case "explore": navigate(to: .spaceLens)
            case "clutter": navigate(to: .clutter)
            case "system": navigate(to: .overview)
            default: navigate(to: .spaceLens)
            }
        }
        if let destArg = arguments.first(where: { $0.hasPrefix("--dest=") }) {
            let key = String(destArg.dropFirst("--dest=".count))
            switch key {
            case "spaceLens": navigate(to: .spaceLens)
            case "clutter": navigate(to: .clutter)
            case "apps": navigate(to: .apps)
            case "overview", "smartClean", "maintenance": navigate(to: .overview)
            default: navigate(to: .overview)
            }
        }
        if arguments.contains("--history") { openCleanupHistory() }
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
    var isUnifiedOverview: Bool { unifiedOverviewMode }

    /// "正在深度扫描你的 Mac" / "正在快速扫描缓存" / "正在完整扫描" / "正在扫描「Coding」"
    var scanningTitle: String {
        if unifiedOverviewMode { return "正在全盘深度扫描你的 Mac" }
        if quickMode { return "正在快速扫描常用缓存" }
        if root.path == policy.home.path { return "正在完整扫描" }
        return "正在扫描「\(root.lastPathComponent)」"
    }

    var notScannedTitle: String {
        if quickMode { return "尚未进行快速扫描" }
        if root.path == policy.home.path { return "尚未进行完整扫描" }
        return "尚未扫描「\(root.lastPathComponent)」"
    }

    var selectedItem: ScanItem? { displayedItems.first { $0.id == selectedID } }

    @Published private(set) var deferredBrowsers: [URL: String] = [:]

    var deferredBrowserBytes: Int64 {
        Self.cleanupSum(shownItems.filter { deferredBrowsers[$0.id] != nil })
    }

    func refreshBrowserAvailability(runningBundleIDs: Set<String>? = nil) {
        let running = runningBundleIDs ?? Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let blocked = shownItems.reduce(into: [URL: String]()) { result, item in
            guard item.kind == .cache, item.canTrash, let browser = BrowserCaches.owner(of: item.url, home: policy.home),
                  running.contains(browser.bundleID) else { return }
            result[item.id] = browser.name
        }
        guard blocked != deferredBrowsers else { return }
        let unblocked = Set(shownItems.map(\.id)).intersection(deferredBrowsers.keys).subtracting(blocked.keys)
        deferredBrowsers = blocked
        selectedCleanupIDs.subtract(blocked.keys)
        selectedCleanupIDs.formUnion(unblocked)
    }

    /// Regenerable caches available for "全选" and the one-click total.
    var eligibleItems: [ScanItem] {
        shownItems.filter { $0.kind == .cache && $0.canTrash && deferredBrowsers[$0.id] == nil }
    }

    func isDecidable(_ item: ScanItem) -> Bool { decisionNotes[item.id] != nil }

    /// Caches, plus items the user may delete after confirming. Never picked by "全选".
    func isSelectable(_ item: ScanItem) -> Bool {
        (item.kind == .cache && item.canTrash && deferredBrowsers[item.id] == nil) || isDecidable(item)
    }

    var selectableInFilter: [ScanItem] { displayedItems.filter(isSelectable) }

    var selectedCleanupItems: [ScanItem] {
        var seen: Set<URL> = []
        let pool = (shownItems + cachedFullLargeItems).filter { seen.insert($0.id).inserted }
        return pool.filter { selectedCleanupIDs.contains($0.id) && isSelectable($0) }
    }

    /// Ticked in the list.
    func isPicked(_ id: URL) -> Bool { selectedCleanupIDs.contains(id) }

    var selectedDecidedItems: [ScanItem] { selectedCleanupItems.filter(isDecidable) }

    private static func decisionNotes(for result: ScanResult?, cachedLarge: [ScanItem] = [], policy: SafetyPolicy) -> [URL: String] {
        var notes: [URL: String] = [:]
        // Large files and iOS backups are opt-in. Other review rows are handled in their own tools.
        let pool = (result?.items ?? []) + cachedLarge
        for item in pool where item.kind == .largeFile || ItemFilter.isIOSBackup(item) {
            if let note = policy.decisionNote(for: item) { notes[item.id] = note }
        }
        return notes
    }

    /// Everything safe is picked from the start: one button cleans it ("哗一下就删了").
    private func pickAllSafe() {
        selectedCleanupIDs = Set(eligibleItems.map(\.id))
    }

    var selectedCleanupBytes: Int64 { Self.cleanupSum(selectedCleanupItems) }

    /// Apps to quit before cleaning the current selection.
    /// Apps running now whose caches are in the selection; their items are skipped, not a reason to stop.
    /// Measured when the confirmation opens (checking every item on every redraw would be slow).
    @Published private(set) var runningOwners: [String] = []

    private func measureRunningOwners() {
        runningOwners = ItemPresentation.runningOwners(for: itemsToClean, home: policy.home)
    }

    /// Fraction of the last scan of the same scope, when one is known.
    ///
    /// Measured against the time the last scan took, not the item count: counting files hits the old total
    /// within seconds (one folder can hold most of them), which used to leave the bar full for the rest of
    /// the scan (reported 2026-10-31). A first scan of a scope shows the sweeping band instead.
    var estimatedProgress: Double? {
        guard let started = scanStartedAt, let expected = scanDurations[scopeKey], expected > 1 else { return nil }
        return min(Date().timeIntervalSince(started) / expected, 0.97)
    }

    nonisolated static func sum(_ items: [ScanItem]) -> Int64 { total(items, bytes: \.bytes) }

    nonisolated static func cleanupSum(_ items: [ScanItem]) -> Int64 { total(items, bytes: \.cleanupBytes) }

    private nonisolated static func total(_ items: [ScanItem], bytes: KeyPath<ScanItem, Int64>) -> Int64 {
        items.reduce(0) { sum, item in
            let addition = sum.addingReportingOverflow(item[keyPath: bytes])
            return addition.overflow ? Int64.max : addition.partialValue
        }
    }

    // MARK: Selection

    func toggleSelection(_ item: ScanItem) {
        setCleanupSelected(item, selected: !isPicked(item.id))
    }

    func setCleanupSelected(_ item: ScanItem, selected: Bool) {
        guard !isCleaning, isSelectable(item) else { return }
        let existsInResult = result?.items.contains(where: { $0.id == item.id }) == true
            || cachedFullLargeItems.contains(where: { $0.id == item.id })
        guard existsInResult else { return }
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
        if let only = cleanupOnly {
            var seen: Set<URL> = []
            let pool = (shownItems + cachedFullLargeItems).filter { seen.insert($0.id).inserted }
            return pool.filter { only.contains($0.id) && isSelectable($0) }
        }
        guard let scope = cleanupScope else { return selectedCleanupItems }
        return selectedCleanupItems.filter { scope.contains($0) }
    }

    var selectedCacheItems: [ScanItem] {
        selectedItems(in: .caches)
    }

    var selectedCacheBytes: Int64 {
        Self.cleanupSum(selectedCacheItems)
    }

    var safeOrphanGroups: [OrphanGroup] {
        (uninstaller.orphans ?? []).filter { !SensitiveApps.matches($0.id) }
    }

    var safeOrphanBytes: Int64 {
        safeOrphanGroups.reduce(0) { sum, g in
            let add = sum.addingReportingOverflow(g.bytes)
            return add.overflow ? Int64.max : add.partialValue
        }
    }

    var smartCleanTotalSelectedBytes: Int64 {
        let orphanAdd = includeOrphansInSmartClean ? safeOrphanBytes : 0
        let add = selectedCacheBytes.addingReportingOverflow(orphanAdd)
        return add.overflow ? Int64.max : add.partialValue
    }

    func triggerSmartClean() {
        guard !isCleaning else { return }
        let caches = selectedCacheItems.filter { $0.kind == .cache && $0.canTrash && !isDecidable($0) }
        let directItems = caches.filter { policy.isDirectPurgeEligible($0) }
        let reversibleItems = caches.filter { !policy.isDirectPurgeEligible($0) }
        let orphanGroups = (includeOrphansInSmartClean && !uninstaller.isWorking) ? safeOrphanGroups : []
        let orphanTraces = orphanGroups.flatMap(\.traces)
        let totalCount = directItems.count + reversibleItems.count + orphanTraces.count
        guard totalCount > 0 else { return }

        showTrashConfirmation = false
        isCleaning = true
        cleanedCount = 0
        cleaningTotalCount = totalCount
        cleaningCurrentItem = directItems.first?.name ?? reversibleItems.first?.name ?? orphanGroups.first?.id ?? ""
        message = nil
        cleanupReport = nil
        failureReasons = [:]
        undoable = []

        if !orphanTraces.isEmpty {
            uninstaller.isWorking = true
        }

        let scanPolicy = SafetyPolicy(
            home: policy.home,
            extraProtected: policy.extraProtectedRoots + ignoredPaths.map { URL(fileURLWithPath: $0) }
        )
        let base1 = directItems.count
        let base2 = base1 + reversibleItems.count

        Task.detached(priority: .userInitiated) { [weak self] in
            let purgeOutcome: CleanupOutcome
            if directItems.isEmpty {
                purgeOutcome = CleanupOutcome()
            } else {
                purgeOutcome = await TrashService.purgeAll(
                    directItems,
                    policy: scanPolicy,
                    onCurrentItem: { name in
                        await MainActor.run { self?.cleaningCurrentItem = name }
                    },
                    progress: { count in
                        await MainActor.run { self?.cleanedCount = count }
                    }
                )
            }

            let moveOutcome: CleanupOutcome
            if reversibleItems.isEmpty {
                moveOutcome = CleanupOutcome()
            } else {
                moveOutcome = await TrashService.moveAll(
                    reversibleItems,
                    policy: scanPolicy,
                    onCurrentItem: { name in
                        await MainActor.run { self?.cleaningCurrentItem = name }
                    },
                    progress: { count in
                        await MainActor.run { self?.cleanedCount = base1 + count }
                    }
                )
            }

            var orphanMovedPaths: Set<String> = []
            var orphanMovedEntries: [(url: URL, bytes: Int64)] = []
            var orphanMovedBytes: Int64 = 0
            var orphanFailures: [CleanupReport.Failure] = []
            if !orphanTraces.isEmpty {
                let installerService = AppUninstaller(policy: scanPolicy)
                for (index, trace) in orphanTraces.enumerated() {
                    await MainActor.run { self?.cleaningCurrentItem = trace.url.lastPathComponent }
                    do {
                        _ = try installerService.moveTrace(trace, of: nil)
                        orphanMovedPaths.insert(trace.url.path)
                        orphanMovedEntries.append((trace.url, trace.bytes))
                        let add = orphanMovedBytes.addingReportingOverflow(trace.bytes)
                        orphanMovedBytes = add.overflow ? Int64.max : add.partialValue
                    } catch {
                        orphanFailures.append(
                            CleanupReport.Failure(
                                id: trace.url,
                                name: trace.url.lastPathComponent,
                                reason: TrashService.reason(for: error)
                            )
                        )
                    }
                    await MainActor.run { self?.cleanedCount = base2 + index + 1 }
                }
            }

            await MainActor.run {
                guard let self else { return }
                self.isCleaning = false
                self.cleaningCurrentItem = ""
                if !orphanTraces.isEmpty {
                    self.uninstaller.applyRemovedOrphans(movedPaths: orphanMovedPaths)
                }

                let removedIDs = Set(purgeOutcome.purgedIDs + purgeOutcome.gone + moveOutcome.moved.map(\.item.id) + moveOutcome.gone)
                self.selectedCleanupIDs.subtract(removedIDs)
                if !removedIDs.isEmpty {
                    self.updateResult(removing: removedIDs, adding: [])
                }

                let allFailures = purgeOutcome.failures + moveOutcome.failures + orphanFailures
                self.failureReasons = Dictionary(allFailures.map { ($0.id, $0.reason) }, uniquingKeysWith: { first, _ in first })
                self.undoable = moveOutcome.moved

                if !purgeOutcome.purgedEntries.isEmpty || !purgeOutcome.failures.isEmpty {
                    CleanupLog.record("直接清理缓存", moved: purgeOutcome.purgedEntries,
                                      failedCount: purgeOutcome.failures.count, failures: purgeOutcome.failures,
                                      volumes: purgeOutcome.volumes, disposition: .purged)
                }
                if !moveOutcome.moved.isEmpty || !moveOutcome.failures.isEmpty {
                    CleanupLog.record("一键清理", moved: moveOutcome.moved.map { ($0.item.url, $0.item.cleanupBytes) },
                                      failedCount: moveOutcome.failures.count, failures: moveOutcome.failures,
                                      volumes: moveOutcome.volumes)
                }
                if !orphanMovedEntries.isEmpty || !orphanFailures.isEmpty {
                    CleanupLog.record("清理残留", moved: orphanMovedEntries, failedCount: orphanFailures.count, failures: orphanFailures)
                }

                self.refreshDisplayVolumes()
                let totalPurged = purgeOutcome.purgedCount
                let totalMoved = moveOutcome.moved.count + orphanMovedEntries.count
                let totalGone = purgeOutcome.gone.count + moveOutcome.gone.count
                if totalPurged == 0 && totalMoved == 0 && allFailures.isEmpty {
                    self.message = "所选项目已不存在，已从列表中移除"
                } else {
                    let sumMovedBytes = moveOutcome.bytes.addingReportingOverflow(orphanMovedBytes)
                    self.cleanupReport = CleanupReport(
                        movedCount: totalMoved,
                        movedBytes: sumMovedBytes.overflow ? Int64.max : sumMovedBytes.partialValue,
                        failures: allFailures,
                        openApps: Array(Set(purgeOutcome.openApps + moveOutcome.openApps)),
                        recreatedCount: purgeOutcome.recreatedCount + moveOutcome.recreatedCount,
                        alreadyGoneCount: totalGone,
                        purgedCount: totalPurged,
                        purgedBytes: purgeOutcome.purgedBytes
                    )
                }
            }
        }
    }

    func selectedItems(in category: ItemFilter?) -> [ScanItem] {
        guard let category else { return selectedCleanupItems }
        return selectedCleanupItems.filter { category.contains($0) }
    }

    func reviewCleanup(scope: ItemFilter? = nil, only: Set<URL>? = nil) {
        cleanupScope = scope
        cleanupOnly = only
        refreshBrowserAvailability()
        guard !itemsToClean.isEmpty, !isCleaning else { return }
        hoveredID = nil
        confirmDecided = false
        // Strictly whitelisted regenerable caches go directly in one click so APFS free space increases immediately.
        // Decided user items (large files, backups, dependencies) and project-name build caches stay in Trash confirmation.
        if itemsToClean.allSatisfy({ policy.isDirectPurgeEligible($0) }) {
            purgeSelectedCaches()
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
        destination = .overview
        tool = nil
        showingSpaceMap = false
        showingHistory = false
        showingSmartCleanDetail = false
        showingOverview = true
        showingScanDetail = false
        showingGrowth = false
        selectedID = nil
    }

    enum SpaceTab: String, CaseIterable, Identifiable {
        case map = "空间分布"
        case explore = "逐层透视"
        case clutter = "大文件与查重"
        case system = "系统释放"
        var id: Self { self }
    }

    @Published var spaceTab: SpaceTab = .map

    lazy var spaceLens = SpaceLensStore(home: policy.home, policy: policy)
    lazy var reconciler = ReconcilerStore(policy: policy) { [weak self] in
        self?.refreshDisplayVolumes()
    }
    @Published var showReconciler = false

    func openReconciler() {
        openSpace(tab: .system)
    }

    func openSpace(tab: SpaceTab, exploreDirectory: URL? = nil) {
        guard !isScanning, !isCleaning else { return }
        spaceTab = tab
        showSpaceMap()
        switch tab {
        case .map: break
        case .explore:
            spaceLens.navigate(to: exploreDirectory ?? policy.home)
        case .clutter: break
        case .system:
            if reconciler.report == nil && !reconciler.isScanning { reconciler.refreshUserBlackHoles() }
            if storageTools.snapshots == nil { storageTools.refreshSnapshots() }
            if storageTools.cliProbes.isEmpty { storageTools.refreshCLIAdapters() }
        }
    }

    func setSentinelEnabled(_ enabled: Bool) {
        sentinelEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: TrashSentinel.enabledKey)
        if enabled {
            startTrashSentinel()
        } else {
            trashSentinel?.stop()
            trashSentinel = nil
        }
    }

    private func startTrashSentinel() {
        guard sentinelEnabled, !AppHome.isDemo, trashSentinel == nil else { return }
        let sentinel = TrashSentinel { [weak self] alert in
            Task { @MainActor in
                self?.sentinelAlert = alert
            }
        }
        sentinel.start()
        trashSentinel = sentinel
    }

    func openSentinelOrphans() {
        sentinelAlert = nil
        appsSystemTab = .leftovers
        uninstaller.selectOrphans()
        openTool(.uninstall)
    }

    /// 「空间分布」页：从总览的圆环进入。各块大小量一次存 `space-map.json`，超过一天或用户点「重新测量」才再量
    lazy var storageTools = StorageToolsStore(policy: policy, ignoredPaths: { [weak self] in
        self?.ignoredPaths ?? []
    }, onMoved: { [weak self] url in
        self?.forgetMovedDuplicate(url)
    })

    private func forgetMovedDuplicate(_ url: URL) {
        if let item = result?.items.first(where: { $0.url.path == url.path }) {
            selectedCleanupIDs.remove(item.id)
            updateResult(removing: [item.id], adding: [])
        } else {
            refreshLargeFileSummary()
        }
    }

    @Published var showingSpaceMap = false
    @Published private(set) var spaceMap: SpaceMap? = SpaceMap.load()
    @Published private(set) var measuringSpaceMap: String?

    func showSpaceMap() {
        guard !isScanning, !isCleaning else { return }
        destination = .spaceLens
        tool = nil
        showingHistory = false
        showingOverview = false
        showingScanDetail = false
        showingGrowth = false
        showingSpaceMap = true
        selectedID = nil
        if spaceMap.map({ $0.trashOccupancy == nil || Date().timeIntervalSince($0.measuredAt) > 86_400 }) ?? true { measureSpaceMap() }
    }

    func measureSpaceMap() {
        guard measuringSpaceMap == nil else { return }
        measuringSpaceMap = "正在测量"
        let mapper = SpaceMapper(home: policy.home, devRoot: dev.root,
                                 chatBytes: (result?.chatApps ?? []).compactMap(\.bytes).reduce(0, +))
        Task.detached(priority: .utility) { [weak self] in
            let map = mapper.measure { step in Task { @MainActor in self?.measuringSpaceMap = "正在测量：\(step)" } }
            map.save()
            await MainActor.run {
                self?.spaceMap = map
                self?.measuringSpaceMap = nil
            }
        }
    }

    /// The space-change report, opened from the overview's card.
    @Published var showingGrowth = false

    /// Free-space samples for the report's chart, read when the report opens.
    @Published private(set) var spaceHistory: [SpaceHistory.Sample] = []

    func showGrowth() {
        spaceHistory = SpaceHistory.load()
        tool = nil
        showingSpaceMap = false
        showingHistory = false
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
        showingSpaceMap = false
        showingHistory = false
        showingOverview = false
        showingGrowth = false
        showingScanDetail = true
        selectedID = nil
    }

    func selectCategory(_ category: ItemFilter) {
        tool = nil
        showingSpaceMap = false
        showingHistory = false
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
        scanFeedTask?.cancel()
        scanFeedTask = nil
        chatUsageTask?.cancel()
        chatUsageTask = nil
        isMeasuringChatUsage = false
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
            showingSpaceMap = false
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
        unifiedOverviewMode = false
        scan()
    }

    func scanKnownCaches() {
        setRoot(policy.home)
        quickMode = true
        unifiedOverviewMode = false
        scan()
    }

    /// Full-Home Deep Scan: collects caches, dev artifacts across ~/Coding & user directories,
    /// ≥100 MB large files, installers, creator caches, leftovers, diagnostics, and snapshots in one flow.
    func scanOverview() {
        setRoot(policy.home)
        quickMode = false
        unifiedOverviewMode = true
        scan()
    }

    /// The low-space notification was clicked: bring the window up and start a quick scan,
    /// unless a scan or cleanup is already running.
    func quickScanFromAlert() {
        NSApp.activate()
        guard !isScanning, !isCleaning else { return }
        showAbout = false
        tool = nil
        showingSpaceMap = false
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

    private var scopeKey: String { Self.scopeKey(root: root, quick: quickMode, unified: unifiedOverviewMode) }

    private static func scopeKey(root: URL, quick: Bool, unified: Bool = false) -> String {
        if unified { return "overview" }
        return quick ? "quick" : root.path
    }

    private var scanDates: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: Keys.scanDates) as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Keys.scanDates) }
    }

    private var scanSizes: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: Keys.scanSizes) as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Keys.scanSizes) }
    }

    /// How long the last scan of a scope took, in seconds: the progress bar's only estimate.
    private var scanDurations: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: Keys.scanDurations) as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Keys.scanDurations) }
    }

    static func initialModules(unified: Bool, quick: Bool) -> [ScanModuleProgress] {
        if unified {
            return [
                ScanModuleProgress(id: "cache", title: "系统、应用与浏览器缓存", symbol: "sparkles", status: .running("准备开始…")),
                ScanModuleProgress(id: "chatCreative", title: "社交聊天与影视创作软件", symbol: "bubble.left.and.bubble.right.fill", status: .waiting),
                ScanModuleProgress(id: "devAI", title: "开发工程、AI 编程与包管理器", symbol: "hammer.fill", status: .waiting),
                ScanModuleProgress(id: "clutter", title: "全盘大文件、安装包与重复项", symbol: "doc.on.doc.fill", status: .waiting),
                ScanModuleProgress(id: "orphans", title: "卸载软件残留与开机自启", symbol: "archivebox.fill", status: .waiting),
                ScanModuleProgress(id: "system", title: "废纸篓、本地快照与系统日志", symbol: "internaldrive.fill", status: .waiting)
            ]
        }
        return [
            ScanModuleProgress(id: "cache", title: quick ? "系统、应用与浏览器缓存" : "目标目录与可清缓存", symbol: "sparkles", status: .running("正在扫描…")),
            ScanModuleProgress(id: "chatCreative", title: "AI 编程与创作渲染缓存", symbol: "wand.and.stars", status: .waiting),
            ScanModuleProgress(id: "system", title: "诊断日志与废纸篓检查", symbol: "doc.text.fill", status: .waiting)
        ]
    }

    private func setModuleStatus(_ id: String, status: ScanModuleProgress.Status) {
        guard let idx = scanModules.firstIndex(where: { $0.id == id }) else { return }
        scanModules[idx].status = status
    }

    func scan(clearMessage: Bool = true) {
        guard !isScanning, !isCleaning else { return }
        tool = nil
        showingSpaceMap = false
        showingHistory = false
        isScanning = true
        liveFound = []
        liveCacheBytes = 0
        liveCreativeBytes = 0
        liveLargeBytes = 0
        liveNotableCount = 0
        liveRecentItems = []
        scanModules = Self.initialModules(unified: unifiedOverviewMode, quick: quickMode)
        progress = ScanProgress(scannedCount: 0, currentFolder: root.path)
        let startedAt = Date()
        scanStartedAt = startedAt
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
        let isUnified = unifiedOverviewMode
        let devRoot = dev.root
        let ignoredSnap = ignoredPaths
        let realHomePath = CanonicalPath.url(FileManager.default.homeDirectoryForCurrentUser).path
        chatUsageTask?.cancel()
        chatUsageTask = nil
        isMeasuringChatUsage = false
        let chatBefore = lastChatUsage
        let feed = ScanEventBuffer()
        scanFeedTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
                guard let self, self.scanID == thisScan, self.isScanning else { return }
                let snap = feed.drainSnapshot()
                guard snap.hasUpdates else { continue }
                if let progress = snap.progress { self.progress = progress }
                self.liveCacheBytes = snap.cacheBytes
                self.liveCreativeBytes = snap.creativeBytes
                self.liveLargeBytes = snap.largeBytes
                self.liveNotableCount = snap.notableCount
                self.liveRecentItems = snap.recentItems
            }
        }
        @Sendable func markModule(_ id: String, _ status: ScanModuleProgress.Status) {
            Task { @MainActor [weak self] in
                guard let self, self.scanID == thisScan, self.isScanning else { return }
                self.setModuleStatus(id, status: status)
            }
        }
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in

            var scanner = DiskScanner(policy: scanPolicy)
            scanner.onFound = { feed.record($0) }

            struct UnifiedBundle {
                var result: ScanResult
                var devResult: DevScanResult?
                var cliProbes: [CLICleanerAdapters.ProbeResult] = []
                var duplicates: DuplicateFiles.Result?
                var cloudItems: [CloudDownloads.LocalItem]?
                var installedApps: [InstalledApp]?
                var orphans: [OrphanGroup] = []
                var launchAgents: [UserLaunchAgent] = []
                var reconcilerReport: StorageReconciler.Report?
                var snapshots: Set<String>?
            }

            let output: Result<UnifiedBundle, Error> = Result {
                if isUnified {
                    // 1. Caches & Browsers
                    markModule("cache", .running("正在扫描应用与浏览器缓存…"))
                    let quick = try scanner.scanKnownCaches { progress in
                        feed.record(ScanProgress(scannedCount: progress.scannedCount, currentFolder: progress.currentFolder, stage: "阶段 1/6 · 系统与浏览器缓存"))
                    }
                    let quickCacheBytes = Self.cleanupSum(quick.items.filter { $0.kind == .cache && $0.canTrash })
                    markModule("cache", .done(quickCacheBytes > 0 ? ByteFormat.string(quickCacheBytes) : "无需清理", accent: quickCacheBytes > 0))

                    // 2. Social & Creative Apps
                    markModule("chatCreative", .running("正在统计微信、飞书与创作软件…"))
                    let chats = AppHome.isDemo ? [] : scanner.chatAppUsage()
                    let chatBytes = chats.compactMap(\.bytes).reduce(0, +)
                    let creativeCacheBytes = Self.cleanupSum(quick.items.filter { CreativeApp.of($0) != nil && $0.canTrash })
                    let chatLabel = chatBytes + creativeCacheBytes > 0 ? ByteFormat.string(chatBytes + creativeCacheBytes) : "已检查"
                    markModule("chatCreative", .done(chatLabel, accent: creativeCacheBytes > 0))

                    // 3. Dev Projects, AI Coding & Package Managers
                    markModule("devAI", .running("正在扫描代码工程与开发包管理器…"))
                    var scannedDev: DevScanResult?
                    if !AppHome.isDemo, FileManager.default.fileExists(atPath: devRoot.path) {
                        scannedDev = try? DevScanner(policy: scanPolicy).scan(devRoot, onProgress: { count, folder in
                            feed.record(ScanProgress(scannedCount: quick.scannedCount + count, currentFolder: folder, stage: "阶段 3/6 · 代码工程与开发工具"))
                        }, onFound: { _, item in
                            feed.record(item)
                        })
                    }
                    let isRealHome = (scanPolicy.home.path == realHomePath) && !AppHome.isDemo
                    let cliProbes = isRealHome ? CLICleanerAdapters(home: scanPolicy.home).probeAll().filter(\.available) : []
                    let devArtifactBytes = scannedDev?.projects.reduce(Int64(0)) { $0 + $1.bytes } ?? 0
                    let cliBytes = cliProbes.compactMap(\.estimatedBytes).reduce(Int64(0), +)
                    let devLabel = devArtifactBytes + cliBytes > 0 ? ByteFormat.string(devArtifactBytes + cliBytes) : (cliProbes.isEmpty ? "已检查" : "\(cliProbes.count) 项工具可清理")
                    markModule("devAI", .done(devLabel, accent: devArtifactBytes + cliBytes > 0))

                    // 4. Full-Home Large Files, Installers, Duplicates & iCloud Local Copies
                    markModule("clutter", .running("正在全盘遍历大文件与重复文件…"))
                    var full = try scanner.scanFullHomeAdditions(after: quick) { progress in
                        feed.record(ScanProgress(scannedCount: progress.scannedCount, currentFolder: progress.currentFolder, stage: "阶段 4/6 · 全盘大文件与安装包"))
                    }
                    let dupFolders = isRealHome ? DuplicateFiles.defaultUserFolders(home: scanPolicy.home) : []
                    let duplicates = dupFolders.isEmpty ? nil : (try? DuplicateFiles(policy: scanPolicy).scan(folders: dupFolders, minimumBytes: 10_000_000, ignoring: ignoredSnap))
                    let cloudItems = isRealHome ? CloudDownloads.scanLocalCopies(home: scanPolicy.home, minBytes: 20_000_000) : nil
                    let largeBytes = full.items.filter { $0.kind == .largeFile || $0.kind == .project }.reduce(Int64(0)) { $0 + $1.bytes }
                    let dupCount = duplicates?.groups.count ?? 0
                    let clutterLabel = largeBytes > 0
                        ? (dupCount > 0 ? "\(ByteFormat.string(largeBytes))，\(dupCount) 组重复" : ByteFormat.string(largeBytes))
                        : (dupCount > 0 ? "\(dupCount) 组重复" : "无超大文件")
                    markModule("clutter", .done(clutterLabel, accent: largeBytes > 0 || dupCount > 0))

                    // 5. Uninstalled App Leftovers & LaunchAgents
                    markModule("orphans", .running("正在比对软件卸载残留与自启服务…"))
                    let uninstaller = AppUninstaller(policy: scanPolicy)
                    let installed = isRealHome ? uninstaller.installedApps() : nil
                    let orphans = installed.map { uninstaller.orphans(installed: $0) } ?? []
                    let agents = isRealHome ? UninstallStore.scanUserLaunchAgents(home: scanPolicy.home) : []
                    let safeOrphanSum = orphans.filter { !SensitiveApps.matches($0.id) }.reduce(Int64(0)) { $0 + $1.bytes }
                    markModule("orphans", .done(safeOrphanSum > 0 ? "\(orphans.count) 项，\(ByteFormat.string(safeOrphanSum))" : "无残留", accent: safeOrphanSum > 0))

                    // 6. Trash, Time Machine Snapshots & System Logs
                    markModule("system", .running("正在检查废纸篓、本地快照与系统日志…"))
                    let recReport = StorageReconciler(policy: scanPolicy).scanUserBlackHoles()
                    let snaps = isRealHome ? (try? TimeMachineSnapshots().list()) : nil
                    let sysBytes = recReport.totalBytes
                    let snapCount = snaps?.count ?? 0
                    let sysLabel = sysBytes > 0
                        ? (snapCount > 0 ? "\(ByteFormat.string(sysBytes))，\(snapCount) 份快照" : ByteFormat.string(sysBytes))
                        : (snapCount > 0 ? "\(snapCount) 份快照" : "无需清理")
                    markModule("system", .done(sysLabel, accent: sysBytes > 0 || snapCount > 0))

                    // Merge DevScanner `.cache` items into unified ScanResult without overlapping existing items
                    var mergedItems = full.items
                    var mergedPaths = Set(mergedItems.map(\.url.path))
                    if let scannedDev {
                        for artifact in scannedDev.projects.flatMap(\.artifacts) where artifact.kind == .cache && artifact.canTrash {
                            let p = artifact.url.path
                            let overlaps = mergedPaths.contains { $0 == p || p.hasPrefix($0 + "/") || $0.hasPrefix(p + "/") }
                            if !overlaps && mergedPaths.insert(p).inserted {
                                mergedItems.append(artifact)
                            }
                        }
                    }
                    mergedItems.sort { $0.bytes > $1.bytes }
                    full = ScanResult(
                        root: full.root,
                        isQuickScan: false,
                        items: mergedItems,
                        totalBytes: full.totalBytes,
                        volumeTotalBytes: full.volumeTotalBytes,
                        volumeFreeBytes: full.volumeFreeBytes,
                        skippedCount: full.skippedCount,
                        scannedCount: full.scannedCount,
                        scannedAt: Date(),
                        chatApps: chats
                    )
                    return UnifiedBundle(
                        result: full,
                        devResult: scannedDev,
                        cliProbes: cliProbes,
                        duplicates: duplicates,
                        cloudItems: cloudItems,
                        installedApps: installed,
                        orphans: orphans,
                        launchAgents: agents,
                        reconcilerReport: recReport,
                        snapshots: snaps
                    )
                }

                // Quick scan or custom folder scan
                let basic = try isQuick ? scanner.scanKnownCaches(onProgress: { feed.record($0) })
                    : scanner.scan(scanRoot, onProgress: { feed.record($0) })
                let recReport = isQuick ? StorageReconciler(policy: scanPolicy).scanUserBlackHoles(includeSystemAerial: false, includeSnapshots: false, includeTrash: true) : nil
                return UnifiedBundle(result: basic, reconcilerReport: recReport)
            }

            await MainActor.run {
                guard let self, self.scanID == thisScan else { return }
                self.scanTask = nil
                self.scanFeedTask?.cancel()
                self.scanFeedTask = nil
                self.isScanning = false
                self.scanStartedAt = nil
                let elapsed = Date().timeIntervalSince(startedAt)
                if elapsed > 1 {
                    var durations = self.scanDurations
                    durations[Self.scopeKey(root: scanRoot, quick: isQuick, unified: isUnified)] = elapsed
                    self.scanDurations = durations
                }
                switch output {
                case .success(let bundle):
                    var value = bundle.result
                    if !isUnified {
                        value.chatApps = chatBefore
                    }
                    if let devResult = bundle.devResult {
                        self.dev.applyScanResult(devResult)
                    }
                    if isUnified {
                        self.storageTools.applyUnifiedFindings(
                            cli: bundle.cliProbes,
                            duplicates: bundle.duplicates,
                            cloud: bundle.cloudItems,
                            snapshots: bundle.snapshots
                        )
                        self.uninstaller.applyUnifiedOrphans(
                            apps: bundle.installedApps,
                            orphans: bundle.orphans,
                            agents: bundle.launchAgents
                        )
                    }
                    if let recReport = bundle.reconcilerReport {
                        self.reconciler.applyScannedReport(recReport)
                    }
                    if isQuick || isUnified { self.rotateGrowthBaseline() }
                    self.result = value
                    self.pickAllSafe()
                    let recreated = CleanupLog.recreatedCacheCount(in: value.items)
                    if recreated > 0 {
                        self.message = "\(recreated) 项缓存在上次清理后重新生成。"
                    }
                    self.selectedID = nil
                    self.scanSizes[self.scopeKey] = value.scannedCount
                    self.saveResult(value)
                    if !isUnified, (isQuick || value.root.path == scanPolicy.home.path) {
                        self.measureChatUsage(policy: scanPolicy, scanID: thisScan)
                        self.reconciler.refreshUserBlackHoles()
                        self.storageTools.refreshSnapshots()
                        Task { [weak self] in
                            try? await Task.sleep(for: .milliseconds(900))
                            guard let self, self.scanID == thisScan else { return }
                            self.storageTools.refreshCLIAdapters()
                            if isQuick { _ = self.dev.discoverIfNeeded() }
                            try? await Task.sleep(for: .milliseconds(1200))
                            guard self.scanID == thisScan else { return }
                            self.uninstaller.loadIfNeeded()
                        }
                    }
                case .failure(let error):
                    self.message = error is CancellationError ? "扫描已取消。" : error.localizedDescription
                }
            }
        }
    }

    private func measureChatUsage(policy: SafetyPolicy, scanID: UUID) {
        isMeasuringChatUsage = true
        chatUsageTask = Task.detached(priority: .utility) { [weak self] in
            let chats = DiskScanner(policy: policy).chatAppUsage()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.scanID == scanID, var result = self.result else { return }
                result.chatApps = chats
                self.result = result
                self.saveResult(result)
                self.isMeasuringChatUsage = false
                self.chatUsageTask = nil
            }
        }
    }

    func cancelScan() {
        guard isScanning else { return }
        scanTask?.cancel()
        scanTask = nil
        scanFeedTask?.cancel()
        scanFeedTask = nil
        scanID = UUID()
        isScanning = false
        scanStartedAt = nil
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
        let key = scopeKey
        let targetURL = resultURL(for: key)
        scanDates[key] = value.scannedAt.timeIntervalSince1970
        UserDefaults.standard.set(key, forKey: Keys.lastScope)
        refreshLargeFileSummary()
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(value) {
                try? data.write(to: targetURL, options: .atomic)
            }
        }
    }

    /// Large files from the last full scan of the home folder, for the overview while another scan is shown.
    struct LargeFileSummary {
        let count: Int
        let bytes: Int64
        let scannedAt: Date
    }

    @Published private(set) var largeFileSummary: LargeFileSummary?

    /// Large files and installers available for 「文件整理」, falling back to the saved home scan when current
    /// quick result didn't walk personal folders yet, keeping Overview summary and ClutterPage 100% consistent.
    var largeAndInstallerItems: [ScanItem] {
        let live = items(in: .large)
        if !live.isEmpty { return live }
        return cachedFullLargeItems
    }

    @Published private(set) var cachedFullLargeItems: [ScanItem] = []

    func refreshLargeFileSummary() {
        let currentLarge = shownItems.filter { ItemFilter.large.contains($0) && FileManager.default.fileExists(atPath: $0.url.path) }
        if !currentLarge.isEmpty {
            cachedFullLargeItems = currentLarge
            largeFileSummary = LargeFileSummary(count: currentLarge.count, bytes: Self.sum(currentLarge),
                                                scannedAt: result?.scannedAt ?? Date())
            return
        }
        let value: ScanResult?
        if !quickMode, root.path == policy.home.path, let result {
            value = result
        } else if let overviewData = try? Data(contentsOf: resultURL(for: "overview")),
                  let overviewResult = try? JSONDecoder().decode(ScanResult.self, from: overviewData) {
            value = overviewResult
        } else {
            value = (try? Data(contentsOf: resultURL(for: Self.scopeKey(root: policy.home, quick: false))))
                .flatMap { try? JSONDecoder().decode(ScanResult.self, from: $0) }
        }
        guard let value else {
            cachedFullLargeItems = []
            largeFileSummary = nil
            return
        }
        let ignored = Set(ignoredPaths.map { CanonicalPath.url(URL(fileURLWithPath: $0)).path })
        let large = value.items.filter { item in
            ItemFilter.large.contains(item)
                && FileManager.default.fileExists(atPath: item.url.path)
                && !ignored.contains { item.url.path == $0 || item.url.path.hasPrefix($0 + "/") }
        }
        cachedFullLargeItems = large
        decisionNotes = Self.decisionNotes(for: result, cachedLarge: large, policy: policy)
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
        let versions = ToolVersions(home: policy.home)
        let currentVersions = Set(ToolVersions.Tool.supported.flatMap { versions.candidates(for: $0).map(\.path) })
        let checkedItems = present.map { item in
            if item.kind == .cache, currentVersions.contains(item.url.path), !policy.isProtected(item.url),
               TrashService.currentIdentity(item.url) == item.identity { return item }
            guard item.canTrash else { return item }
            if CanonicalPath.isDirect(item.url), !policy.hasProtectedDescendant(item.url),
               policy.cacheDescription(for: item.url, isDirectory: true) != nil ||
                    DiagnosticJunk.eligible(item.url, home: policy.home) { return item }
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
        if let saved = UserDefaults.standard.string(forKey: Keys.lastFilter).flatMap(ItemFilter.fromStored), ItemFilter.visible.contains(saved) {
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
        if key == "overview" {
            unifiedOverviewMode = true
            quickMode = false
            root = policy.home
        } else if key == "quick" {
            unifiedOverviewMode = false
            quickMode = true
            root = policy.home
        } else {
            unifiedOverviewMode = false
            quickMode = false
            root = URL(fileURLWithPath: key)
        }
        showSavedResult()
    }

    // MARK: Cleanup

    /// Directly purges pure regenerable caches (Grade A/B) to free physical APFS disk space immediately.
    func purgeSelectedCaches() {
        let items = itemsToClean.filter { $0.kind == .cache && $0.canTrash && !isDecidable($0) }
        guard !items.isEmpty, !isCleaning else { return }
        showTrashConfirmation = false
        isCleaning = true
        cleanedCount = 0
        cleaningTotalCount = items.count
        cleaningCurrentItem = items.first?.name ?? ""
        message = nil
        cleanupReport = nil
        let scanPolicy = SafetyPolicy(home: policy.home,
                                      extraProtected: policy.extraProtectedRoots + ignoredPaths.map { URL(fileURLWithPath: $0) })
        failureReasons = [:]
        undoable = []
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = await TrashService.purgeAll(
                items,
                policy: scanPolicy,
                onCurrentItem: { name in
                    await MainActor.run { self?.cleaningCurrentItem = name }
                },
                progress: { count in
                    await MainActor.run { self?.cleanedCount = count }
                }
            )
            await MainActor.run {
                guard let self else { return }
                self.isCleaning = false
                self.cleaningCurrentItem = ""
                let removedIDs = Set(outcome.purgedIDs + outcome.gone)
                self.selectedCleanupIDs.subtract(removedIDs)
                self.updateResult(removing: removedIDs, adding: [])
                self.failureReasons = Dictionary(outcome.failures.map { ($0.id, $0.reason) }, uniquingKeysWith: { first, _ in first })
                CleanupLog.record("直接清理缓存", moved: outcome.purgedEntries,
                                  failedCount: outcome.failures.count, failures: outcome.failures, volumes: outcome.volumes,
                                  disposition: .purged)
                self.refreshDisplayVolumes()
                if outcome.purgedCount == 0 && outcome.failures.isEmpty {
                    self.message = "所选缓存已不存在，已从列表中移除"
                } else {
                    self.cleanupReport = outcome.report
                }
            }
        }
    }

    func trashSelectedItems() {
        let items = itemsToClean
        guard !items.isEmpty, !isCleaning else { return }
        showTrashConfirmation = false
        isCleaning = true
        cleanedCount = 0
        cleaningTotalCount = items.count
        cleaningCurrentItem = items.first?.name ?? ""
        message = nil
        cleanupReport = nil
        let scanPolicy = SafetyPolicy(home: policy.home,
                                      extraProtected: policy.extraProtectedRoots + ignoredPaths.map { URL(fileURLWithPath: $0) })
        failureReasons = [:]
        undoable = []
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = await TrashService.moveAll(
                items,
                policy: scanPolicy,
                onCurrentItem: { name in
                    await MainActor.run { self?.cleaningCurrentItem = name }
                },
                progress: { count in
                    await MainActor.run { self?.cleanedCount = count }
                }
            )
            await MainActor.run {
                guard let self else { return }
                self.isCleaning = false
                self.cleaningCurrentItem = ""
                let removedIDs = Set(outcome.moved.map(\.item.id) + outcome.gone)
                self.selectedCleanupIDs.subtract(removedIDs)
                self.cachedFullLargeItems.removeAll { removedIDs.contains($0.id) }
                // No rescan: drop what moved (or was already gone) and keep the user where they were.
                // Failed items stay, with the reason.
                self.updateResult(removing: removedIDs, adding: [])
                self.failureReasons = Dictionary(outcome.failures.map { ($0.id, $0.reason) }, uniquingKeysWith: { first, _ in first })
                self.undoable = outcome.moved
                CleanupLog.record("清理", moved: outcome.moved.map { ($0.item.url, $0.item.cleanupBytes) },
                                  failedCount: outcome.failures.count, failures: outcome.failures, volumes: outcome.volumes)
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

    /// Permanently removes only the items that Qingo moved in the last cleanup, without touching other Trash items.
    func purgeLastTrashed() {
        let entries = undoable
        guard !entries.isEmpty, !isCleaning, !isRestoring, !isPurging else { return }
        isPurging = true
        resultDismissTimer.cancel()
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = TrashService.purgeTrashed(entries)
            await MainActor.run {
                guard let self else { return }
                self.isPurging = false
                let removed = Set(outcome.purgedIDs)
                self.undoable.removeAll { removed.contains($0.item.id) }
                if self.undoable.isEmpty { self.cleanupReport = nil }
                self.refreshDisplayVolumes()
                if outcome.purgedCount > 0 {
                    var tail = ""
                    if outcome.failedCount > 0 { tail += "，\(outcome.failedCount) 项未能删除" }
                    if outcome.skippedOutsideTrash > 0 { tail += "，\(outcome.skippedOutsideTrash) 项在外置卷废纸篓中已保留" }
                    self.message = "已永久释放 \(outcome.purgedCount) 项（约 \(ByteFormat.string(outcome.purgedBytes))）\(tail)"
                } else {
                    self.message = outcome.failedCount > 0 || outcome.skippedOutsideTrash > 0
                        ? "部分项目未能从废纸篓删除，可在访达中清空。"
                        : "本次清理项已不在废纸篓中。"
                }
            }
        }
    }

    /// Gracefully quits browsers currently blocking cache cleanup, then cleans those newly unblocked caches.
    func quitBlockedBrowsersAndClean() {
        guard !deferredBrowsers.isEmpty, !isCleaning, !isQuittingBrowsers else { return }
        let blockedIDs = Set(deferredBrowsers.keys)
        let bundleIDs = Array(Set(
            shownItems.compactMap { item -> String? in
                guard blockedIDs.contains(item.id) else { return nil }
                return BrowserCaches.owner(of: item.url, home: policy.home)?.bundleID
            }
        ))
        guard !bundleIDs.isEmpty else { return }
        isQuittingBrowsers = true
        Task { [weak self] in
            let result = await AppBlockerResolver.quitApps(bundleIDs: bundleIDs)
            guard let self else { return }
            self.isQuittingBrowsers = false
            self.refreshBrowserAvailability()
            let nowReady = blockedIDs.filter { self.deferredBrowsers[$0] == nil }
            if !nowReady.isEmpty {
                self.reviewCleanup(only: nowReady)
            } else if !result.allExited {
                self.message = "部分浏览器尚未退出，请确认保存后退出再试。"
            }
        }
    }

    func openTrash() {
        let homeTrash = policy.home.appending(path: ".Trash")
        let confirmed = undoable.map(\.trashed).filter { FileManager.default.fileExists(atPath: $0.path) }
        if confirmed.isEmpty {
            NSWorkspace.shared.open(homeTrash)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(confirmed)
        }
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
    ///
    /// `rawValue` is the id, `title` is what people read: renaming a category must never invalidate a saved
    /// `lastFilter` or the `--category` argument.
    static let visible: [ItemFilter] = [.caches, .creative, .chat, .large]

    case caches, creative, chat, review, large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .caches: "应用缓存"
        case .creative: "创作与 AI 工具"
        case .chat: "通讯与办公"
        case .review: "需要判断"
        case .large: "大文件与工程"
        }
    }

    /// Older builds saved the label itself; accept those labels as well as the ids.
    static func fromStored(_ raw: String) -> ItemFilter? {
        if let filter = ItemFilter(rawValue: raw) { return filter }
        switch raw {
        case "可清理缓存": return .caches
        case "剪辑与设计软件", "创作与 AI 工具": return .creative
        case "微信与企业微信", "常用通讯": return .chat
        case "需要判断": return .review
        case "大文件", "大文件与工程": return .large
        default: return nil
        }
    }

    /// iPhone 备份是 `.review`（文件夹、要确认），但给人看时和大文件放在一起
    static func isIOSBackup(_ item: ScanItem) -> Bool {
        item.kind == .review && item.url.deletingLastPathComponent().path.hasSuffix("/Library/Application Support/MobileSync/Backup")
    }

    func contains(_ item: ScanItem) -> Bool {
        let creative = CreativeApp.of(item) != nil
        switch self {
        case .caches: return item.kind == .cache && !creative
        case .creative: return creative
        case .chat: return false
        case .review: return item.kind == .review && !creative
        case .large: return (item.kind == .project || item.kind == .largeFile || Self.isIOSBackup(item)) && !creative
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
    private static let keys = ["appearance", "savedFolders", "scanSizes", "scanDurations", "lastFilter", "lastScope", "scanDates"]

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
