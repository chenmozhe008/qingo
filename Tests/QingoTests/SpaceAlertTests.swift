import Foundation
import Testing
@testable import Qingo

/// When the low-space notification goes out: once per drop, again after a day or another 5 GB.
struct SpaceAlertTests {
    private let gb: Int64 = 1_073_741_824
    private let now = Date()

    @Test func warnsOnlyBelowThreshold() {
        #expect(!SpaceAlert.shouldWarn(free: 12 * gb, threshold: 10 * gb, lastFree: nil, lastDate: nil, now: now))
        #expect(SpaceAlert.shouldWarn(free: 8 * gb, threshold: 10 * gb, lastFree: nil, lastDate: nil, now: now))
    }

    @Test func doesNotRepeatWithinADay() {
        let hourAgo = now.addingTimeInterval(-3600)
        #expect(!SpaceAlert.shouldWarn(free: 7 * gb, threshold: 10 * gb, lastFree: 8 * gb, lastDate: hourAgo, now: now))
    }

    @Test func repeatsAfterADayOrAnotherFiveGigabytes() {
        let dayAgo = now.addingTimeInterval(-86_400)
        let hourAgo = now.addingTimeInterval(-3600)
        #expect(SpaceAlert.shouldWarn(free: 8 * gb, threshold: 10 * gb, lastFree: 8 * gb, lastDate: dayAgo, now: now))
        #expect(SpaceAlert.shouldWarn(free: 3 * gb, threshold: 10 * gb, lastFree: 8 * gb, lastDate: hourAgo, now: now))
    }
}

/// What the space-change report says grew, and which earlier scan it compares against.
struct SpaceGrowthTests {
    private let gb: Int64 = 1_000_000_000

    private func item(_ path: String, _ bytes: Int64) -> ScanItem {
        let url = URL(fileURLWithPath: path)
        return ScanItem(id: url, url: url, kind: .cache, risk: .a, bytes: bytes, note: "应用缓存，下次使用时自动重建。",
                        canTrash: true, identity: FileIdentity(device: 1, inode: 1))
    }

    private func result(_ items: [ScanItem], available: Int64?, free: Int64? = nil, at date: Date = Date(),
                        chats: [ChatAppUsage] = []) -> ScanResult {
        var value = ScanResult(root: URL(fileURLWithPath: "/Users/test"), isQuickScan: true, items: items, totalBytes: 0,
                               volumeTotalBytes: nil, volumeFreeBytes: free, skippedCount: 0, scannedCount: 0, scannedAt: date)
        value.chatApps = chats
        value.availableBytes = available
        return value
    }

    @Test func listsWhatGrewLargestFirst() {
        let before = result([item("/c/ae", 2 * gb), item("/c/uv", gb)], available: 31 * gb)
        let after = result([item("/c/ae", 16 * gb), item("/c/uv", gb + 100_000_000), item("/c/new", 3 * gb)], available: 8 * gb)
        let growth = SpaceGrowth.compare(baseline: before, current: after)
        #expect(growth.entries.map(\.id) == ["/c/ae", "/c/new"])
        #expect(growth.entries[0].growth == 14 * gb)
        #expect(growth.entries[0].bytes == 16 * gb)
        #expect(growth.freeDrop == 23 * gb)
        // 23 GB lost, 17.1 GB accounted for by items (small growth included).
        #expect(growth.unexplained == 23 * gb - 17_100_000_000)
        #expect(growth.isNotable)
    }

    @Test func countsChatAppsAndComparesLikeWithLike() {
        let before = result([], available: nil, free: 20 * gb, chats: [ChatAppUsage(id: "wechat", name: "微信", bytes: 10 * gb)])
        let after = result([], available: 5 * gb, free: 15 * gb, chats: [ChatAppUsage(id: "wechat", name: "微信", bytes: 13 * gb)])
        let growth = SpaceGrowth.compare(baseline: before, current: after)
        #expect(growth.entries.count == 1)
        #expect(growth.entries[0].growth == 3 * gb)
        // The earlier result has no Finder figure, so both sides use the raw free size.
        #expect(growth.freeDrop == 5 * gb)
    }

    @Test func everydayDriftIsNotNotable() {
        let before = result([item("/c/a", gb)], available: 20 * gb)
        let after = result([item("/c/a", gb + 300_000_000)], available: 19 * gb)
        #expect(!SpaceGrowth.compare(baseline: before, current: after).isNotable)
    }

    @Test func baselineMovesOnlyToScansHalfADayOld() {
        let now = Date()
        let old = result([], available: nil, at: now.addingTimeInterval(-3 * 86_400))
        let recent = result([], available: nil, at: now.addingTimeInterval(-3600))
        let dayOld = result([], available: nil, at: now.addingTimeInterval(-86_400))
        #expect(SpaceGrowth.nextBaseline(current: nil, previous: recent, now: now)?.scannedAt == recent.scannedAt)
        #expect(SpaceGrowth.nextBaseline(current: old, previous: recent, now: now)?.scannedAt == old.scannedAt)
        #expect(SpaceGrowth.nextBaseline(current: old, previous: dayOld, now: now)?.scannedAt == dayOld.scannedAt)
        #expect(SpaceGrowth.nextBaseline(current: old, previous: nil, now: now)?.scannedAt == old.scannedAt)
    }

    @Test func notificationNamesTheDropWhenHistoryShowsOne() {
        let now = Date()
        let history = [SpaceHistory.Sample(date: now.addingTimeInterval(-2 * 86_400), free: 31 * gb)]
        #expect(SpaceAlert.body(free: 8 * gb, history: history, now: now) == "可用 8 GB，2 天内减少 23 GB。点按以扫描并查看原因。")
        #expect(SpaceAlert.body(free: 8 * gb, history: [], now: now) == "可用 8 GB。点按以开始快速扫描。")
    }
}

struct UpdateVersionTests {
    @Test func comparesVersionsNumerically() {
        #expect(UpdateChecker.isNewer("1.10.0", than: "1.9.2"))
        #expect(UpdateChecker.isNewer("1.12.1", than: "1.12"))
        #expect(!UpdateChecker.isNewer("1.12.0", than: "1.12.0"))
        #expect(!UpdateChecker.isNewer("1.11.0", than: "1.12.0"))
        #expect(!UpdateChecker.isNewer("2.0.0", than: "开发版"))
    }
}
