import AppKit
import Darwin
import Foundation

struct InstalledApp: Identifiable, Codable, Sendable {
    /// The .app, or for a suite the folder holding it (/Applications/DaVinci Resolve), which goes as a whole.
    let id: URL
    let name: String
    let bundleID: String
    let version: String?
    var appBytes: Int64?
    var traceBytes: Int64?
    var lastUsed: Date?
    /// For a suite: its main app (name, icon, last use) and the bundle ids of every app in the folder.
    var mainApp: URL?
    var memberIDs: [String]?

    var totalBytes: Int64? { appBytes.map { $0 + (traceBytes ?? 0) } }
    /// The .app to read the icon and last use from.
    var appURL: URL { mainApp ?? id }
    var bundleIDs: [String] { memberIDs ?? [bundleID] }
}

/// Where an app left something. Each kind is one row group on the uninstall page.
enum TraceKind: Int, CaseIterable, Sendable {
    case app, support, caches, preferences, background, web, logs, toolData

    var title: String {
        switch self {
        case .app: "App 本身"
        case .support: "应用支持文件"
        case .caches: "缓存"
        case .preferences: "偏好设置和窗口状态"
        case .background: "后台和登录项"
        case .web: "网页数据"
        case .logs: "日志"
        case .toolData: "工具数据"
        }
    }
}

struct AppTrace: Identifiable, Sendable {
    let id: URL
    let kind: TraceKind
    let bytes: Int64
    let identity: FileIdentity
    let isDirectory: Bool
    /// Last change of the item itself; apps touch their preferences, window state and caches whenever they run.
    var modified: Date? = nil
    var url: URL { id }
}

/// Leftovers of an app that is gone, merged by bundle id ("com.vendor.app").
struct OrphanGroup: Identifiable, Sendable {
    let id: String
    let traces: [AppTrace]
    var bytes: Int64 { traces.reduce(0) { $0 + $1.bytes } }
}

/// Finds what an app keeps in ~/Library, and what is left of apps that are gone.
/// Only fixed Library folders are searched, by exact bundle id or app name; Containers are never read.
struct AppUninstaller: Sendable {
    let policy: SafetyPolicy

    private var library: URL { policy.home.appending(path: "Library") }

    // MARK: Installed apps

