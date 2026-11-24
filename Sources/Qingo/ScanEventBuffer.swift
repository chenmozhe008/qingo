import Foundation

/// A scanner writes here without scheduling main-thread work for every discovered file.
/// Maintains deduplicated live byte totals and notable recent discoveries off the main thread
/// so the UI only pulls a tiny snapshot every ~160ms.
final class ScanEventBuffer: @unchecked Sendable {
    struct Batch {
        var progress: ScanProgress?
        var items: [ScanItem] = []
    }

    struct Snapshot: Sendable {
        var progress: ScanProgress?
        var cacheBytes: Int64 = 0
        var creativeBytes: Int64 = 0
        var largeBytes: Int64 = 0
        var notableCount: Int = 0
        var recentItems: [ScanItem] = []
        var hasUpdates: Bool = false
    }

    private let lock = NSLock()
    private var batch = Batch()
    private var latestProgress: ScanProgress?
    private var cacheTotals: [String: Int64] = [:]
    private var creativeTotals: [String: Int64] = [:]
    private var largeTotals: [String: Int64] = [:]
    private var notableItems: [ScanItem] = []
    private var dirty = false

    func record(_ progress: ScanProgress) {
        lock.withLock {
            batch.progress = progress
            latestProgress = progress
            dirty = true
        }
    }

    func record(_ item: ScanItem) {
        lock.withLock {
            batch.items.append(item)
            let path = item.url.path
            if item.kind == .cache && item.canTrash {
                let prefix = path + "/"
                for key in cacheTotals.keys where key.hasPrefix(prefix) {
                    cacheTotals.removeValue(forKey: key)
                }
                cacheTotals[path] = item.cleanupBytes
                dirty = true
            } else if CreativeApp.isReviewCache(item.url) || item.kind == .review {
                let prefix = path + "/"
                for key in creativeTotals.keys where key.hasPrefix(prefix) {
                    creativeTotals.removeValue(forKey: key)
                }
                creativeTotals[path] = item.bytes
                dirty = true
            } else if item.kind == .largeFile || item.kind == .project {
                largeTotals[path] = item.bytes
                dirty = true
            }

            if item.bytes >= 5_000_000 && (item.canTrash || item.kind == .largeFile || item.kind == .project || item.kind == .review) {
                if item.kind == .cache || item.kind == .review {
                    let prefix = path + "/"
                    notableItems.removeAll { $0.url.path.hasPrefix(prefix) }
                }
                notableItems.removeAll { $0.url.path == path }
                notableItems.append(item)
                dirty = true
            }
        }
    }

    func drain() -> Batch {
        lock.withLock {
            let pending = batch
            batch = Batch()
            return pending
        }
    }

    func drainSnapshot() -> Snapshot {
        lock.withLock {
            batch = Batch()
            guard dirty else { return Snapshot() }
            dirty = false
            let cacheSum = cacheTotals.values.reduce(Int64(0)) { sum, value in
                let add = sum.addingReportingOverflow(value)
                return add.overflow ? Int64.max : add.partialValue
            }
            let creativeSum = creativeTotals.values.reduce(Int64(0)) { sum, value in
                let add = sum.addingReportingOverflow(value)
                return add.overflow ? Int64.max : add.partialValue
            }
            let largeSum = largeTotals.values.reduce(Int64(0)) { sum, value in
                let add = sum.addingReportingOverflow(value)
                return add.overflow ? Int64.max : add.partialValue
            }
            let recent = Array(notableItems.suffix(6).reversed())
            return Snapshot(
                progress: latestProgress,
                cacheBytes: cacheSum,
                creativeBytes: creativeSum,
                largeBytes: largeSum,
                notableCount: notableItems.count,
                recentItems: recent,
                hasUpdates: true
            )
        }
    }
}
