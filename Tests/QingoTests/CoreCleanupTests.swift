import AppKit
import Foundation
import Testing
@testable import Qingo

struct CoreCleanupTests {
    @Test func browserProfilesExposeOnlyKnownCacheLeaves() throws {
        try withHome { home in
            let safe = [
                "Library/Caches/Google/Chrome/Default/Cache",
                "Library/Application Support/Google/Chrome/Profile 2/Code Cache",
                "Library/Application Support/Microsoft Edge/Default/GPUCache",
                "Library/Caches/BraveSoftware/Brave-Browser/Default/Cache",
                "Library/Caches/Firefox/Profiles/test.default-release/cache2",
                "Library/Application Support/Codex/GPUCache"
            ]
            let protected = [
                "Library/Caches/Google/Chrome/Default/Service Worker/CacheStorage",
                "Library/Application Support/Google/Chrome/Profile 2/IndexedDB",
                "Library/Application Support/Microsoft Edge/Default/GPUCache/../Local Storage",
                "Library/Application Support/Firefox/Profiles/test.default-release/cache2",
                "Library/Application Support/Codex/Local Storage",
                "Library/Caches/llama.cpp"
            ]
            for path in safe + protected { _ = try cache(home, path) }
            let alias = home.appending(path: "Library/Caches/Google/Chrome/Profile 7")
            try FileManager.default.createSymbolicLink(at: alias,
                withDestinationURL: home.appending(path: "Library/Caches/Google/Chrome/Default"))
            let scanner = DiskScanner(policy: SafetyPolicy(home: home))
            let expected = Set(safe.map { home.appending(path: $0).path })
            for result in try [scanner.scanKnownCaches(), scanner.scan(home)] {
                #expect(Set(result.items.filter(\.canTrash).map(\.url.path)) == expected)
            }
        }
    }

    @Test func protectedDescendantsAndLinksCannotBeMovedThroughAnApprovedCache() throws {
        try withHome { home in
            let known = try cache(home, "Library/Caches/com.example.cache/keep")
            let parent = known.deletingLastPathComponent()
            let plainScanner = DiskScanner(policy: SafetyPolicy(home: home))
            let parentItem = try #require(plainScanner.scanKnownCaches().items.first { $0.url.path == parent.path })
            let excludingChild = SafetyPolicy(home: home, extraProtected: [known])
            #expect(try DiskScanner(policy: excludingChild).scanKnownCaches().items.allSatisfy { !$0.canTrash })
            #expect(throws: TrashError.notEligible) { try TrashService(policy: excludingChild).moveToTrash(parentItem) }

            let alternative = home.appending(path: "Library/Caches2")
            try FileManager.default.createSymbolicLink(at: alternative, withDestinationURL: parent.deletingLastPathComponent())
            let linked = alternative.appending(path: parent.lastPathComponent)
            let forged = ScanItem(id: linked, url: linked, kind: .cache, risk: .b, bytes: parentItem.bytes,
                                  note: "", canTrash: true, identity: parentItem.identity)
            #expect(throws: TrashError.changed) { try TrashService(policy: plainScanner.policy).moveToTrash(forged) }
            #expect(FileManager.default.fileExists(atPath: known.path))
        }
    }

