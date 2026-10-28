import AppKit
import Darwin
import Foundation

/// One code project and the dependencies / build output inside it. The code itself is never listed.
struct DevProject: Identifiable, Codable, Sendable {
    let id: URL
    /// Newest change to a file outside build output, dependencies and .git: "how long untouched".
    let modified: Date?
    var artifacts: [ScanItem]

    var name: String { id.lastPathComponent }
    var bytes: Int64 { ScanStore.sum(artifacts) }
}

struct DevScanResult: Codable, Sendable {
    let root: URL
    var projects: [DevProject]
    let scannedAt: Date
}

/// Finds projects under a folder and the regenerable build output inside them (`SafetyPolicy.cacheDescription`).
/// Dependencies and virtual environments are not listed: people who don't code can't reinstall them.
struct DevScanner: Sendable {
    let policy: SafetyPolicy
    /// Projects whose output adds up to less than this are not worth a card.
    static let minProjectBytes: Int64 = 5_000_000
    static let markers = ["package.json", "Cargo.toml", "Package.swift", "pyproject.toml", "requirements.txt", "setup.py",
                          "go.mod", "build.gradle", "build.gradle.kts", "Podfile", "pubspec.yaml", ".git"]
    /// How deep to look for projects outside any project; deeper folders are rarely code roots.
    static let maxSearchDepth = 6

    func scan(_ input: URL, onProgress: @Sendable (Int, String) -> Void = { _, _ in },
              onFound: @Sendable (URL, ScanItem) -> Void = { _, _ in }) throws -> DevScanResult {
        let root = CanonicalPath.url(input)
        var info = stat()
        guard lstat(root.path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { throw ScanError.invalidRoot }
        var state = WalkState(device: UInt64(info.st_dev))
        try walk(root, project: nil, depth: 0, state: &state, onProgress: onProgress, onFound: onFound)
        onProgress(state.scanned, root.path)
        let projects = state.artifacts.keys.compactMap { key -> DevProject? in
            let artifacts = state.artifacts[key, default: []].sorted { $0.bytes > $1.bytes }
            let project = DevProject(id: key, modified: state.newest[key], artifacts: artifacts)
            return project.bytes >= Self.minProjectBytes ? project : nil
        }
        // Longest untouched first; unknown dates last.
        .sorted { ($0.modified ?? .distantFuture) < ($1.modified ?? .distantFuture) }
        return DevScanResult(root: root, projects: projects, scannedAt: Date())
    }

    private struct WalkState {
        let device: UInt64
        var scanned = 0
        var artifacts: [URL: [ScanItem]] = [:]
        var newest: [URL: Date] = [:]
    }

    private func walk(_ url: URL, project: URL?, depth: Int, state: inout WalkState,
                      onProgress: @Sendable (Int, String) -> Void, onFound: @Sendable (URL, ScanItem) -> Void) throws {
        try Task<Never, Never>.checkCancellation()
        state.scanned += 1
        if state.scanned.isMultiple(of: 300) { onProgress(state.scanned, url.deletingLastPathComponent().path) }
        var info = stat()
        guard lstat(url.path, &info) == 0, UInt64(info.st_dev) == state.device else { return }
        let type = info.st_mode & mode_t(S_IFMT)
        guard type != mode_t(S_IFLNK), !policy.isProtected(url) else { return }
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        if type != mode_t(S_IFDIR) {
            if let project, modified > state.newest[project, default: .distantPast] { state.newest[project] = modified }
            return
        }
        let name = url.lastPathComponent
        if [".git", "node_modules", ".venv", "venv"].contains(name) { return }
        guard let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return }

        var owner = project
        if owner == nil {
            // Outside projects: skip app data and dot-folders (~/Library, ~/.npm…), and do not wander too deep.
            if depth > 0, name.hasPrefix(".") || (name == "Library" && url.deletingLastPathComponent().path == policy.home.path) { return }
            if depth > Self.maxSearchDepth { return }
            let names = Set(children.map(\.lastPathComponent))
            if Self.markers.contains(where: names.contains) { owner = url }
        }
        if let owner, url != owner, let item = try artifact(url, identity: FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino)),
                                                        modified: modified, state: &state) {
            state.artifacts[owner, default: []].append(item)
            onFound(owner, item)
            return
        }
        for child in children {
            try walk(child, project: owner, depth: depth + 1, state: &state, onProgress: onProgress, onFound: onFound)
        }
    }

    /// A regenerable build cache, measured; nil for anything else. node_modules and virtual environments are
    /// skipped whole (not descended into either), so nothing inside them is listed.
    private func artifact(_ url: URL, identity: FileIdentity, modified: Date, state: inout WalkState) throws -> ScanItem? {
        let movable = access(url.path, W_OK) == 0 && access(url.deletingLastPathComponent().path, W_OK) == 0
        guard movable, let note = policy.cacheDescription(for: url, isDirectory: true) else { return nil }
        return ScanItem(id: url, url: url, kind: .cache, risk: policy.risk(for: url, kind: .cache), bytes: try measure(url, state: &state),
                        note: note, canTrash: true, identity: identity, modified: modified)
    }

    private func measure(_ url: URL, state: inout WalkState) throws -> Int64 {
        try Task<Never, Never>.checkCancellation()
        var info = stat()
        guard lstat(url.path, &info) == 0, UInt64(info.st_dev) == state.device else { return 0 }
        state.scanned += 1
        let type = info.st_mode & mode_t(S_IFMT)
        if type == mode_t(S_IFLNK) { return 0 }
        if type != mode_t(S_IFDIR) { return max(0, Int64(info.st_size)) }
        var total: Int64 = 0
        for child in (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] {
            let addition = total.addingReportingOverflow(try measure(child, state: &state))
            total = addition.overflow ? Int64.max : addition.partialValue
        }
        return total
    }
}

