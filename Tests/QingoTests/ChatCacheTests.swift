import Foundation
import Testing
@testable import Qingo

/// The chat apps' containers stay protected except for the cache folders `ChatCache` lists.
struct ChatCacheTests {
    private static let profile = "0123456789abcdef0123456789abcdef"

    @Test func previousCategoryNamesStillResolve() {
        #expect(ItemFilter.fromStored("大文件与工程") == .large)
        #expect(ItemFilter.fromStored("微信与企业微信") == .chat)
        #expect(ItemFilter.fromStored("可清理缓存") == .caches)
        #expect(ItemFilter.fromStored("剪辑与设计软件") == .creative)
    }

    /// A WeCom container with one cache folder of each kind plus the session database next to them.
    private func weComHome() throws -> (home: URL, data: URL) {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let data = home.appending(path: "Library/Containers/com.tencent.WeWorkMac/Data")
        let folders = ["Library/Caches", "Library/WebKit", "Documents/GYLog", "Documents/cefcache",
                       "Documents/Profiles/\(Self.profile)/Publishsys",
                       "Documents/Profiles/\(Self.profile)/Messages1"]
        for folder in folders {
            let url = data.appending(path: folder)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try writeSparse(url.appending(path: "data"), bytes: 2_000_000)
        }
        return (home, data)
    }