    func installedApps() -> [InstalledApp] {
        let roots = [URL(fileURLWithPath: "/Applications"), policy.home.appending(path: "Applications")]
        var apps: [InstalledApp] = []
        for root in roots {
            for child in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                if child.pathExtension == "app" {
                    if let app = single(child) { apps.append(app) }
                } else if (try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map({ $0.isDirectory == true && $0.isSymbolicLink != true }) == true {
                    // A folder of apps (/Applications/DaVinci Resolve: the editor, its uninstaller, utilities) is one
                    // product: listed once, removed as a whole folder.
                    let bundles = ((try? FileManager.default.contentsOfDirectory(at: child, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "app" }
                    if bundles.count == 1, let app = single(bundles[0]) {
                        apps.append(app)
                    } else if let suite = suite(child, bundles: bundles) {
                        apps.append(suite)
                    }
                }
            }
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func single(_ url: URL) -> InstalledApp? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !id.hasPrefix("com.apple."), id != Bundle.main.bundleIdentifier,
              !Self.isBackgroundOnly(bundle) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        return InstalledApp(id: url, name: name, bundleID: id, version: bundle.infoDictionary?["CFBundleShortVersionString"] as? String)
    }

    /// A helper with no interface at all (LSBackgroundOnly), started by something else: not an app anyone
    /// opens or would think to uninstall, and removing it breaks whatever relies on it (e.g. a helper that
    /// holds a permission for an automation). Menu-bar apps (LSUIElement) have an interface and stay listed.
    static func isBackgroundOnly(_ bundle: Bundle) -> Bool {
        let value = bundle.infoDictionary?["LSBackgroundOnly"]
        return (value as? Bool) == true || (value as? String) == "1" || (value as? String)?.uppercased() == "YES"
    }

    private func suite(_ folder: URL, bundles: [URL]) -> InstalledApp? {
        let members = bundles.compactMap { url -> (URL, Bundle, String)? in
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !id.hasPrefix("com.apple.") else { return nil }
            return (url, bundle, id)
        }
        // The main app is the one named like the folder, else the largest that is not an uninstaller.
        let name = folder.lastPathComponent
        let candidates = members.filter { !$0.0.lastPathComponent.lowercased().contains("uninstall") }
        guard let main = candidates.first(where: { $0.0.deletingPathExtension().lastPathComponent == name })
                ?? candidates.max(by: { Self.size(of: $0.0) < Self.size(of: $1.0) }) ?? members.first else { return nil }
        return InstalledApp(id: folder, name: name, bundleID: main.2, version: main.1.infoDictionary?["CFBundleShortVersionString"] as? String,
                            mainApp: main.0, memberIDs: members.map(\.2))
    }

    /// Spotlight's last-used date when it has one (often it does not), or the newest change the app made
    /// to its own preferences, window state, caches or support files, whichever is later.
    static func lastUsed(_ url: URL, traces: [AppTrace]) -> Date? {
        let spotlight = NSMetadataItem(url: url)?.value(forAttribute: "kMDItemLastUsedDate") as? Date
        let touched = traces.filter { [.support, .caches, .preferences, .web].contains($0.kind) }.compactMap(\.modified).max()
        if let date = [spotlight, touched].compactMap({ $0 }).max() { return date }
        // Sandboxed apps keep everything in their container, which is not read here: fall back to when the
        // executable was last read, which launching it does.
        var info = stat()
        guard let executable = Bundle(url: url)?.executableURL, lstat(executable.path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_atimespec.tv_sec))
    }

    // MARK: Traces of one app

    /// Everything to move when uninstalling: the bundle first, then ~/Library leftovers.
    func traces(for app: InstalledApp) -> [AppTrace] {
        var found: [(URL, TraceKind)] = [(app.id, .app)]
        let ids = app.bundleIDs
        // Executable names are skipped: every Electron app's is "Electron", and its folders are shared.
        let generic: Set<String> = ["electron", "chromium", "helper", "app", "application", "launcher", "updater"]
        let names = Set(ids + [app.name, Bundle(url: app.appURL)?.infoDictionary?["CFBundleName"] as? String].compactMap { $0 }
            .filter { $0.count > 2 && !generic.contains($0.lowercased()) })
        let tool = CreativeApp.allCases.first { $0.isInstalled && ids.contains($0.bundleID) }
        for name in names {
            let support = library.appending(path: "Application Support/\(name)")
            found.append((support, tool == nil ? .support : .toolData))
            found.append((library.appending(path: "Caches/\(name)"), .caches))
            found.append((library.appending(path: "Logs/\(name)"), .logs))
        }
        for id in ids {
            found += namespaced(in: "Preferences", id: id, suffix: ".plist").map { ($0, .preferences) }
            found.append((library.appending(path: "Saved Application State/\(id).savedState"), .preferences))
            found += [library.appending(path: "HTTPStorages/\(id)"), library.appending(path: "HTTPStorages/\(id).binarycookies"),
                      library.appending(path: "WebKit/\(id)"), library.appending(path: "Cookies/\(id).binarycookies")].map { ($0, .web) }
        }
        found += launchAgents(for: app).map { ($0, .background) }
        // A recognized tool's own data roots (conversations, models…): listed, never picked by default.
        if let tool {
            found += tool.roots.map { (policy.home.appending(path: $0), .toolData) }
            for prefix in [""] + CreativeApp.vendorFolders.map({ $0 + "/" }) {
                found += tool.folders.map { (library.appending(path: "Application Support/\(prefix)\($0)"), .toolData) }
                found += tool.folders.map { (library.appending(path: "Caches/\(prefix)\($0)"), .caches) }
            }
        }
        // Grouped by kind, the app first and a tool's own data last.
        return measured(found).enumerated().sorted { ($0.element.kind.rawValue, $0.offset) < ($1.element.kind.rawValue, $1.offset) }.map(\.element)
    }

    /// Whether the app keeps a sandbox container. Only checks existence; reading it would ask the user for permission.
    func hasContainer(_ app: InstalledApp) -> Bool {
        app.bundleIDs.contains { FileManager.default.fileExists(atPath: library.appending(path: "Containers/\($0)").path) }
    }

    /// Uninstalling means not wanting the app any more: everything it left goes, its own data included
    /// (用户定，2026-10-25). It all lands in the Trash and can be put back.
    static func pickedByDefault(_ trace: AppTrace) -> Bool { true }

    private func namespaced(in folder: String, id: String, suffix: String) -> [URL] {
        let directory = library.appending(path: folder)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0 == id + suffix || ($0.hasPrefix(id + ".") && $0.hasSuffix(suffix)) }.map { directory.appending(path: $0) }
    }

    private func launchAgents(for app: InstalledApp) -> [URL] {
        let directory = library.appending(path: "LaunchAgents")
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { file in
            guard file.pathExtension == "plist" else { return false }
            if app.bundleIDs.contains(where: { file.lastPathComponent.hasPrefix($0) }) { return true }
            // Agents named after the vendor still point into the bundle.
            guard let plist = NSDictionary(contentsOf: file) else { return false }
            let program = (plist["Program"] as? String) ?? ((plist["ProgramArguments"] as? [String])?.first ?? "")
            return program.hasPrefix(app.id.path + "/")
        }
    }

    /// Existing, unprotected, non-overlapping paths with their size and identity.
    private func measured(_ candidates: [(URL, TraceKind)]) -> [AppTrace] {
        var traces: [AppTrace] = []
        for (url, kind) in candidates {
            let path = url.standardizedFileURL.path
            guard kind == .app || isAllowedTrace(url), !traces.contains(where: { $0.url.path == path }) else { continue }
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            let type = info.st_mode & mode_t(S_IFMT)
            guard type != mode_t(S_IFLNK) else { continue }
            let isDirectory = type == mode_t(S_IFDIR)
            traces.append(AppTrace(id: url.standardizedFileURL, kind: kind, bytes: isDirectory ? Self.size(of: url) : Int64(info.st_size),
                                   identity: FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino)), isDirectory: isDirectory,
                                   modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))))
        }
        // A parent already covers its children.
        return traces.filter { trace in !traces.contains { $0.url != trace.url && trace.url.path.hasPrefix($0.url.path + "/") } }
    }

    /// Leftovers may only come from these ~/Library folders, or from a recognized tool's data roots.
    func isAllowedTrace(_ url: URL) -> Bool {
        let path = CanonicalPath.url(url).path
        guard !policy.isProtected(url) else { return false }
        let folders = ["Application Support", "Caches", "Preferences", "Saved Application State", "HTTPStorages", "WebKit", "Cookies",
                       "Logs", "LaunchAgents"]
        for folder in folders {
            let base = CanonicalPath.url(library.appending(path: folder)).path
            // Direct children only (or Application Support/<vendor>/<tool> for recognized tools).
            if CanonicalPath.url(url.deletingLastPathComponent()).path == base { return true }
        }
        let relative = path.hasPrefix(policy.home.path + "/") ? String(path.dropFirst(policy.home.path.count + 1)) : ""
        let prefixes = [""] + CreativeApp.vendorFolders.map { $0 + "/" }
        return CreativeApp.allCases.contains { app in
            app.roots.contains(relative) || app.folders.contains { folder in
                prefixes.contains { relative == "Library/Application Support/\($0)\(folder)" || relative == "Library/Caches/\($0)\(folder)" }
            }
        }
    }

    static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    // MARK: Leftovers of apps that are gone

    /// Bundle-id-named items whose vendor has no installed app at all, merged per id.
    /// Only ids that left what apps leave (support files, caches or window state) count: preferences or network
    /// storage alone are just as often written by helpers, installers and SDKs inside apps that are still here.
    func orphans(installed: [InstalledApp]) -> [OrphanGroup] {
        let vendors = Set(installed.map { Self.vendor($0.bundleID) })
        // Ids a recognized, installed tool is known to use besides its main bundle id.
        let toolIDs = Set(CreativeApp.allCases.filter(\.isInstalled).flatMap { $0.apps + $0.folders }.map { $0.lowercased() })
        let folders: [(String, String)] = [("Application Support", ""), ("Caches", ""), ("Preferences", ".plist"),
                                           ("Saved Application State", ".savedState"), ("HTTPStorages", ""), ("WebKit", ""), ("Logs", "")]
        var byID: [String: [(URL, TraceKind)]] = [:]
        for (folder, suffix) in folders {
            let directory = library.appending(path: folder)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
                var id = name
                if !suffix.isEmpty {
                    guard name.hasSuffix(suffix) else { continue }
                    id = String(name.dropLast(suffix.count))
                }
                if folder == "HTTPStorages", id.hasSuffix(".binarycookies") { id = String(id.dropLast(".binarycookies".count)) }
                guard Self.looksLikeBundleID(id), !vendors.contains(Self.vendor(id)), !toolIDs.contains(id.lowercased()),
                      !Self.sdkVendors.contains(Self.vendor(id)) else { continue }
                let url = directory.appending(path: name)
                guard CreativeApp.dataOwner(url, home: policy.home) == nil else { continue }
                let kind: TraceKind = folder == "Caches" ? .caches : folder == "Logs" ? .logs : folder == "HTTPStorages" || folder == "WebKit" ? .web
                    : folder == "Application Support" ? .support : .preferences
                byID[id, default: []].append((url, kind))
            }
        }
        return byID.compactMap { id, candidates -> OrphanGroup? in
            guard candidates.contains(where: { [.support, .caches].contains($0.1) || $0.0.pathExtension == "savedState" }) else { return nil }
            // LaunchServices knows apps outside /Applications too (Setapp, external disks, other folders).
            guard !Self.isRegistered(id) else { return nil }
            let traces = measured(candidates)
            return traces.isEmpty ? nil : OrphanGroup(id: id, traces: traces)
        }
        .sorted { $0.bytes > $1.bytes }
    }

    /// Namespaces of SDKs and system or developer tools, not apps: their data belongs to whatever still uses them.
    static let sdkVendors: Set<String> = ["com.segment", "com.revenuecat", "com.launchdarkly", "com.bugsnag", "com.plausiblelabs",
                                          "com.telemetrydeck", "com.crashlytics", "io.sentry", "com.google", "org.sparkle-project",
                                          "org.cups", "org.swift", "net.java", "com.github", "org.python", "org.nodejs", "com.mixpanel",
                                          "com.amplitude", "io.realm", "com.firebase", "com.microsoft"]

    static func vendor(_ id: String) -> String { id.split(separator: ".").prefix(2).joined(separator: ".").lowercased() }

    static func looksLikeBundleID(_ id: String) -> Bool {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty && !$0.contains(" ") }) else { return false }
        let lower = id.lowercased()
        return !["com.apple.", "group.", "systemgroup.", "com.microsoft.autoupdate"].contains { lower.hasPrefix($0) }
            && parts[0].allSatisfy({ $0.isLetter }) && ["com", "org", "net", "io", "cn", "ai", "dev", "app", "co", "me", "tv", "us"].contains(parts[0].lowercased())
    }

    static func isRegistered(_ id: String) -> Bool {
        var parts = id.split(separator: ".").map(String.init)
        while parts.count >= 3 {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: parts.joined(separator: ".")) != nil { return true }
            parts.removeLast()
        }
        return false
    }

    // MARK: Moving

    /// Re-checks one leftover and moves it to the Trash.
    func moveTrace(_ trace: AppTrace) throws -> URL {
        guard trace.kind != .app, isAllowedTrace(trace.url) else { throw TrashError.notEligible }
        var info = stat()
        guard lstat(trace.url.path, &info) == 0,
              FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino)) == trace.identity else { throw TrashError.changed }
        try TrashService.ensureUnused(trace.url, isDirectory: trace.isDirectory)
        var resulting: NSURL?
        try FileManager.default.trashItem(at: trace.url, resultingItemURL: &resulting)
        return resulting as URL? ?? trace.url
    }
}