/// State of the "开发项目" page.
@MainActor
final class DevStore: ObservableObject {
    @Published var result: DevScanResult? {
        didSet { decisionNotes = Self.notes(for: result, policy: policy) }
    }
    @Published private(set) var decisionNotes: [URL: String] = [:]
    @Published var isScanning = false
    @Published var scannedCount = 0
    @Published var currentFolder = ""
    /// Build caches found so far in the running scan, newest last, for the live list.
    @Published private(set) var liveFound: [(project: URL, item: ScanItem)] = []
    @Published var selected: Set<URL> = []
    @Published var expanded: Set<String> = []
    @Published var showConfirm = false
    @Published var confirmDecided = false
    @Published var isCleaning = false
    private let resultDismissTimer = ResultDismissTimer()
    @Published var report: CleanupReport? {
        didSet {
            resultDismissTimer.cancel()
            if report != nil { resultDismissTimer.schedule { [weak self] in self?.report = nil } }
        }
    }
    @Published var failureReasons: [URL: String] = [:]
    @Published private(set) var undoable: [TrashedItem] = []
    @Published var message: String?

    let policy = SafetyPolicy()
    private var scanTask: Task<Void, Never>?
    private var scanID = UUID()

    var root: URL {
        get { UserDefaults.standard.string(forKey: "devRoot").map { URL(fileURLWithPath: $0) } ?? policy.home.appending(path: "Coding") }
        set { UserDefaults.standard.set(newValue.path, forKey: "devRoot"); objectWillChange.send() }
    }

    init() { load() }

    // MARK: Derived

    var allArtifacts: [ScanItem] { result?.projects.flatMap(\.artifacts) ?? [] }
    var selectedItems: [ScanItem] { allArtifacts.filter { selected.contains($0.id) } }
    var selectedDecided: [ScanItem] { selectedItems.filter { decisionNotes[$0.id] != nil } }
    func isDecidable(_ item: ScanItem) -> Bool { decisionNotes[item.id] != nil }

    private static func notes(for result: DevScanResult?, policy: SafetyPolicy) -> [URL: String] {
        var notes: [URL: String] = [:]
        for item in result?.projects.flatMap(\.artifacts) ?? [] {
            if let note = policy.decisionNote(for: item) { notes[item.id] = note }
        }
        return notes
    }

    // MARK: Selection

    func toggle(_ items: [ScanItem]) {
        guard !isCleaning else { return }
        let ids = Set(items.map(\.id))
        if ids.isSubset(of: selected) { selected.subtract(ids) } else { selected.formUnion(ids) }
    }

    /// Everything listed is regenerable build output, so all of it starts picked.
    func selectAll() {
        guard !isCleaning else { return }
        selected = Set(allArtifacts.map(\.id))
    }

    func clearSelection() { selected.removeAll() }

    func reviewCleanup() {
        guard !selectedItems.isEmpty, !isCleaning else { return }
        confirmDecided = false
        showConfirm = true
    }

    // MARK: Scanning

    /// How far along the scan is, judged by how many entries the last scan of this folder checked.
    var estimatedProgress: Double? {
        let expected = UserDefaults.standard.integer(forKey: Self.lastCountKey(root))
        guard expected > 0 else { return nil }
        return min(Double(scannedCount) / Double(expected), 0.99)
    }

    private static func lastCountKey(_ root: URL) -> String { "devScanSize:" + root.path }

    var canDiscoverAutomatically: Bool {
        !isScanning && !isCleaning && !showConfirm && report == nil && undoable.isEmpty
            && selected == Set(allArtifacts.map(\.id))
    }

