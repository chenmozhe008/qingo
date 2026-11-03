import Foundation
import Testing
@testable import Qingo

@Test func recyclePermissionErrorsAreDistinguished() {
    let permission = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
    let wrapped = NSError(domain: NSCocoaErrorDomain, code: 1, userInfo: ["NSUnderlyingErrors": [permission]])
    #expect(AppRecycle.permissionDenied(wrapped))
    #expect(!AppRecycle.permissionDenied(NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)))
    #expect(AppRecycle.shellQuote("Bob's app") == "'Bob'\\''s app'")
}

@Test func authorizedRecycleProbe() throws {
    guard let path = ProcessInfo.processInfo.environment["QINGO_AUTH_PROBE"] else { return }
    let source = URL(fileURLWithPath: path)
    let identity = try #require(TrashService.currentIdentity(source))
    let trashed = try AppRecycle.authorizedTrash(source, identity: identity)
    #expect(TrashService.currentIdentity(source) == nil)
    #expect(TrashService.currentIdentity(trashed) == identity)
    try AppRecycle.authorizedMove(from: trashed, to: source, identity: identity)
    #expect(TrashService.currentIdentity(source) == identity)
}

struct ToolPagesTests {
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    @Test @MainActor func backgroundDiscoveryPreservesPendingChoices() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let project = home.appending(path: "Coding/project")
        let cache = project.appending(path: ".build")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("// project".utf8).write(to: project.appending(path: "Package.swift"))
        try writeSparse(cache.appending(path: "data"), bytes: 6_000_000)
        let result = try DevScanner(policy: SafetyPolicy(home: home)).scan(home.appending(path: "Coding"))
        let store = DevStore()
        store.result = result
        store.selectAll()
        #expect(store.canDiscoverAutomatically)
        store.clearSelection()
        #expect(!store.canDiscoverAutomatically)
        store.selectAll()
        store.showConfirm = true
        #expect(!store.canDiscoverAutomatically)
        store.showConfirm = false
        store.isCleaning = true
        #expect(!store.canDiscoverAutomatically)
    }

    @Test func devScannerGroupsOutputByOutermostProjectAndSkipsCode() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appending(path: "Coding")
        let web = root.appending(path: "web")
        let package = web.appending(path: "packages/ui")
        for folder in [web.appending(path: "node_modules"), web.appending(path: ".next/cache"), web.appending(path: ".turbo"),
                       package.appending(path: "node_modules"), web.appending(path: "src")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data("{}".utf8).write(to: web.appending(path: "package.json"))
        try Data("{}".utf8).write(to: package.appending(path: "package.json"))
        try writeSparse(web.appending(path: "node_modules/dep"), bytes: 30_000_000)
        try writeSparse(web.appending(path: ".next/cache/data"), bytes: 6_000_000)
        try writeSparse(web.appending(path: ".turbo/data"), bytes: 1_000_000)
        try writeSparse(package.appending(path: "node_modules/dep"), bytes: 2_000_000)
        try Data("code".utf8).write(to: web.appending(path: "src/index.ts"))
        let tiny = root.appending(path: "tiny/__pycache__")
        try FileManager.default.createDirectory(at: tiny, withIntermediateDirectories: true)
        try Data("x = 1".utf8).write(to: root.appending(path: "tiny/requirements.txt"))
        try Data(repeating: 1, count: 100).write(to: tiny.appending(path: "a.pyc"))

        let policy = SafetyPolicy(home: home)
        let result = try DevScanner(policy: policy).scan(root)
        // The monorepo is one project; the tiny one is under the 5 MB bar.
        #expect(result.projects.map(\.name) == ["web"])
        let project = try #require(result.projects.first)
        let names = Set(project.artifacts.map { String($0.url.path.dropFirst(CanonicalPath.url(web).path.count + 1)) })
        // Only regenerable build output; dependencies are never listed for people who can't reinstall them.
        #expect(names == [".next/cache", ".turbo"])
        #expect(project.artifacts.allSatisfy { $0.canTrash })
        let turbo = try #require(project.artifacts.first { $0.name == ".turbo" })
        #expect(turbo.kind == .cache && turbo.canTrash && turbo.risk == .a)
        #expect(project.modified != nil)
        // Caches found here are the same ones TrashService accepts.
        let trashed = try TrashService(policy: policy).moveToTrash(turbo)
        try? FileManager.default.removeItem(at: trashed)
    }

    @Test func uninstallTracesStayInsideKnownLibraryFolders() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let id = "com.example.Sample"
        let app = home.appending(path: "Applications/Sample.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": "Sample", "CFBundleExecutable": "Electron",
                                    "CFBundleShortVersionString": "1.0", "CFBundlePackageType": "APPL"]
        (plist as NSDictionary).write(to: app.appending(path: "Info.plist"), atomically: true)
        let library = home.appending(path: "Library")
        for folder in ["Application Support/Sample", "Caches/\(id)", "Saved Application State/\(id).savedState", "Containers/\(id)",
                       "Application Support/Unrelated", "LaunchAgents", "Logs/Electron"] {
            try FileManager.default.createDirectory(at: library.appending(path: folder), withIntermediateDirectories: true)
        }
        try Data("x".utf8).write(to: library.appending(path: "Application Support/Sample/state"))
        for file in ["Preferences/\(id).plist", "Preferences/\(id).helper.plist", "Preferences/com.example.SampleOther.plist",
                     "LaunchAgents/\(id).updater.plist"] {
            try FileManager.default.createDirectory(at: library.appending(path: file).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("<plist/>".utf8).write(to: library.appending(path: file))
        }
        let uninstaller = AppUninstaller(policy: SafetyPolicy(home: home))
        let installed = try #require(uninstaller.installedApps().first { $0.bundleID == id })
        let traces = uninstaller.traces(for: installed)
        let relative = Set(traces.map { $0.url.path.replacingOccurrences(of: CanonicalPath.url(home).path + "/", with: "")
            .replacingOccurrences(of: home.path + "/", with: "") })
        #expect(relative == ["Applications/Sample.app", "Library/Application Support/Sample", "Library/Caches/\(id)",
                             "Library/Saved Application State/\(id).savedState", "Library/Preferences/\(id).plist",
                             "Library/Preferences/\(id).helper.plist", "Library/LaunchAgents/\(id).updater.plist"])
        #expect(traces.allSatisfy { AppUninstaller.pickedByDefault($0) })
        #expect(uninstaller.hasContainer(installed))
        // A leftover outside the allowed folders is refused even if asked.
        let outside = AppTrace(id: home.appending(path: "Documents"), kind: .support, bytes: 0, identity: FileIdentity(device: 0, inode: 0), isDirectory: true)
        #expect(throws: TrashError.self) { try uninstaller.moveTrace(outside) }
    }

    @Test func orphansNeedABundleIDWithNoInstalledVendor() throws {
        #expect(AppUninstaller.looksLikeBundleID("com.vendor.app"))
        #expect(!AppUninstaller.looksLikeBundleID("com.apple.Safari"))
        #expect(!AppUninstaller.looksLikeBundleID("Google"))
        #expect(!AppUninstaller.looksLikeBundleID("group.com.vendor.app"))
        #expect(!AppUninstaller.looksLikeBundleID("Some Folder.with.dots"))
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let library = home.appending(path: "Library")
        // Preferences / network storage alone, or an SDK namespace, are not proof of a removed app.
        for file in ["Preferences/com.prefsonly.tool.plist", "Preferences/org.cups.PrintingPrefs.plist"] {
            try FileManager.default.createDirectory(at: library.appending(path: file).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("<plist/>".utf8).write(to: library.appending(path: file))
        }
        for folder in ["Caches/com.gonevendor.tool", "Application Support/com.gonevendor.tool", "Caches/com.livevendor.helper",
                       "HTTPStorages/com.httponly.tool", "Application Support/com.segment.storage"] {
            try FileManager.default.createDirectory(at: library.appending(path: folder), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 10).write(to: library.appending(path: "\(folder)/data"))
        }
        let installed = [InstalledApp(id: URL(fileURLWithPath: "/Applications/Live.app"), name: "Live", bundleID: "com.livevendor.Live", version: nil)]
        let orphans = AppUninstaller(policy: SafetyPolicy(home: home)).orphans(installed: installed)
        #expect(orphans.map(\.id) == ["com.gonevendor.tool"])
        #expect(orphans.first?.traces.count == 2)
    }

    @Test func folderOfAppsIsOneProduct() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home.appending(path: "Applications/Studio Suite")
        func makeApp(_ name: String, id: String) throws {
            let contents = folder.appending(path: "\(name).app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            (["CFBundleIdentifier": id, "CFBundleName": name, "CFBundlePackageType": "APPL"] as NSDictionary)
                .write(to: contents.appending(path: "Info.plist"), atomically: true)
        }
        try makeApp("Studio Suite", id: "com.example.studio")
        try makeApp("Uninstall Studio", id: "com.example.studio.uninstaller")
        try makeApp("Studio Helper", id: "com.example.studio.helper")
        let prefs = home.appending(path: "Library/Preferences")
        try FileManager.default.createDirectory(at: prefs, withIntermediateDirectories: true)
        for id in ["com.example.studio", "com.example.studio.helper"] {
            try Data("<plist/>".utf8).write(to: prefs.appending(path: "\(id).plist"))
        }
        let uninstaller = AppUninstaller(policy: SafetyPolicy(home: home))
        let apps = uninstaller.installedApps().filter { $0.bundleIDs.contains { $0.hasPrefix("com.example.") } }
        // One entry, named after the folder, removed as the whole folder; leftovers of every member found.
        #expect(apps.count == 1)
        let suite = try #require(apps.first)
        #expect(suite.name == "Studio Suite" && suite.bundleID == "com.example.studio")
        #expect(suite.appURL.lastPathComponent == "Studio Suite.app")
        let traces = uninstaller.traces(for: suite)
        #expect(traces.first { $0.kind == .app }?.url.lastPathComponent == "Studio Suite")
        #expect(traces.filter { $0.kind == .preferences }.count == 2)
    }

    @Test func projectsAndSystemFilesStayUnlessPicked() {
        func trace(_ kind: TraceKind) -> AppTrace {
            AppTrace(id: URL(fileURLWithPath: "/x"), kind: kind, bytes: 0, identity: FileIdentity(device: 0, inode: 0), isDirectory: true)
        }
        #expect(!AppUninstaller.pickedByDefault(trace(.projects)))
        #expect(!AppUninstaller.pickedByDefault(trace(.system)))
        #expect(AppUninstaller.pickedByDefault(trace(.toolData)))
        #expect(AppUninstaller.pickedByDefault(trace(.caches)))
    }

    @Test func systemFolderMovesOnlyForItsOwnApp() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let resolve = InstalledApp(id: URL(fileURLWithPath: "/Applications/DaVinci Resolve"), name: "DaVinci Resolve", bundleID: "com.blackmagic-design.DaVinciResolve", version: nil)
        let other = InstalledApp(id: URL(fileURLWithPath: "/Applications/Other.app"), name: "Other", bundleID: "com.example.other", version: nil)
        #expect(AppUninstaller.systemFolders(for: other).isEmpty)
        let folder = try #require(AppUninstaller.systemFolders(for: resolve).first)
        let trace = AppTrace(id: folder, kind: .system, bytes: 0, identity: FileIdentity(device: 0, inode: 0), isDirectory: true)
        let uninstaller = AppUninstaller(policy: SafetyPolicy(home: home))
        #expect(throws: TrashError.self) { try uninstaller.moveTrace(trace, of: other) }
        #expect(throws: TrashError.self) { try uninstaller.moveTrace(trace) }
        // A wrong identity is refused before any password prompt.
        #expect(throws: TrashError.self) { try uninstaller.moveTrace(trace, of: resolve) }
    }

    @Test func pythonLauncherFolderIsNotListed() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        for (name, id) in [("IDLE", "org.python.IDLE"), ("Python Launcher", "org.python.PythonLauncher")] {
            let contents = home.appending(path: "Applications/Python 3.14/\(name).app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            (["CFBundleIdentifier": id, "CFBundleName": name, "CFBundlePackageType": "APPL"] as NSDictionary)
                .write(to: contents.appending(path: "Info.plist"), atomically: true)
        }
        #expect(!AppUninstaller(policy: SafetyPolicy(home: home)).installedApps().contains { $0.bundleID.hasPrefix("org.python.") })
    }

    @MainActor @Test func productLinesSitNextToEachOtherAsSeparateRows() {
        func app(_ name: String, _ id: String, _ bytes: Int64) -> InstalledApp {
            InstalledApp(id: URL(fileURLWithPath: "/Applications/\(name).app"), name: name, bundleID: id, version: nil, appBytes: bytes)
        }
        let store = UninstallStore()
        store.apps = [app("DaVinci", "com.blackmagic-design.DaVinciResolve", 100), app("RAW", "com.blackmagic-design.BlackmagicRawSpeedTest", 5),
                      app("WeChat", "com.tencent.xinWeChat", 50), app("WeCom", "com.tencent.WeWorkMac", 40), app("AE", "com.adobe.AfterEffects.application", 30)]
        // RAW is small but follows DaVinci; Tencent's unrelated apps are not treated as a product line.
        #expect(store.visibleApps.map(\.name) == ["DaVinci", "RAW", "WeChat", "WeCom", "AE"])
        store.search = "raw"
        #expect(store.visibleApps.map(\.name) == ["RAW"])
    }

    @Test func slimItemsAreExactPathsOnly() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let model = home.appending(path: "Movies/JianyingPro/User Data/SupplysStore/local-asr-supplies")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data(count: 2048).write(to: model.appending(path: "model.onnx"))
        let drafts = home.appending(path: "Movies/JianyingPro/User Data/Projects")
        try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)
        let jianying = InstalledApp(id: home.appending(path: "Applications/VideoFusion-macOS.app"), name: "剪映专业版", bundleID: "com.lemon.lvpro", version: nil)
        let uninstaller = AppUninstaller(policy: SafetyPolicy(home: home))
        let items = uninstaller.slimItems(for: jianying)
        #expect(items.map(\.url.lastPathComponent) == ["local-asr-supplies"])
        #expect(items.first?.bytes == 2048)
        // Anything not in the recipe is refused, even with a matching identity.
        let identity = try #require(TrashService.currentIdentity(drafts))
        let forged = AppSlimItem(id: drafts, title: "草稿", note: "", bytes: 0, identity: identity)
        #expect(throws: TrashError.self) { try uninstaller.moveSlimItem(forged, of: jianying) }
        #expect(FileManager.default.fileExists(atPath: drafts.path))
    }

    @Test func slimItemMovesToTrashAndComesBack() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let model = home.appending(path: "Movies/JianyingPro/User Data/SupplysStore/local-asr-supplies")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data(count: 16).write(to: model.appending(path: "model.onnx"))
        let jianying = InstalledApp(id: home.appending(path: "Applications/VideoFusion-macOS.app"), name: "剪映专业版", bundleID: "com.lemon.lvpro", version: nil)
        let uninstaller = AppUninstaller(policy: SafetyPolicy(home: home))
        let item = try #require(uninstaller.slimItems(for: jianying).first)
        let trashed = try uninstaller.moveSlimItem(item, of: jianying)
        #expect(!FileManager.default.fileExists(atPath: model.path))
        #expect(TrashService.putBack([(original: model, trashed: trashed)]) == [true])
        #expect(FileManager.default.fileExists(atPath: model.appending(path: "model.onnx").path))
    }

    @Test func afterEffectsLeftoverIsOnlyAFolderWithNothingButPlugins() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let apps = home.appending(path: "Applications")
        for path in ["Adobe After Effects 2025/Plug-ins/Old.plugin", "Adobe After Effects 2024/Plug-ins", "Adobe After Effects 2024/Adobe After Effects 2024.app",
                     "Adobe After Effects 2026/Adobe After Effects 2026.app"] {
            try FileManager.default.createDirectory(at: apps.appending(path: path), withIntermediateDirectories: true)
        }
        let current = InstalledApp(id: apps.appending(path: "Adobe After Effects 2026"), name: "Adobe After Effects 2026",
                                   bundleID: "com.adobe.AfterEffects.application", version: nil)
        #expect(AppSlimming.parts(for: current, home: home).map(\.url.lastPathComponent) == ["Adobe After Effects 2025"])
    }

    @Test func backgroundOnlyHelpersAreNotListed() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        func makeApp(_ name: String, id: String, extra: [String: Any] = [:]) throws {
            let contents = home.appending(path: "Applications/\(name).app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            var plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundlePackageType": "APPL"]
            plist.merge(extra) { _, new in new }
            (plist as NSDictionary).write(to: contents.appending(path: "Info.plist"), atomically: true)
        }
        try makeApp("Helper", id: "com.example.helper", extra: ["LSBackgroundOnly": true])
        try makeApp("MenuBar", id: "com.example.menubar", extra: ["LSUIElement": true])
        let ids = AppUninstaller(policy: SafetyPolicy(home: home)).installedApps().map(\.bundleID)
        #expect(!ids.contains("com.example.helper"))
        #expect(ids.contains("com.example.menubar"))
    }
}

struct PageSwitchTests {
    /// The overview is the whole Mac; a location opens its own page; a category clears both.
    @Test @MainActor func overviewScanDetailAndCategoryAreDistinctPages() {
        let store = ScanStore()
        store.showScanDetail()
        #expect(store.showingScanDetail && !store.showingOverview)
        store.showOverview()
        #expect(store.showingOverview && !store.showingScanDetail)
        store.selectCategory(.caches)
        #expect(!store.showingOverview && !store.showingScanDetail)
    }

    /// A tool opened from a location without a result falls back to the quick scan, so the sidebar keeps its categories.
    @Test @MainActor func toolFromUnscannedLocationKeepsAResult() throws {
        let store = ScanStore()
        store.selectLocation(URL(fileURLWithPath: "/Volumes/never-scanned-\(UUID().uuidString)"), quick: false)
        #expect(store.result == nil)
        store.openTool(.dev)
        #expect(store.tool == .dev)
        #expect(store.isQuickScope)
    }
}
