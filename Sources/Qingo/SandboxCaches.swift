import Foundation

/// Discovers regenerable caches inside sandboxed app containers (`~/Library/Containers/<id>/Data/Library/Caches`).
///
/// Only touches the standard `Data/Library/Caches` directory of third-party sandboxed apps:
/// - Skips `com.apple.*` system containers to avoid touching OS-managed state.
/// - Skips chat apps handled by `ChatCache` (WeChat, WeCom) so they are never double-counted or mishandled.
/// - Requires direct, non-symlink paths and only runs when readable (typically with Full Disk Access).
enum SandboxCaches {
    private static let excludedBundleIDs: Set<String> = Set(ChatCache.apps.map(\.bundleID))

    static func cacheDirectories(home: URL) -> [URL] {
        let root = home.appending(path: "Library/Containers")
        guard CanonicalPath.isDirect(root),
              let containers = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        var results: [URL] = []
        for container in containers {
            let name = container.lastPathComponent
            guard isEligibleContainerName(name), CanonicalPath.isDirect(container) else { continue }
            let cacheDir = container.appending(path: "Data/Library/Caches")
            guard CanonicalPath.isDirect(cacheDir),
                  (try? cacheDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            results.append(cacheDir)
        }
        return results.sorted { $0.path < $1.path }
    }

    static func isEligibleContainerName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix(".") else { return false }
        if name.hasPrefix("com.apple.") || name.hasPrefix("systemgroup.com.apple.") { return false }
        if excludedBundleIDs.contains(name) { return false }
        return true
    }

    static func note(for url: URL, home: URL) -> String? {
        let path = CanonicalPath.url(url).path
        let prefix = home.appending(path: "Library/Containers").path + "/"
        guard path.hasPrefix(prefix), path.hasSuffix("/Data/Library/Caches") else { return nil }
        let rest = String(path.dropFirst(prefix.count))
        let parts = rest.split(separator: "/")
        guard parts.count == 4, parts[1] == "Data", parts[2] == "Library", parts[3] == "Caches" else { return nil }
        let bundleID = String(parts[0])
        guard isEligibleContainerName(bundleID) else { return nil }
        return "应用缓存，下次打开时自动重建。"
    }
}