/// State of the "卸载应用" page.
@MainActor
final class UninstallStore: ObservableObject {
    enum Sort: String, CaseIterable, Identifiable {
        case size = "按大小", idle = "按上次使用时间"
        var id: String { rawValue }
    }

    @Published var apps: [InstalledApp] = []
    @Published var isLoading = false
    @Published var sort: Sort = .size
    @Published var search = ""
    /// Selected app, or nil when the leftovers of removed apps are shown.
    @Published var selectedID: URL?
    @Published var showOrphans = false
    /// Whether the merged "相关文件" row of the selected app is opened up.
    @Published var showRelated = false
    @Published var showToolData = false
    @Published private(set) var traces: [URL: [AppTrace]] = [:]
    @Published var picked: Set<URL> = []
    @Published var orphans: [OrphanGroup]?
    @Published var pickedOrphans: Set<String> = []
    @Published var showConfirm = false
    @Published var confirmDecided = false
    @Published var isWorking = false
    private let resultDismissTimer = ResultDismissTimer()
    @Published var report: CleanupReport? {
        didSet {
            resultDismissTimer.cancel()
            if report != nil { resultDismissTimer.schedule { [weak self] in self?.report = nil } }
        }
    }
    @Published var message: String?
    @Published private(set) var undoable: [(original: URL, trashed: URL)] = []

