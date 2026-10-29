import Foundation

/// What took the space since an earlier quick scan: each item that grew, by how much, and what is left unexplained
/// (space lost outside the quick scan's locations: downloads, projects, other apps).
struct SpaceGrowth: Sendable {
    struct Entry: Identifiable, Sendable {
        enum Source: Sendable {
            case item(ScanItem)
            /// WeChat / WeCom, measured read-only; its page explains how to clean in the app.
            case chat(ChatAppUsage)
        }

        let id: String
        let source: Source
        let growth: Int64
        /// Size now; cleaning an item moves all of it, not just the growth.
        let bytes: Int64
    }

    /// When the earlier quick scan ran.
    let since: Date
    /// Free space then and now, same measure on both sides; nil when the earlier result lacks it.
    let freeThen: Int64?
    let freeNow: Int64?
    /// Items that grew by at least `minEntryGrowth`, largest growth first.
    let entries: [Entry]
    /// Growth of every item, small ones included, for the unexplained remainder.
    let explained: Int64

    static let minEntryGrowth: Int64 = 200_000_000
    private static let gigabyte: Int64 = 1_073_741_824

    var freeDrop: Int64? {
        guard let freeThen, let freeNow else { return nil }
        return freeThen - freeNow
    }

    /// Space lost that no listed item accounts for.
    var unexplained: Int64 { max((freeDrop ?? 0) - explained, 0) }

    var entriesGrowth: Int64 { entries.reduce(0) { $0 + $1.growth } }

    /// Worth showing: a real jump, not the drift of everyday caches.
    var isNotable: Bool { entriesGrowth >= Self.gigabyte || (freeDrop ?? 0) >= 5 * Self.gigabyte }

    static func compare(baseline: ScanResult, current: ScanResult) -> SpaceGrowth {
        let before = Dictionary(baseline.items.map { ($0.url.standardizedFileURL.path, $0.bytes) }, uniquingKeysWith: max)
        var entries: [Entry] = []
        var explained: Int64 = 0
        for item in current.items {
            let growth = item.bytes - (before[item.url.standardizedFileURL.path] ?? 0)
            guard growth > 0 else { continue }
            explained += growth
            if growth >= minEntryGrowth {
                entries.append(Entry(id: item.id.path, source: .item(item), growth: growth, bytes: item.bytes))
            }
        }
        let chatsBefore = Dictionary(baseline.chatApps.map { ($0.id, $0.bytes ?? 0) }, uniquingKeysWith: max)
        for chat in current.chatApps {
            guard let bytes = chat.bytes, let old = chatsBefore[chat.id] else { continue }
            let growth = bytes - old
            guard growth > 0 else { continue }
            explained += growth
            if growth >= minEntryGrowth {
                entries.append(Entry(id: "chat:\(chat.id)", source: .chat(chat), growth: growth, bytes: bytes))
            }
        }
        // Compare like with like: Finder's figure when both results have it, else the raw free size.
        let free: (Int64?, Int64?) = baseline.availableBytes != nil && current.availableBytes != nil
            ? (baseline.availableBytes, current.availableBytes)
            : (baseline.volumeFreeBytes, current.volumeFreeBytes)
        return SpaceGrowth(since: baseline.scannedAt, freeThen: free.0, freeNow: free.1,
                           entries: entries.sorted { $0.growth > $1.growth }, explained: explained)
    }

    /// Which saved quick scan to compare against once a new one replaces `previous`. Comparing with a scan
    /// from minutes ago shows nothing, so a previous scan only becomes the baseline once it is 12 hours old;
    /// until then the older baseline stays.
    static func nextBaseline(current baseline: ScanResult?, previous: ScanResult?, now: Date) -> ScanResult? {
        guard let previous else { return baseline }
        guard let baseline else { return previous }
        return now.timeIntervalSince(previous.scannedAt) >= 12 * 3600 ? previous : baseline
    }

    /// "3 天内" / "5 小时内", for "N 天内可用空间减少 X".
    static func spanText(since: Date, now: Date = Date()) -> String {
        let hours = max(Int(now.timeIntervalSince(since) / 3600), 1)
        return hours < 36 ? "\(hours) 小时内" : "\(Int((Double(hours) / 24).rounded())) 天内"
    }
}

/// Free space measured by the background check every 30 minutes, kept for 14 days, for the trend chart.
enum SpaceHistory {
    struct Sample: Codable, Sendable {
        let date: Date
        let free: Int64
    }

    private static var url: URL { AppHome.resultsDirectory.appending(path: "space-history.json") }

    static func load() -> [Sample] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Sample].self, from: data)) ?? []
    }

    static func record(_ free: Int64, at date: Date = Date()) {
        let kept = load().filter { date.timeIntervalSince($0.date) < 14 * 86_400 }
        if let data = try? JSONEncoder().encode(kept + [Sample(date: date, free: free)]) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
