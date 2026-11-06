import Foundation
import Testing
@testable import Qingo

/// 第二块「安全底座」：忽略名单、VPN / 密码管理类软件的数据默认不勾、上级目录是链接时不放行。
struct SafetyFoundationTests {
    private func item(_ path: String) -> ScanItem {
        let url = URL(fileURLWithPath: path)
        return ScanItem(id: url, url: url, kind: .cache, risk: .b, bytes: 5_000_000, note: "应用缓存，下次使用时自动重建。",
                        canTrash: true, identity: FileIdentity(device: 1, inode: 1))
    }

    @MainActor @Test func ignoredItemsLeaveTheListAndComeBack() {
        let store = ScanStore()
        store.restoreIgnored()
        defer { store.restoreIgnored() }
        let a = item("/Users/test/Library/Caches/com.example.a"), b = item("/Users/test/Library/Caches/com.example.b")
        store.result = ScanResult(root: URL(fileURLWithPath: "/Users/test"), isQuickScan: true, items: [a, b], totalBytes: 0,
                                  volumeTotalBytes: nil, volumeFreeBytes: nil, skippedCount: 0, scannedCount: 2, scannedAt: Date())
        store.selectAllEligible()
        store.ignore([a])
        #expect(store.eligibleItems.map(\.id) == [b.id])
        #expect(store.selectedCleanupItems.map(\.id) == [b.id])
        #expect(store.ignoredPaths.contains(a.url.path))
        store.restoreIgnored()
        #expect(Set(store.eligibleItems.map(\.id)) == [a.id, b.id])
    }

    @Test func vpnAndPasswordAppsAreRecognized() {
        for name in ["io.github.clash-verge-rev.clash-verge-rev", "com.west2online.ClashXPro", "com.nssurge.surge-mac",
                     "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.wireguard.macos",
                     "Clash Verge"] {
            #expect(SensitiveApps.matches(name), "\(name)")
        }
        for name in ["com.example.balloon", "com.tencent.xinWeChat", "com.google.Chrome", "com.example.mustache"] {
            #expect(!SensitiveApps.matches(name), "\(name)")
        }
    }

    @Test func sensitiveAppDataIsNotPickedOnUninstall() {
        func trace(_ path: String, _ kind: TraceKind) -> AppTrace {
            AppTrace(id: URL(fileURLWithPath: path), kind: kind, bytes: 1, identity: FileIdentity(device: 1, inode: 1), isDirectory: true)
        }
        let support = "/Users/test/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
        #expect(!AppUninstaller.pickedByDefault(trace(support, .support)))
        #expect(!AppUninstaller.pickedByDefault(trace("/Users/test/Library/Preferences/com.nssurge.surge-mac.plist", .preferences)))
        // The app bundle and its caches still go; ordinary apps keep their data picked.
        #expect(AppUninstaller.pickedByDefault(trace("/Users/test/Library/Caches/io.github.clash-verge-rev.clash-verge-rev", .caches)))
        #expect(AppUninstaller.pickedByDefault(trace("/Users/test/Library/Application Support/com.example.editor", .support)))
    }

    /// A cache folder whose parent is a link into a protected place is not cleanable (Mole: ancestor symlinks).
    @Test func linkedParentIntoProtectedRootIsRefused() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let ssh = home.appending(path: ".ssh/keys")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appending(path: "Library"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appending(path: "Library/Caches"), withDestinationURL: home.appending(path: ".ssh"))
        let policy = SafetyPolicy(home: home)
        #expect(policy.cacheDescription(for: home.appending(path: "Library/Caches/keys"), isDirectory: true) == nil)
    }
}