    @Test func cachesBecomeCleanableRowsAndHistoryDoesNot() throws {
        let (home, data) = try weComHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let policy = SafetyPolicy(home: home)
        let result = try DiskScanner(policy: policy).scanKnownCaches()
        func row(_ path: String) -> ScanItem? {
            let target = CanonicalPath.url(data.appending(path: path)).path
            return result.items.first { $0.url.path == target }
        }
        for path in ["Library/Caches", "Documents/GYLog"] {
            let item = try #require(row(path))
            #expect(item.kind == .cache && item.canTrash)
            #expect(item.bytes == 2_000_000)
        }
        // The embedded browser's image cache and the resource pack both come back only by downloading them
        // again (avatars reload, resource packs re-download): never offered as cleanup.
        for path in ["Documents/cefcache", "Library/WebKit", "Documents/Profiles/\(Self.profile)/Publishsys"] {
            #expect(row(path) == nil)
            #expect(policy.isProtected(data.appending(path: path)))
        }
        // The container itself and everything that is not a cache stays out of the cleanup list.
        #expect(policy.isProtected(data))
        #expect(policy.isProtected(data.appending(path: "Documents/Profiles/\(Self.profile)/Messages1")))
        #expect(row("Documents/Profiles/\(Self.profile)/Messages1") == nil)
        #expect(policy.cacheDescription(for: data.appending(path: "Documents/Profiles/\(Self.profile)/Messages1"),
                                        isDirectory: true) == nil)
    }

    @Test func trashRefusesTheChatDatabaseEvenWhenForged() throws {
        let (home, data) = try weComHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let policy = SafetyPolicy(home: home)
        let history = data.appending(path: "Documents/Profiles/\(Self.profile)/Messages1")
        let forged = ScanItem(id: history, url: history, kind: .cache, risk: .b, bytes: 2_000_000,
                              note: "", canTrash: true,
                              identity: try #require(TrashService.currentIdentity(history)))
        #expect(throws: TrashError.self) { try TrashService(policy: policy).moveToTrash(forged) }
        #expect(FileManager.default.fileExists(atPath: history.appending(path: "data").path))
    }

    @MainActor
    @Test func oneClickNeverPicksTheResourcePack() throws {
        let (home, data) = try weComHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ScanStore()
        store.minShownBytes = 0
        store.result = try DiskScanner(policy: SafetyPolicy(home: home)).scanKnownCaches()
        store.filter = .caches
        store.selectAllEligible()
        let pack = CanonicalPath.url(data.appending(path: "Documents/Profiles/\(Self.profile)/Publishsys")).path
        #expect(!store.shownItems.contains { $0.url.path == pack })
        #expect(!store.selectedCleanupItems.contains { $0.url.path == pack })
        #expect(store.selectedCleanupItems.contains { $0.url.path.hasSuffix("/Data/Library/Caches") })
    }

    @Test func profileFolderWithoutCachesAddsNothing() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let other = home.appending(path: "Library/Containers/com.tencent.WeWorkMac/Data/Documents/Profiles/\(Self.profile)/Messages1")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try writeSparse(other.appending(path: "Info.db"), bytes: 2_000_000)
        #expect(ChatCache.parts(home: home).isEmpty)
        #expect(try DiskScanner(policy: SafetyPolicy(home: home)).scanKnownCaches().items.isEmpty)
    }

    /// `app_data` carries the signed-in account: clearing it made WeChat ask for the QR code again (2026-10-31).
    @Test func weChatAccountDataIsNeverCleanable() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let data = home.appending(path: "Library/Containers/com.tencent.xinWeChat/Data")
        let folders = ["Documents/app_data", "Library/Caches", ".wxapplet",
                       "Documents/xwechat_files/wxid_test/cache", "Documents/xwechat_files/wxid_test/msg"]
        for folder in folders {
            let url = data.appending(path: folder)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try writeSparse(url.appending(path: "data"), bytes: 2_000_000)
        }
        let policy = SafetyPolicy(home: home)
        let cleanable = Set(ChatCache.parts(home: home).map { $0.url.standardizedFileURL.path })
        #expect(cleanable.contains(data.appending(path: "Library/Caches").standardizedFileURL.path))
        #expect(cleanable.contains(data.appending(path: ".wxapplet").standardizedFileURL.path))
        #expect(cleanable.contains(data.appending(path: "Documents/xwechat_files/wxid_test/cache").standardizedFileURL.path))
        #expect(!cleanable.contains(data.appending(path: "Documents/app_data").standardizedFileURL.path))
        #expect(policy.isProtected(data.appending(path: "Documents/app_data")))
        #expect(policy.isProtected(data.appending(path: "Documents/xwechat_files/wxid_test/msg")))

        let rows = try DiskScanner(policy: policy).scanKnownCaches().items
        let account = CanonicalPath.url(data.appending(path: "Documents/app_data")).path
        #expect(!rows.contains { $0.url.path == account })
    }

    /// Feishu keeps its data in Application Support and has no sandbox container; its logs and shader
    /// caches are cleanable, the embedded browser's profile (aha) is not.
    @Test func feishuLogsAndShadersAreCleanable() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appending(path: "Library/Application Support/LarkShell")
        let folders = ["sdk_storage/log", "GrShaderCache", "CodeCache",
                       "aha/users/abc/profile_explorer", "sdk_storage/abc/resources"]
        for folder in folders {
            let url = root.appending(path: folder)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try writeSparse(url.appending(path: "data"), bytes: 2_000_000)
        }
        let policy = SafetyPolicy(home: home)
        let cleanable = Set(ChatCache.parts(home: home).map { $0.url.standardizedFileURL.path })
        #expect(cleanable.contains(root.appending(path: "sdk_storage/log").standardizedFileURL.path))
        #expect(cleanable.contains(root.appending(path: "GrShaderCache").standardizedFileURL.path))
        #expect(!cleanable.contains(root.appending(path: "aha/users/abc/profile_explorer").standardizedFileURL.path))
        #expect(policy.isProtected(root.appending(path: "aha/users/abc/profile_explorer")))
        #expect(policy.isProtected(root.appending(path: "sdk_storage/abc/resources")))

        let rows = try DiskScanner(policy: policy).scanKnownCaches().items
        let log = CanonicalPath.url(root.appending(path: "sdk_storage/log")).path
        #expect(rows.contains { $0.url.path == log && $0.canTrash })
    }

    @Test func symlinkedFeishuCacheNeverExemptsItsTarget() throws {
        let home = CanonicalPath.url(FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appending(path: "Library/Application Support/LarkShell")
        let target = home.appending(path: "Documents/important")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "CodeCache"), withDestinationURL: target)
        let policy = SafetyPolicy(home: home)
        #expect(!policy.chatCacheRoots.contains(target.path))
        #expect(!ChatCache.parts(home: home).contains { $0.url.lastPathComponent == "CodeCache" })
        #expect(!policy.quickScanLocations.contains { CanonicalPath.url($0).path == target.path })
    }
}