    /// Refresh in the background only when no pending choice or cleanup can be disturbed.
    func discoverIfNeeded() -> UUID? {
        guard canDiscoverAutomatically,
              FileManager.default.fileExists(atPath: root.path) else { return nil }
        scan()
        return scanID
    }

    func cancelDiscovery(_ id: UUID) {
        if isScanning && scanID == id { cancelScan() }
    }

    func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = root
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        root = url.standardizedFileURL
        result = nil
        scan()
    }

    func scan() {
        guard !isScanning, !isCleaning else { return }
        isScanning = true
        scannedCount = 0
        currentFolder = root.path
        liveFound = []
        selected.removeAll()
        report = nil
        message = nil
        failureReasons = [:]
        undoable = []
        let scanRoot = root
        let scanPolicy = policy
        let thisScan = UUID()
        scanID = thisScan
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let output = Result { try DevScanner(policy: scanPolicy).scan(scanRoot, onProgress: { count, folder in
                Task { @MainActor in
                    guard let self, self.scanID == thisScan, self.isScanning else { return }
                    self.scannedCount = count
                    self.currentFolder = folder
                }
            }, onFound: { project, item in
                Task { @MainActor in
                    guard let self, self.scanID == thisScan, self.isScanning else { return }
                    self.liveFound.append((project, item))
                }
            }) }
            await MainActor.run {
                guard let self, self.scanID == thisScan else { return }
                self.isScanning = false
                self.scanTask = nil
                switch output {
                case .success(let value):
                    UserDefaults.standard.set(self.scannedCount, forKey: Self.lastCountKey(scanRoot))
                    self.result = value
                    self.selectAll()
                    self.save()
                case .failure(let error):
                    self.message = error is CancellationError ? "扫描已取消。" : "无法读取该文件夹，请选择其他文件夹。"
                }
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        scanID = UUID()
        isScanning = false
    }

    // MARK: Cleanup

    func trashSelected() {
        let items = selectedItems
        guard !items.isEmpty, !isCleaning else { return }
        showConfirm = false
        isCleaning = true
        report = nil
        message = nil
        failureReasons = [:]
        let scanPolicy = policy
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = await TrashService.moveAll(items, policy: scanPolicy)
            await MainActor.run {
                guard let self else { return }
                self.isCleaning = false
                let moved = Set(outcome.moved.map(\.item.id))
                self.selected.subtract(moved)
                self.update(removing: moved, adding: [])
                self.failureReasons = Dictionary(outcome.failures.map { ($0.id, $0.reason) }, uniquingKeysWith: { first, _ in first })
                self.undoable = outcome.moved
                self.report = outcome.report
            }
        }
    }

    func undo() {
        let entries = undoable
        guard !entries.isEmpty, !isCleaning else { return }
        undoable = []
        Task.detached(priority: .userInitiated) { [weak self] in
            let back = TrashService.putBack(entries.map { ($0.item.url, $0.trashed) })
            let restored = zip(entries, back).filter(\.1).map(\.0.item)
            await MainActor.run {
                guard let self else { return }
                self.report = nil
                self.update(removing: [], adding: restored)
                let skipped = entries.count - restored.count
                self.message = skipped == 0 ? "已恢复 \(restored.count) 项" : "已恢复 \(restored.count) 项，\(skipped) 项因原位置已有文件或已不在废纸篓而未恢复"
            }
        }
    }

    private func update(removing ids: Set<URL>, adding items: [ScanItem]) {
        guard var value = result else { return }
        value.projects = value.projects.compactMap { project in
            var project = project
            project.artifacts.removeAll { ids.contains($0.id) }
            let back = items.filter { item in
                item.url.path.hasPrefix(project.id.path + "/") && !project.artifacts.contains { $0.id == item.id }
            }
            project.artifacts = (project.artifacts + back).sorted { $0.bytes > $1.bytes }
            return project.artifacts.isEmpty ? nil : project
        }
        result = value
        save()
    }

    // MARK: Saved result

    private var savedURL: URL {
        let directory = ProcessInfo.processInfo.environment["QINGO_RESULTS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Qingo/results")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "dev.json")
    }

    private func save() {
        guard let result, let data = try? JSONEncoder().encode(result) else { return }
        try? data.write(to: savedURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: savedURL), let value = try? JSONDecoder().decode(DevScanResult.self, from: data),
              value.root.path == root.path else { return }
        // Results saved before 1.5 may hold dependencies; only build caches are kept.
        var cachesOnly = value
        cachesOnly.projects = value.projects.compactMap { project in
            var project = project
            project.artifacts = project.artifacts.filter(\.canTrash)
            return project.artifacts.isEmpty ? nil : project
        }
        result = cachesOnly
        selectAll()
    }
}
