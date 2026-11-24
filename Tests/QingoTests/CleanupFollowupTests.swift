import Foundation
import Testing
@testable import Qingo

struct CleanupFollowupTests {
    @Test func volumeChangesUseTheSameDiskAndForwardTime() throws {
        let now = Date()
        let before = VolumeSpaceReading(uuid: "disk-one", mount: URL(fileURLWithPath: "/"),
                                        label: "Mac", available: 100, measuredAt: now)
        let after = VolumeSpaceReading(uuid: "disk-one", mount: before.mount,
                                       label: "Mac", available: 70, measuredAt: now.addingTimeInterval(1))
        let different = VolumeSpaceReading(uuid: "disk-two", mount: before.mount,
                                           label: "Mac", available: 120, measuredAt: now.addingTimeInterval(1))
        #expect(after.change(since: before) == -30)
        #expect(before.change(since: after) == nil)
        #expect(different.change(since: before) == nil)
        #expect((try JSONDecoder().decode(VolumeSpaceReading.self, from: JSONEncoder().encode(before))) == before)
        let measured = try #require(VolumeSpaceReading.read(at: FileManager.default.temporaryDirectory))
        #expect(!measured.uuid.isEmpty && measured.available >= 0)
    }

    @Test func trashMayBeEmptyWithoutConflatingLinksAndUnreadableTrees() throws {
        try withHome { home in
            let trash = home.appending(path: ".Trash")
            #expect(DirectoryOccupancy.bytes(at: trash, missingIsEmpty: true) == 0)
            #expect(DirectoryOccupancy.bytes(at: trash) == nil)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            #expect(DirectoryOccupancy.bytes(at: trash) == 0)
            let file = trash.appending(path: "data")
            try Data(repeating: 1, count: 1000).write(to: file)
            let allocated = try #require(DirectoryOccupancy.bytes(at: trash))
            #expect(allocated >= 1000)
            try FileManager.default.linkItem(at: file, to: trash.appending(path: "hard-link"))
            let alias = home.appending(path: "trash-alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: trash)
            #expect(DirectoryOccupancy.bytes(at: trash) == allocated)
            #expect(DirectoryOccupancy.bytes(at: alias) == nil)
        }
    }

    @Test func updaterStagingIsReadOnlyButSiblingBrowserCachesRemainCleanable() throws {
        try withHome { home in
            let paths = [
                "Library/Caches/com.example.editor/org.sparkle-project.Sparkle/Installation/build-current",
                "Library/Caches/com.example.editor/Code Cache",
                "Library/Caches/com.example.editor.ShipIt/update.current",
                "Library/Application Support/Caches/another-updater/pending"
            ]
            for path in paths { try file(home.appending(path: path + "/data"), Data([1])) }
            let policy = SafetyPolicy(home: home)
            let scanner = DiskScanner(policy: policy)
            let parent = home.appending(path: "Library/Caches/com.example.editor")
            for result in try [scanner.scanKnownCaches(), scanner.scan(home)] {
                let safe = Set(result.items.filter(\.canTrash).map(\.url.path))
                #expect(safe == [home.appending(path: paths[1]).path])
                #expect(result.items.count { $0.kind == .review && $0.note.contains("应用更新暂存") } == 3)
            }
            let identity = try #require(TrashService.currentIdentity(parent))
            let stale = ScanItem(id: parent, url: parent, kind: .cache, risk: .b, bytes: 5000,
                                 note: "旧扫描缓存", canTrash: true, identity: identity)
            #expect(throws: TrashError.notEligible) { try TrashService(policy: policy).moveToTrash(stale) }
            #expect(FileManager.default.fileExists(atPath: home.appending(path: paths[0] + "/data").path))
        }
    }

    @Test func playwrightPreviewRespectsVersionsAndFlagsBrokenRegistrations() throws {
        try withHome { home in
            let root = home.appending(path: "Library/Caches/ms-playwright")
            let references = root.appending(path: ".links")
            let package = home.appending(path: "fixture-playwright-package")
            try file(package.appending(path: "browsers.json"), Data("""
                {"browsers":[{"name":"chromium","revision":"1217"},{"name":"webkit","revision":"2272",
                "revisionOverrides":{"mac14":"2251"}}]}
                """.utf8))
            try file(references.appending(path: "one"), Data(package.path.utf8))
            for name in ["chromium-1217", "chromium-1223", "webkit-2251"] {
                try file(root.appending(path: name + "/INSTALLATION_COMPLETE"), Data())
            }
            try file(root.appending(path: "chromium-1248/partial"), Data())
            let complete = try PlaywrightPreview.scan(home: home, environment: [:])
            let states = Dictionary(uniqueKeysWithValues: complete.entries.map { ($0.url.lastPathComponent, $0.state) })
            #expect(states["chromium-1217"] == .registered)
            #expect(states["chromium-1223"] == .unlisted)
            #expect(states["webkit-2251"] == .registered)
            #expect(states["chromium-1248"] == .incomplete)

            let custom = try PlaywrightPreview.scan(home: home, environment: ["PLAYWRIGHT_BROWSERS_PATH": "0"])
            #expect(custom.customRoot)
            #expect(!custom.entries.contains { $0.state == .unlisted })

            try file(references.appending(path: "broken"), Data(home.appending(path: "no-project").path.utf8))
            let uncertain = try PlaywrightPreview.scan(home: home, environment: [:])
            #expect(uncertain.unreadableRegistrations == 1)
            #expect(uncertain.entries.first { $0.url.lastPathComponent == "chromium-1223" }?.state == .unknown)

            try FileManager.default.createDirectory(at: root.appending(path: "__dirlock"), withIntermediateDirectories: true)
            #expect(try PlaywrightPreview.scan(home: home, environment: [:]).isInstalling)
        }
    }

    @Test func sameVersionAndUnrecognizedClonesNeverCountAsObsolete() {
        #expect(Leftovers.isObsolete("158.0.7.51", installed: "158.0.8127.36"))
        #expect(!Leftovers.isObsolete("158.0.8127.36", installed: "158.0.8127.36"))
        #expect(!Leftovers.isObsolete("159.0.8127.36", installed: "158.0.8127.36"))
        #expect(!Leftovers.isObsolete("unknown", installed: "158.0.8127.36"))
    }

    @Test func scanEventsKeepTheLatestProgressAndDrainItemsOnce() {
        let feed = ScanEventBuffer()
        let url = URL(fileURLWithPath: "/tmp/test-cache")
        let found = ScanItem(id: url, url: url, kind: .cache, risk: .a, bytes: 5,
                             note: "", canTrash: true, identity: FileIdentity(device: 1, inode: 2))
        feed.record(ScanProgress(scannedCount: 100, currentFolder: "a"))
        feed.record(found)
        feed.record(ScanProgress(scannedCount: 200, currentFolder: "b"))
        let first = feed.drain()
        #expect(first.progress?.scannedCount == 200)
        #expect(first.items.map(\.url) == [url])
        let next = feed.drain()
        #expect(next.progress == nil && next.items.isEmpty)
    }

    private func file(_ url: URL, _ bytes: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
    }

    private func withHome(_ body: (URL) throws -> Void) throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try body(CanonicalPath.url(tmp))
    }
}