    @Test func oldDiagnosticsMoveIndividuallyAndAreCheckedAgainAtCleanup() throws {
        try withHome { home in
            let base = home.appending(path: "Library/Logs/DiagnosticReports")
            let retired = base.appending(path: "Retired")
            try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
            let old = retired.appending(path: "App.ips")
            let young = base.appending(path: "Recent.ips")
            let log = base.appending(path: "Active.log")
            let staleDate = Date().addingTimeInterval(-31 * 86_400)
            for url in [old, young, log] { try Data([42]).write(to: url) }
            for url in [old, log] {
                try FileManager.default.setAttributes([.modificationDate: staleDate], ofItemAtPath: url.path)
            }
            let policy = SafetyPolicy(home: home)
            let scan = try DiskScanner(policy: policy).scanKnownCaches()
            #expect(scan.items.filter(\.canTrash).map(\.url.path) == [old.path])
            let item = try #require(scan.items.first)
            let moved = try TrashService(policy: policy).moveToTrash(item)
            #expect(TrashService.putBack([(old, moved)]) == [true])
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: old.path)
            #expect(throws: TrashError.changed) { try TrashService(policy: policy).moveToTrash(item) }
            #expect(FileManager.default.fileExists(atPath: young.path))
        }
    }

    @MainActor @Test func smallCachesAreIncludedWhenTheyAddUp() {
        let store = ScanStore()
        let urls = (0..<4).map { URL(fileURLWithPath: "/Users/test/Library/Caches/org.test.tiny-\($0)") }
        let items = urls.map { url in
            ScanItem(id: url, url: url, kind: .cache, risk: .b, bytes: 200_000, note: "",
                     canTrash: true, identity: FileIdentity(device: 1, inode: 1), allocatedBytes: 300_000)
        }
        store.result = ScanResult(root: URL(fileURLWithPath: "/Users/test"), isQuickScan: true, items: items,
                                  totalBytes: 800_000, volumeTotalBytes: nil, volumeFreeBytes: nil, skippedCount: 0,
                                  scannedCount: 4, scannedAt: Date())
        store.selectAllEligible()
        #expect(Set(store.selectedCleanupItems.map(\.url)) == Set(urls))
        #expect(store.selectedCleanupBytes == 1_200_000)
    }

    @MainActor @Test func browserCachesLeaveTheOneClickTotalUntilTheBrowserExits() {
        let store = ScanStore()
        let url = store.policy.home.appending(path: "Library/Caches/Microsoft Edge/Default/Cache")
        let item = ScanItem(id: url, url: url, kind: .cache, risk: .b, bytes: 2_000_000, note: "",
                            canTrash: true, identity: FileIdentity(device: 1, inode: 1))
        store.result = ScanResult(root: store.policy.home, isQuickScan: true, items: [item], totalBytes: item.bytes,
                                  volumeTotalBytes: nil, volumeFreeBytes: nil, skippedCount: 0, scannedCount: 1, scannedAt: Date())
        store.refreshBrowserAvailability(runningBundleIDs: ["com.microsoft.edgemac"])
        store.selectAllEligible()
        #expect(store.eligibleItems.isEmpty)
        #expect(store.selectedCleanupItems.isEmpty)
        #expect(store.deferredBrowserBytes == item.bytes)
        store.refreshBrowserAvailability(runningBundleIDs: [])
        #expect(store.eligibleItems.map(\.id) == [item.id])
        #expect(store.selectedCleanupItems.map(\.id) == [item.id])
    }

    @Test func sparseFilesAndHardLinksDoNotInflateCacheEstimates() throws {
        try withHome { home in
            let folder = try cache(home, "Library/Caches/org.test.sparse")
            let sparse = folder.appending(path: "empty-blocks")
            try writeSparse(sparse, bytes: 900_000_000)
            let file = folder.appending(path: "data")
            try FileManager.default.linkItem(at: file, to: home.appending(path: "outside-cache"))
            let result = try DiskScanner(policy: SafetyPolicy(home: home)).scanKnownCaches()
            let row = try #require(result.items.first)
            #expect(row.bytes >= 900_000_000)
            #expect(row.allocatedBytes == 0)
        }
    }

    @Test func recentCleanupRecognizesNewlyCreatedCacheDirectories() throws {
        try withHome { home in
            let before = Date().addingTimeInterval(-60)
            let cache = try cache(home, "Library/Caches/org.test.recreated")
            let scan = try DiskScanner(policy: SafetyPolicy(home: home)).scanKnownCaches()
            let moved = CleanupLog.Entry.Moved(path: CleanupLog.display(cache), bytes: 9000)
            let previous = CleanupLog.Entry(date: before, action: "清理", moved: [moved], failedCount: 0)
            #expect(CleanupLog.recreatedCacheCount(in: scan.items, entries: [previous]) == 1)
            let newer = CleanupLog.Entry(date: Date().addingTimeInterval(1), action: "清理", moved: [moved], failedCount: 0)
            #expect(CleanupLog.recreatedCacheCount(in: scan.items, entries: [newer]) == 0)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["QINGO_READONLY_QUICK_SCAN"] == "1"))
    func readOnlyQuickScanBenchmark() throws {
        let policy = SafetyPolicy()
        let start = Date()
        let result = try DiskScanner(policy: policy).scanKnownCaches()
        let caches = result.items.filter(\.canTrash)
        let parts = Dictionary(grouping: caches) { item -> String in
            if let browser = BrowserCaches.owner(of: item.url, home: policy.home) {
                return NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID).isEmpty
                    ? "browser_eligible" : "browser_requires_exit"
            }
            if Leftovers.browser(of: item.url) != nil { return "old_signing_copies" }
            return "other_caches"
        }
        for (category, items) in parts.sorted(by: { $0.key < $1.key }) {
            print("QINGO_BENCHMARK \(category) count=\(items.count) allocated_estimate=\(ScanStore.cleanupSum(items)) logical=\(ScanStore.sum(items))")
        }
        print("QINGO_BENCHMARK scanned=\(result.scannedCount) skipped=\(result.skippedCount) seconds=\(Date().timeIntervalSince(start))")
    }

    private func cache(_ home: URL, _ relative: String) throws -> URL {
        let url = home.appending(path: relative).standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data([1]).write(to: url.appending(path: "data"))
        return CanonicalPath.url(url)
    }

    private func withHome(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(CanonicalPath.url(root))
    }
}
