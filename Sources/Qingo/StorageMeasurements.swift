import Darwin
import Foundation

/// Allocated space visible in one directory tree. A partial result must not appear as an empty folder.
enum DirectoryOccupancy {
    static func bytes(at root: URL, missingIsEmpty: Bool = false) -> Int64? {
        var rootInfo = stat()
        if lstat(root.path, &rootInfo) != 0 {
            return missingIsEmpty && errno == ENOENT ? 0 : nil
        }
        guard (rootInfo.st_mode & S_IFMT) == S_IFDIR, CanonicalPath.isDirect(root) else { return nil }
        var readable = true
        guard let contents = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
            options: [], errorHandler: { _, _ in readable = false; return true }) else { return nil }
        var hardLinks = Set<UInt64>()
        var total: Int64 = 0
        for case let entry as URL in contents {
            if Task.isCancelled { return nil }
            var info = stat()
            guard lstat(entry.path, &info) == 0 else { readable = false; continue }
            guard info.st_dev == rootInfo.st_dev else {
                contents.skipDescendants()
                readable = false
                continue
            }
            guard (info.st_mode & S_IFMT) == S_IFREG else { continue }
            if info.st_nlink > 1, !hardLinks.insert(info.st_ino).inserted { continue }
            let blockBytes = Int64(info.st_blocks).multipliedReportingOverflow(by: 512)
            let sum = total.addingReportingOverflow(blockBytes.partialValue)
            guard !blockBytes.overflow, !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return readable ? total : nil
    }
}

struct VolumeSpaceReading: Codable, Equatable, Sendable {
    let uuid: String
    let mount: URL
    let label: String
    let available: Int64
    let measuredAt: Date

    static func read(at url: URL) -> Self? {
        // Network volumes can disappear or stall. This feature compares mounted local volumes by UUID.
        let keys: Set<URLResourceKey> = [.volumeURLKey, .volumeUUIDStringKey, .volumeLocalizedNameKey, .volumeIsLocalKey]
        let fresh = URL(fileURLWithPath: url.path)
        guard let values = try? fresh.resourceValues(forKeys: keys), values.volumeIsLocal == true,
              let id = values.volumeUUIDString, let mount = values.volume else { return nil }
        var info = statfs()
        guard statfs(mount.path, &info) == 0 else { return nil }
        let bytes = UInt64(info.f_bsize).multipliedReportingOverflow(by: info.f_bavail)
        guard !bytes.overflow, bytes.partialValue <= UInt64(Int64.max) else { return nil }
        return Self(uuid: id, mount: mount, label: values.volumeLocalizedName ?? mount.lastPathComponent,
                    available: Int64(bytes.partialValue), measuredAt: Date())
    }

    func change(since earlier: Self) -> Int64? {
        guard uuid == earlier.uuid, measuredAt >= earlier.measuredAt else { return nil }
        return available - earlier.available
    }
}

struct CleanupVolumeReading: Codable, Equatable, Identifiable, Sendable {
    let before: VolumeSpaceReading
    let afterMove: VolumeSpaceReading?
    var id: String { before.uuid }

    static func captureBefore(_ items: [ScanItem]) -> [UInt64: VolumeSpaceReading] {
        var seen = Set<UInt64>()
        var readings: [UInt64: VolumeSpaceReading] = [:]
        for item in items {
            guard let device = TrashService.currentIdentity(item.url)?.device, seen.insert(device).inserted else { continue }
            if let reading = VolumeSpaceReading.read(at: item.url) { readings[device] = reading }
        }
        return readings
    }

    static func captureAfter(_ before: [UInt64: VolumeSpaceReading], moved: [TrashedItem], purgedIDs: [ScanItem] = []) -> [Self] {
        let devices = Set(moved.map(\.item.identity.device) + purgedIDs.map(\.identity.device))
        return devices.compactMap { device -> Self? in
            guard let first = before[device] else { return nil }
            let next = VolumeSpaceReading.read(at: first.mount).flatMap { $0.change(since: first) == nil ? nil : $0 }
            return Self(before: first, afterMove: next)
        }.sorted { $0.before.mount.path < $1.before.mount.path }
    }
}

/// Finder-compatible available capacity is an IPC request. Never read it while building a view.
struct DisplayVolume: Sendable {
    let total: Int64
    let free: Int64
    let name: String

    static func read(at url: URL) -> Self? {
        let fresh = URL(fileURLWithPath: url.path)
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedNameKey]
        guard let values = try? fresh.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return Self(total: Int64(total), free: free, name: values.volumeLocalizedName ?? "磁盘")
    }

    static func externalLocations() -> [URL] {
        let keys: Set<URLResourceKey> = [.volumeIsBrowsableKey, .isSymbolicLinkKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"),
                          includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        return urls.filter { volume in
            guard volume.lastPathComponent != "Recovery",
                  let values = try? volume.resourceValues(forKeys: keys) else { return false }
            return values.isSymbolicLink != true && values.volumeIsBrowsable != false
        }
    }
}