    /// App name to select once it is measured (`--select-app=` launch argument, for screenshots).
    var pendingSelection: String?

    let policy = SafetyPolicy()
    private var uninstaller: AppUninstaller { AppUninstaller(policy: policy) }
    private var loaded = false

    var visibleApps: [InstalledApp] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let filtered = query.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
        switch sort {
        case .size: return filtered.sorted { ($0.totalBytes ?? -1) > ($1.totalBytes ?? -1) }
        case .idle: return filtered.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        }
    }

    var selectedApp: InstalledApp? { apps.first { $0.id == selectedID } }

    /// The last list, for the overview, without measuring anything. The page itself still refreshes it on first visit.
    func showCachedList() {
        if apps.isEmpty { apps = Self.loadCache() }
    }

    /// Apps not opened for three months: the ones worth looking at first.
    var idleApps: [InstalledApp] {
        let cutoff = Date().addingTimeInterval(-90 * 86_400)
        return apps.filter { ($0.lastUsed ?? .distantFuture) < cutoff }
    }

    func isRunning(_ app: InstalledApp) -> Bool {
        app.bundleIDs.contains { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
    }

    /// First visit: list apps right away, then fill in sizes, last-used dates and leftovers in the background.
    func loadIfNeeded() {
        guard !loaded else { return }
        reload()
    }

    /// Shows the last list at once (sizes included), then refreshes it in the background without
    /// blanking anything: opening the page should not feel like a scan.
    func reload() {
        loaded = true
        isLoading = true
        if apps.isEmpty { apps = Self.loadCache() }
        let uninstaller = self.uninstaller
        Task.detached(priority: .userInitiated) { [weak self] in
            let fresh = uninstaller.installedApps()
            await MainActor.run {
                guard let self else { return }
                // Keep known sizes until they are measured again.
                let known = Dictionary(self.apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                self.apps = fresh.map { app in
                    var app = app
                    app.appBytes = known[app.id]?.appBytes
                    app.traceBytes = known[app.id]?.traceBytes
                    app.lastUsed = known[app.id]?.lastUsed
                    return app
                }
                if !fresh.contains(where: { $0.id == self.selectedID }) { self.selectedID = nil }
            }
            // A few at a time: sizes fill in quickly without hogging the disk.
            await withTaskGroup(of: Void.self) { group in
                var pending = fresh[...]
                func next() -> InstalledApp? { pending.popFirst() }
                for _ in 0..<4 {
                    guard let app = next() else { break }
                    group.addTask { await self?.measure(app, with: uninstaller) }
                }
                while await group.next() != nil {
                    if let app = next() { group.addTask { await self?.measure(app, with: uninstaller) } }
                }
            }
            let orphans = uninstaller.orphans(installed: fresh)
            await MainActor.run {
                guard let self else { return }
                self.orphans = orphans
                // The rules that find these are strict enough to clean them without asking.
                self.pickedOrphans = Set(orphans.map(\.id))
                self.isLoading = false
                Self.saveCache(self.apps)
            }
        }
    }

    nonisolated private func measure(_ app: InstalledApp, with uninstaller: AppUninstaller) async {
        let traces = uninstaller.traces(for: app)
        let used = AppUninstaller.lastUsed(app.appURL, traces: traces)
        await MainActor.run { self.apply(traces, lastUsed: used, to: app) }
    }

    private func apply(_ traces: [AppTrace], lastUsed: Date?, to app: InstalledApp) {
        guard let index = apps.firstIndex(where: { $0.id == app.id }) else { return }
        let firstLook = self.traces[app.id] == nil
        self.traces[app.id] = traces
        apps[index].appBytes = traces.first { $0.kind == .app }?.bytes
        apps[index].traceBytes = traces.filter { $0.kind != .app }.reduce(0) { $0 + $1.bytes }
        apps[index].lastUsed = lastUsed
        if selectedID == app.id, firstLook { pickDefaults(for: app) }
        if pendingSelection == app.name {
            pendingSelection = nil
            select(apps[index])
        }
    }

    private static var cacheURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Qingo/results")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "apps.json")
    }

    private static func loadCache() -> [InstalledApp] {
        guard let data = try? Data(contentsOf: cacheURL), let apps = try? JSONDecoder().decode([InstalledApp].self, from: data) else { return [] }
        return apps.filter { FileManager.default.fileExists(atPath: $0.id.path) }
    }

    private static func saveCache(_ apps: [InstalledApp]) {
        if let data = try? JSONEncoder().encode(apps) { try? data.write(to: cacheURL, options: .atomic) }
    }

    func select(_ app: InstalledApp) {
        showOrphans = false
        showRelated = false
        showToolData = false
        selectedID = app.id
        report = nil
        message = nil
        pickDefaults(for: app)
        // Not measured yet in this session: measure this one now rather than wait for its turn.
        if traces[app.id] == nil {
            let uninstaller = self.uninstaller
            Task.detached(priority: .userInitiated) { [weak self] in await self?.measure(app, with: uninstaller) }
        }
    }

    func selectOrphans() {
        showOrphans = true
        selectedID = nil
        report = nil
        message = nil
        pickedOrphans = Set((orphans ?? []).map(\.id))
    }

    private func pickDefaults(for app: InstalledApp) {
        picked = Set((traces[app.id] ?? []).filter(AppUninstaller.pickedByDefault).map(\.id))
    }

    /// Picks or unpicks a set of leftovers at once (the merged "相关文件" row).
    func toggle(_ group: [AppTrace]) {
        let ids = Set(group.map(\.id))
        if ids.isSubset(of: picked) { picked.subtract(ids) } else { picked.formUnion(ids) }
    }

    func toggle(_ trace: AppTrace) {
        // The bundle itself always goes; that is what uninstalling means.
        guard trace.kind != .app else { return }
        if picked.contains(trace.id) { picked.remove(trace.id) } else { picked.insert(trace.id) }
    }

    func toggleOrphan(_ group: OrphanGroup) {
        if pickedOrphans.contains(group.id) { pickedOrphans.remove(group.id) } else { pickedOrphans.insert(group.id) }
    }

    func hasContainer(_ app: InstalledApp) -> Bool { uninstaller.hasContainer(app) }

    func reviewCleanup() {
        confirmDecided = false
        showConfirm = true
    }

    // MARK: Uninstall

    func uninstall() {
        guard let app = selectedApp, let traces = traces[app.id], !isWorking else { return }
        showConfirm = false
        guard !isRunning(app) else {
            message = "\(app.name) 正在运行，请先退出再卸载"
            return
        }
        isWorking = true
        report = nil
        message = nil
        let leftovers = traces.filter { $0.kind != .app && picked.contains($0.id) }
        let uninstaller = self.uninstaller
        // The bundle goes through Finder's recycle, which asks for a password when the app belongs to the system admin.
        NSWorkspace.shared.recycle([app.id]) { [weak self] moved, error in
            Task { @MainActor in
                guard let self else { return }
                guard error == nil, let trashedApp = moved[app.id] else {
                    self.isWorking = false
                    self.message = "无法将 \(app.name) 移到废纸篓，可在访达中手动移除（可能需要输入密码）"
                    return
                }
                Task.detached(priority: .userInitiated) { [weak self] in
                    let result = Self.move(leftovers, with: uninstaller)
                    await MainActor.run {
                        guard let self else { return }
                        self.isWorking = false
                        self.undoable = [(app.id, trashedApp)] + result.moved
                        let bytes = (traces.first { $0.kind == .app }?.bytes ?? 0) + leftovers.filter { t in result.moved.contains { $0.original == t.url } }.reduce(0) { $0 + $1.bytes }
                        self.report = CleanupReport(movedCount: result.moved.count + 1, movedBytes: bytes, failures: result.failures)
                        self.apps.removeAll { $0.id == app.id }
                        self.traces[app.id] = nil
                        self.selectedID = nil
                    }
                }
            }
        }
    }

    func removeOrphans() {
        let groups = (orphans ?? []).filter { pickedOrphans.contains($0.id) }
        guard !groups.isEmpty, !isWorking else { return }
        showConfirm = false
        isWorking = true
        report = nil
        message = nil
        let traces = groups.flatMap(\.traces)
        let uninstaller = self.uninstaller
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Self.move(traces, with: uninstaller)
            await MainActor.run {
                guard let self else { return }
                self.isWorking = false
                self.undoable = result.moved
                let movedPaths = Set(result.moved.map(\.original.path))
                let bytes = traces.filter { movedPaths.contains($0.url.path) }.reduce(0) { $0 + $1.bytes }
                self.report = CleanupReport(movedCount: result.moved.count, movedBytes: bytes, failures: result.failures)
                self.orphans = self.orphans?.compactMap { group in
                    let left = group.traces.filter { !movedPaths.contains($0.url.path) }
                    return left.isEmpty ? nil : OrphanGroup(id: group.id, traces: left)
                }
                self.pickedOrphans.removeAll()
            }
        }
    }

    nonisolated private static func move(_ traces: [AppTrace], with uninstaller: AppUninstaller)
        -> (moved: [(original: URL, trashed: URL)], failures: [CleanupReport.Failure]) {
        var moved: [(original: URL, trashed: URL)] = []
        var failures: [CleanupReport.Failure] = []
        for trace in traces {
            do {
                moved.append((trace.url, try uninstaller.moveTrace(trace)))
            } catch {
                failures.append(CleanupReport.Failure(id: trace.url, name: trace.url.lastPathComponent, reason: TrashService.reason(for: error)))
            }
        }
        return (moved, failures)
    }

    func undo() {
        let entries = undoable
        guard !entries.isEmpty, !isWorking else { return }
        undoable = []
        isWorking = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let back = TrashService.putBack(entries)
            let restored = back.filter { $0 }.count
            await MainActor.run {
                guard let self else { return }
                self.isWorking = false
                self.report = nil
                self.message = restored == entries.count ? "已恢复 \(restored) 项" : "已恢复 \(restored) 项，\(entries.count - restored) 项未恢复"
                self.reload()
            }
        }
    }
}
