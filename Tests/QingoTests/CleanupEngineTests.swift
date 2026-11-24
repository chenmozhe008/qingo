import Foundation
import Testing
@testable import Qingo

@Suite("CleanupEngineTests")
struct CleanupEngineTests {

    private func makeTempHome() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appending(path: "qingo-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return CanonicalPath.url(base)
    }

    private func writeFile(_ url: URL, bytes: Int = 2048) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    @Test func sandboxCachesIncludeThirdPartyAndExcludeAppleAndChat() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let thirdParty = home.appending(path: "Library/Containers/com.example.editor/Data/Library/Caches")
        let apple = home.appending(path: "Library/Containers/com.apple.Safari/Data/Library/Caches")
        let wechat = home.appending(path: "Library/Containers/com.tencent.xinWeChat/Data/Library/Caches")
        try writeFile(thirdParty.appending(path: "thumb.bin"))
        try writeFile(apple.appending(path: "web.bin"))
        try writeFile(wechat.appending(path: "wx.bin"))

        let found = SandboxCaches.cacheDirectories(home: home).map(\.path)
        #expect(found.contains(thirdParty.path))
        #expect(!found.contains(apple.path))
        #expect(!found.contains(wechat.path))

        let policy = SafetyPolicy(home: home)
        #expect(policy.cacheDescription(for: thirdParty, isDirectory: true) != nil)
        #expect(policy.cacheDescription(for: apple, isDirectory: true) == nil)
    }

    @Test func developerCachesAllowXcodePreviewsAndProtectArchives() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let previews = home.appending(path: "Library/Developer/Xcode/Previews")
        let deviceSupport = home.appending(path: "Library/Developer/Xcode/iOS DeviceSupport")
        let archives = home.appending(path: "Library/Developer/Xcode/Archives")
        let simCaches = home.appending(path: "Library/Developer/CoreSimulator/Caches")
        let goBuild = home.appending(path: "Library/Caches/go-build")

        for dir in [previews, deviceSupport, archives, simCaches, goBuild] {
            try writeFile(dir.appending(path: "sample.dat"))
        }

        let policy = SafetyPolicy(home: home)
        #expect(!policy.isProtected(previews))
        #expect(!policy.isProtected(deviceSupport))
        #expect(policy.isProtected(archives))
        #expect(policy.cacheDescription(for: previews, isDirectory: true) != nil)
        #expect(policy.cacheDescription(for: deviceSupport, isDirectory: true) != nil)
        #expect(policy.cacheDescription(for: simCaches, isDirectory: true) != nil)
        #expect(policy.cacheDescription(for: goBuild, isDirectory: true) != nil)
        #expect(policy.cacheDescription(for: archives, isDirectory: true) == nil)
        #expect(policy.risk(for: previews, kind: .cache) == .a)
        #expect(policy.risk(for: simCaches, kind: .cache) == .a)
    }

    @Test func purgeTrashedRemovesOnlyTargetInsideTrashAndLeavesOtherFilesIntact() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let fakeTrash = home.appending(path: ".Trash")
        let qingoMoved = fakeTrash.appending(path: "qingo-cache-item")
        let userOwnTrashFile = fakeTrash.appending(path: "user-document.pdf")
        let outsideFile = home.appending(path: "Documents/important.txt")

        try writeFile(qingoMoved.appending(path: "blob.dat"), bytes: 4096)
        try writeFile(userOwnTrashFile, bytes: 1024)
        try writeFile(outsideFile, bytes: 1024)

        let id1 = TrashService.currentIdentity(qingoMoved)!
        let id2 = TrashService.currentIdentity(outsideFile)!

        let entries = [
            TrashedItem(
                item: ScanItem(id: home.appending(path: "Library/Caches/demo"),
                               url: home.appending(path: "Library/Caches/demo"),
                               kind: .cache, risk: .a, bytes: 4096, note: "demo", canTrash: true, identity: id1),
                trashed: qingoMoved
            ),
            TrashedItem(
                item: ScanItem(id: outsideFile, url: outsideFile,
                               kind: .cache, risk: .a, bytes: 1024, note: "outside", canTrash: true, identity: id2),
                trashed: outsideFile
            )
        ]

        let outcome = TrashService.purgeTrashed(entries, trashDirectory: fakeTrash)
        #expect(outcome.purgedCount == 1)
        #expect(outcome.purgedBytes == 4096)
        #expect(outcome.skippedOutsideTrash == 1)
        #expect(!FileManager.default.fileExists(atPath: qingoMoved.path))
        #expect(FileManager.default.fileExists(atPath: userOwnTrashFile.path))
        #expect(FileManager.default.fileExists(atPath: outsideFile.path))
    }

    @Test func cliCleanerAdaptersProbeAndExecuteWithSafeArguments() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        final class Recorder: @unchecked Sendable {
            var calls: [(String, [String])] = []
        }
        let recorder = Recorder()

        let adapters = CLICleanerAdapters(
            home: home,
            run: { exe, args, _ in
                recorder.calls.append((exe, args))
                if args.first == "cleanup" && args.contains("-n") {
                    return .init(status: 0, stdout: "Would remove: /opt/homebrew/foo\nWould remove: /opt/homebrew/bar\n", stderr: "")
                }
                if args.first == "simctl" && args.contains("list") {
                    return .init(status: 0, stdout: "== Devices ==\n-- Unavailable: com.apple.CoreSimulator.SimRuntime.iOS-16 --\n    iPhone 14 (UUID-1) (Shutdown)\n", stderr: "")
                }
                return .init(status: 0, stdout: "ok", stderr: "")
            },
            resolveExecutable: { name in "/mock/bin/\(name)" }
        )

        let brewProbe = adapters.probe(.homebrew)
        #expect(brewProbe.available)
        #expect(brewProbe.summary.contains("2 项"))

        let simProbe = adapters.probe(.xcodeSimulators)
        #expect(simProbe.available)
        #expect(simProbe.summary.contains("1 个"))

        let pnpmResult = adapters.execute(.pnpm)
        #expect(pnpmResult.succeeded)
        #expect(recorder.calls.contains(where: { $0.0 == "/mock/bin/pnpm" && $0.1 == ["store", "prune"] }))

        let uvResult = adapters.execute(.uv)
        #expect(uvResult.succeeded)
        #expect(recorder.calls.contains(where: { $0.0 == "/mock/bin/uv" && $0.1 == ["cache", "prune"] }))
    }

    @Test func cleanupEngineRunsConcurrentlyAndRespectsPermissionGating() async {
        struct MockProvider: CleanerProvider {
            let id: String
            let category: CleanCategory
            let requiredPermission: PermissionLevel
            let bytes: Int64

            func scan(context: ScanContext) async throws -> [CleanCandidate] {
                [CleanCandidate(
                    id: id,
                    category: category,
                    title: id,
                    subtitle: "",
                    risk: .a,
                    estimate: .exactAllocated(bytes),
                    action: .runCLI(id: id),
                    blocker: nil
                )]
            }
        }

        let engine = CleanupEngine(providers: [
            MockProvider(id: "small", category: .smartClean, requiredPermission: .standard, bytes: 100),
            MockProvider(id: "fda-only", category: .smartClean, requiredPermission: .fullDiskAccess, bytes: 9999),
            MockProvider(id: "large", category: .developer, requiredPermission: .standard, bytes: 500)
        ])

        let withoutFDA = await engine.scanAll(context: ScanContext(hasFullDiskAccess: false))
        #expect(withoutFDA.map(\.id) == ["large", "small"])

        let withFDA = await engine.scanAll(context: ScanContext(hasFullDiskAccess: true))
        #expect(withFDA.map(\.id) == ["fda-only", "large", "small"])
    }

    @Test func timeMachineSnapshotsThinRequestsDefault10GB() throws {
        final class ArgsRecorder: @unchecked Sendable {
            var thinArgs: [String]?
            var listCount = 0
        }
        let recorder = ArgsRecorder()
        let snap = "com.apple.TimeMachine.2026-11-22-120000.local"
        let service = TimeMachineSnapshots { args in
            if args.first == "listlocalsnapshots" {
                recorder.listCount += 1
                return recorder.listCount == 1 ? snap : ""
            }
            recorder.thinArgs = args
            return ""
        }
        let result = try service.thin(confirmed: [snap])
        #expect(result.removed == 1)
        #expect(recorder.thinArgs == ["thinlocalsnapshots", "/", "10000000000", "1"])
    }

    @Test func fastSizeCalculatorMeasuresBulkDeduplicatesHardlinksAndSkipsSymlinks() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let dirA = home.appending(path: "Alpha")
        let dirB = home.appending(path: "Beta")
        let fileA = dirA.appending(path: "big.bin")
        let hardlinkA = dirA.appending(path: "big-link.bin")
        let fileB = dirB.appending(path: "small.bin")
        let symlinkB = dirB.appending(path: "link-to-a")

        try writeFile(fileA, bytes: 65_536)
        try FileManager.default.linkItem(at: fileA, to: hardlinkA)
        try writeFile(fileB, bytes: 4_096)
        try FileManager.default.createSymbolicLink(at: symlinkB, withDestinationURL: fileA)

        let summaryA = FastSizeCalculator.measure(dirA)
        // Hardlink must only be counted once (logical size == 65_536, not 131_072)
        #expect(summaryA.logical == 65_536)
        #expect(summaryA.allocated > 0)

        let summaryB = FastSizeCalculator.measure(dirB)
        // Symlink target must NOT be counted
        #expect(summaryB.logical == 4_096)

        let children = await FastSizeCalculator.directChildrenSizes(of: home)
        #expect(children.count == 2)
        #expect(children.first?.name == "Alpha")
        #expect(children.last?.name == "Beta")
    }

    @Test func ruleCatalogDecodesSafeRulesAndRejectsTraversalPaths() throws {
        let json = """
        [
          {
            "id": "demo-app",
            "name": "Demo App",
            "category": "universal",
            "cachePaths": ["Library/Caches/DemoApp", "../etc/passwd", "/tmp/evil"],
            "note": "Demo cache",
            "highConfidence": true
          },
          {
            "id": "bad-app",
            "name": "Bad App",
            "category": "universal",
            "cachePaths": ["../../root"],
            "note": "Should be dropped",
            "highConfidence": false
          }
        ]
        """
        let rules = try RuleCatalog.decode(from: Data(json.utf8))
        #expect(rules.count == 1)
        #expect(rules[0].id == "demo-app")
        #expect(rules[0].cachePaths == ["Library/Caches/DemoApp"])

        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let slackCache = home.appending(path: "Library/Application Support/Slack/Cache")
        try writeFile(slackCache.appending(path: "data.bin"))
        let policy = SafetyPolicy(home: home)
        #expect(policy.cacheDescription(for: slackCache, isDirectory: true) != nil)
    }

    @Test func trashSentinelDetectsTrashedAppLeftoversAndSkipsAppleApps() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let fakeApp = home.appending(path: ".Trash/DemoTool.app")
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>com.example.demotool</string>
            <key>CFBundleName</key><string>DemoTool</string>
        </dict></plist>
        """
        try FileManager.default.createDirectory(at: fakeApp.appending(path: "Contents"), withIntermediateDirectories: true)
        try plist.write(to: fakeApp.appending(path: "Contents/Info.plist"), atomically: true, encoding: .utf8)

        let leftoverCache = home.appending(path: "Library/Caches/com.example.demotool/cache.dat")
        try writeFile(leftoverCache, bytes: 8192)

        let alert = TrashSentinel.inspectTrashedApp(at: fakeApp, home: home)
        #expect(alert != nil)
        #expect(alert?.appName == "DemoTool")
        #expect(alert?.bundleID == "com.example.demotool")
        #expect((alert?.traceCount ?? 0) >= 1)
        #expect((alert?.traceBytes ?? 0) > 0)
    }

    @Test @MainActor func spaceLensProtectsCriticalDirectories() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let store = SpaceLensStore(home: home, policy: SafetyPolicy(home: home))
        let libEntry = FastSizeCalculator.ChildEntry(url: home.appending(path: "Library"), name: "Library", isDirectory: true, bytes: 1000)
        let normalEntry = FastSizeCalculator.ChildEntry(url: home.appending(path: "Downloads/movie.mp4"), name: "movie.mp4", isDirectory: false, bytes: 1000)

        #expect(!store.canOfferTrash(for: libEntry))
        #expect(store.canOfferTrash(for: normalEntry))
        #expect(SpaceLensStore.semanticTitle(for: home.appending(path: "Downloads"), home: home) == "下载")
    }

    @Test func spotlightProbeParserAndMergeFlagsBloatedIndexOnly() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let reconciler = StorageReconciler(policy: SafetyPolicy(home: home))
        let base = StorageReconciler.Report(scannedAt: Date(), findings: [], adminProbed: false,
                                            systemSpotlightBytes: nil, systemLogsBytes: nil, systemCachesBytes: nil)

        // 170 GB spotlight index in kilobytes
        let bloated = SpotlightRepairService.parseProbeOutput("178257920|2097152|512000|0")
        #expect(bloated.spotlightBytes == 178_257_920 * 1024)
        let mergedBloated = reconciler.mergeAdminProbe(bloated, into: base)
        #expect(mergedBloated.adminProbed)
        #expect(mergedBloated.findings.contains(where: { $0.kind == .spotlightIndex && $0.action == .rebuildSpotlight }))

        // Normal 500 MB spotlight index should NOT be flagged
        let healthy = SpotlightRepairService.parseProbeOutput("512000|102400|102400|0")
        let mergedHealthy = reconciler.mergeAdminProbe(healthy, into: base)
        #expect(!mergedHealthy.findings.contains(where: { $0.kind == .spotlightIndex }))
    }

    @Test func reconcilerDetectsRunawayLogsAndOrphanLaunchAgents() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // Runaway log exceeding custom low test threshold (16 KB)
        let bigLog = home.appending(path: "Library/Logs/RunawayApp/telemetry.log")
        let smallLog = home.appending(path: "Library/Logs/NormalApp/app.log")
        try writeFile(bigLog, bytes: 32_768)
        try writeFile(smallLog, bytes: 1_024)

        // Orphan LaunchAgent pointing to missing binary vs live binary
        let agentsDir = home.appending(path: "Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        let orphanPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
            <key>Label</key><string>com.deleted.helper</string>
            <key>ProgramArguments</key><array><string>/Applications/DoesNotExist12345.app/Contents/MacOS/Helper</string></array>
        </dict></plist>
        """
        let livePlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
            <key>Label</key><string>com.alive.helper</string>
            <key>Program</key><string>/bin/sh</string>
        </dict></plist>
        """
        try orphanPlist.write(to: agentsDir.appending(path: "com.deleted.helper.plist"), atomically: true, encoding: .utf8)
        try livePlist.write(to: agentsDir.appending(path: "com.alive.helper.plist"), atomically: true, encoding: .utf8)

        let reconciler = StorageReconciler(policy: SafetyPolicy(home: home), runawayLogMinBytes: 16_384)
        let logs = reconciler.detectRunawayLogs()
        #expect(logs.count == 1)
        #expect(logs[0].title.contains("RunawayApp"))

        let orphans = reconciler.detectOrphanLaunchAgents()
        #expect(orphans.count == 1)
        #expect(orphans[0].subtitle.contains("com.deleted.helper"))
    }

    @Test @MainActor func appleRedesignFourDestinationsRouteCleanly() {
        let store = ScanStore()
        #expect(store.destination == .overview)

        for dest in AppDestination.allCases {
            store.navigate(to: dest)
            #expect(store.destination == dest)
            #expect(!store.showingHistory)
            #expect(dest == .spaceLens ? store.showingSpaceMap : !store.showingSpaceMap)
            #expect(dest == .apps ? store.tool == .uninstall : store.tool == nil)
        }

        store.openCleanupHistory()
        #expect(store.showingHistory)
        store.navigate(to: .overview)
        #expect(!store.showingHistory)
        #expect(store.destination == .overview)
    }

    @Test @MainActor func zeroOverlapSixSectionArchitectureAndUnifiedModules() {
        #expect(AppDestination.allCases.count == 6)
        #expect(ChatAITab.allCases == [.chat, .creative])
        #expect(DevMaintenanceTab.allCases == [.ai, .projects, .cli])
        #expect(AppsSystemTab.allCases == [.apps, .leftovers, .system])

        let unifiedModules = ScanStore.initialModules(unified: true, quick: false)
        #expect(unifiedModules.count == 6)
        #expect(unifiedModules.first?.id == "cache")
        #expect(unifiedModules.dropFirst().allSatisfy { $0.status == .waiting })

        let quickModules = ScanStore.initialModules(unified: false, quick: true)
        #expect(quickModules.count == 3)

        let store = ScanStore()
        store.openSentinelOrphans()
        #expect(store.destination == .apps)
        #expect(store.appsSystemTab == .leftovers)
    }

    @Test func electronCachesDetectChromiumLeavesAndProtectStorageAndSensitiveApps() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let safeCache = home.appending(path: "Library/Application Support/Linear/Cache")
        let safeSW = home.appending(path: "Library/Application Support/LarkWorkspace/Service Worker/CacheStorage")
        let localStorage = home.appending(path: "Library/Application Support/Linear/Local Storage")
        let vpnCache = home.appending(path: "Library/Application Support/ClashX/Cache")
        let chromeCache = home.appending(path: "Library/Application Support/Google/Chrome/Default/Cache")

        for dir in [safeCache, safeSW, localStorage, vpnCache, chromeCache] {
            try writeFile(dir.appending(path: "blob.dat"), bytes: 4096)
        }

        let policy = SafetyPolicy(home: home)
        let found = Set(ElectronCaches.cacheDirectories(home: home, policy: policy).map(\.path))
        #expect(found.contains(safeCache.path))
        #expect(found.contains(safeSW.path))
        #expect(!found.contains(localStorage.path))
        #expect(!found.contains(vpnCache.path))
        #expect(!found.contains(chromeCache.path))
        #expect(policy.cacheDescription(for: safeCache, isDirectory: true) != nil)
        #expect(policy.cacheDescription(for: localStorage, isDirectory: true) == nil)
    }

    @Test func directPurgeClearsPureCacheAndRefusesUserFiles() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let pureCache = home.appending(path: "Library/Caches/com.example.pure")
        let userFile = home.appending(path: "Downloads/movie.mp4")
        try writeFile(pureCache.appending(path: "cache.bin"), bytes: 8192)
        try writeFile(userFile, bytes: 8192)

        let policy = SafetyPolicy(home: home)
        let cacheID = try #require(TrashService.currentIdentity(pureCache))
        let fileID = try #require(TrashService.currentIdentity(userFile))
        let items = [
            ScanItem(id: pureCache, url: pureCache, kind: .cache, risk: .a, bytes: 8192,
                     note: "应用缓存", canTrash: true, identity: cacheID, allocatedBytes: 8192),
            ScanItem(id: userFile, url: userFile, kind: .largeFile, risk: .c, bytes: 8192,
                     note: "大文件", canTrash: false, identity: fileID, allocatedBytes: 8192)
        ]

        let outcome = await TrashService.purgeAll(items, policy: policy)
        #expect(outcome.purgedCount == 1)
        #expect(outcome.purgedBytes == 8192)
        #expect(outcome.failures.count == 1)
        #expect(!FileManager.default.fileExists(atPath: pureCache.path))
        #expect(FileManager.default.fileExists(atPath: userFile.path))
    }

    @Test func duplicateThreeStagePrehashSplitsSameSizeDifferentContent() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let downloads = home.appending(path: "Downloads")
        let desktop = home.appending(path: "Desktop")
        let a1 = downloads.appending(path: "video-a.mp4")
        let a2 = desktop.appending(path: "video-copy.mp4")
        let bSameSize = desktop.appending(path: "different-mid-same-size.mp4")

        var payloadA = Data(repeating: 0x11, count: 200_000)
        payloadA[0] = 0xAA
        payloadA[199_999] = 0xBB
        var payloadB = payloadA
        payloadB[100_000] = 0x99 // Same size, same head/tail, differs in middle

        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        try payloadA.write(to: a1)
        try payloadA.write(to: a2)
        try payloadB.write(to: bSameSize)

        let scanner = DuplicateFiles(policy: SafetyPolicy(home: home))
        let res = try scanner.scan(folders: [downloads, desktop], minimumBytes: 100_000)
        #expect(res.groups.count == 1)
        #expect(res.groups.first?.files.count == 2)
    }

    @Test func apfsGapFindingSurfacesLargeGapUntilAdminProbed() {
        let map = SpaceMap(
            measuredAt: Date(),
            total: 500_000_000_000,
            available: 10_000_000_000,
            blocks: [.init(id: "apps", title: "应用", bytes: 100_000_000_000, note: "", section: .decide, action: nil)]
        )
        let gapFinding = StorageReconciler.apfsUnaccountedGapFinding(spaceMap: map, cleanableBytes: 0, adminProbed: false)
        #expect(gapFinding != nil)
        #expect(gapFinding?.kind == .unaccountedGap)
        #expect(StorageReconciler.apfsUnaccountedGapFinding(spaceMap: map, cleanableBytes: 0, adminProbed: true) == nil)
    }

    @Test func uninstallerOrphansCollectDeadLaunchAgents() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let agentsDir = home.appending(path: "Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        let deadPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
            <key>Label</key><string>com.gonevendor.agent</string>
            <key>ProgramArguments</key><array><string>/Applications/GoneVendor999.app/Contents/MacOS/Agent</string></array>
        </dict></plist>
        """
        try deadPlist.write(to: agentsDir.appending(path: "com.gonevendor.agent.plist"), atomically: true, encoding: .utf8)

        let orphans = AppUninstaller(policy: SafetyPolicy(home: home)).orphans(installed: [])
        #expect(orphans.contains(where: { $0.id == "com.gonevendor.agent" }))
    }

    @Test @MainActor func smartCleanHybridPurgesPureCacheAndTrashesProjectBuildArtifactInOneClick() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let pureCache = home.appending(path: "Library/Caches/com.example.demo")
        let projectBuild = home.appending(path: "Tool/.build")
        try writeFile(pureCache.appending(path: "cache.dat"), bytes: 8192)
        try FileManager.default.createDirectory(at: projectBuild, withIntermediateDirectories: true)
        try Data("// swift-tools-version: 6.0".utf8).write(to: home.appending(path: "Tool/Package.swift"))
        try writeFile(projectBuild.appending(path: "artifact.o"), bytes: 8192)

        let policy = SafetyPolicy(home: home)
        let store = ScanStore(policy: policy)
        store.minShownBytes = 0
        store.includeOrphansInSmartClean = false
        store.setRoot(CanonicalPath.url(home))
        let scanned = try DiskScanner(policy: policy).scan(home)
        store.result = scanned
        store.selectAllEligible()

        #expect(store.selectedCacheItems.count == 2)
        store.triggerSmartClean()
        while store.isCleaning {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(!store.showTrashConfirmation)
        #expect(store.cleanupReport?.purgedCount == 1)
        #expect(store.cleanupReport?.movedCount == 1)
        #expect(!FileManager.default.fileExists(atPath: pureCache.path))
        #expect(!FileManager.default.fileExists(atPath: projectBuild.path))
        if !store.undoable.isEmpty {
            store.undoLastCleanup()
            while store.isRestoring { try await Task.sleep(for: .milliseconds(20)) }
        }
    }
}
