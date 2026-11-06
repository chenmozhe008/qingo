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

/// 第三块：iOS 固件进一键清理、iPhone 备份要确认、已装 App 的安装包写明「已安装」
struct IOSDataTests {
    private func home() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return CanonicalPath.url(home)
    }

    @Test func firmwareIsCleanableAndBackupNeedsConfirmation() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let firmware = home.appending(path: "Library/iTunes/iPhone Software Updates")
        try FileManager.default.createDirectory(at: firmware, withIntermediateDirectories: true)
        let backup = home.appending(path: "Library/Application Support/MobileSync/Backup/00008110-001A2B3C4D5E")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let info: NSDictionary = ["Device Name": "小明的 iPhone", "Last Backup Date": Date(timeIntervalSince1970: 1_700_000_000)]
        info.write(to: backup.appending(path: "Info.plist"), atomically: true)
        let policy = SafetyPolicy(home: home)
        #expect(policy.cacheDescription(for: firmware, isDirectory: true) != nil)
        #expect(policy.quickScanLocations.contains { CanonicalPath.url($0) == CanonicalPath.url(firmware) })
        // A backup is never a one-click cache; it is a decision with its device named.
        #expect(policy.cacheDescription(for: backup, isDirectory: true) == nil)
        #expect(policy.reviewDescription(for: backup, isDirectory: true)?.contains("小明的 iPhone") == true)
        let item = ScanItem(id: backup, url: backup, kind: .review, risk: .c, bytes: 1, note: "", canTrash: false,
                            identity: FileIdentity(device: 1, inode: 1))
        #expect(policy.decisionNote(for: item) != nil)
        #expect(ItemFilter.large.contains(item))
        // A folder next to the backups without Info.plist is not a backup.
        let stray = home.appending(path: "Library/Application Support/MobileSync/Backup/stray")
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        #expect(policy.iosBackup(stray) == nil)
    }
}

struct InstallerMatchTests {
    @Test func namesMatchInstalledAppsOnlyByWholeWords() throws {
        func match(_ name: String) -> String? { InstallerMatch.installedApp(for: URL(fileURLWithPath: "/tmp/\(name)")) }
        let installed = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        #expect(match("notion-calendar-1.2.dmg") != "Notion")
        #expect(match("random-tool-3.0.dmg") == nil)
        if installed.contains("WeChat.app") { #expect(match("WeChatMac_4.0.6.dmg") == "WeChat") }
        if installed.contains("Google Chrome.app") { #expect(match("googlechrome.dmg") == "Google Chrome") }
        if installed.contains("Keka.app") { #expect(match("Keka-1.4.dmg") == "Keka") }
    }
}
