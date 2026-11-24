import Foundation

/// Generic Chromium / Electron / CEF cache detector for everyday desktop apps.
///
/// Automatically discovers regenerable rendering & HTTP caches inside:
/// - `~/Library/Application Support/<App>/` (and `Partitions/<partition>/`)
/// - `~/Library/Containers/<bundle>/Data/Library/Application Support/<App>/`
///
/// Safety invariants:
/// - Skips `BrowserCaches`, `ChatCache`, `SafetyPolicy.isProtected`, `com.apple.*`, and `SensitiveApps`.
/// - Only targets standard regenerable Chromium cache directories; never touches `Local Storage`,
///   `IndexedDB`, `Cookies`, `Session Storage`, or database files.
enum ElectronCaches {
    private static let safeLeafNames: Set<String> = [
        "Cache",
        "Code Cache",
        "GPUCache",
        "DawnCache",
        "DawnGraphiteCache",
        "DawnWebGPUCache",
        "GraphiteDawnCache",
        "ShaderCache",
        "GrShaderCache"
    ]

    private static let nestedLeafPaths: [String] = [
        "Service Worker/CacheStorage",
        "Service Worker/ScriptCache",
        "Crashpad/completed"
    ]

    private static let excludedChatBundleIDs: Set<String> = Set(ChatCache.apps.map(\.bundleID))

    static func cacheDirectories(home: URL, policy: SafetyPolicy? = nil) -> [URL] {
        var found: [URL] = []
        let fm = FileManager.default
        let support = home.appending(path: "Library/Application Support")
        if CanonicalPath.isDirect(support),
           let children = try? fm.contentsOfDirectory(at: support, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for appDir in children {
                let name = appDir.lastPathComponent
                guard CanonicalPath.isDirect(appDir),
                      !SensitiveApps.matches(name),
                      !BrowserCaches.handles(appDir.path, home: home),
                      CreativeApp.dataOwner(appDir, home: home) == nil,
                      !(policy?.isProtected(appDir) ?? false),
                      isDirectory(appDir) else { continue }
                collectLeaves(under: appDir, home: home, policy: policy, into: &found)
                let partitions = appDir.appending(path: "Partitions")
                if CanonicalPath.isDirect(partitions), isDirectory(partitions),
                   let partitionDirs = try? fm.contentsOfDirectory(at: partitions, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                    for part in partitionDirs where CanonicalPath.isDirect(part) && isDirectory(part) {
                        collectLeaves(under: part, home: home, policy: policy, into: &found)
                    }
                }
            }
        }

        let containers = home.appending(path: "Library/Containers")
        if CanonicalPath.isDirect(containers),
           let ids = try? fm.contentsOfDirectory(at: containers, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for container in ids {
                let id = container.lastPathComponent
                guard SandboxCaches.isEligibleContainerName(id),
                      !excludedChatBundleIDs.contains(id),
                      !SensitiveApps.matches(id),
                      CanonicalPath.isDirect(container) else { continue }
                let appSupport = container.appending(path: "Data/Library/Application Support")
                guard CanonicalPath.isDirect(appSupport), isDirectory(appSupport),
                      let subApps = try? fm.contentsOfDirectory(at: appSupport, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
                    continue
                }
                for appDir in subApps where CanonicalPath.isDirect(appDir) && isDirectory(appDir) {
                    guard !(policy?.isProtected(appDir) ?? false),
                          CreativeApp.dataOwner(appDir, home: home) == nil else { continue }
                    collectLeaves(under: appDir, home: home, policy: policy, into: &found)
                }
            }
        }
        return Array(Set(found)).sorted { $0.path < $1.path }
    }

    static func cacheDescription(for url: URL, home: URL) -> String? {
        let path = CanonicalPath.url(url).path
        guard !BrowserCaches.handles(path, home: home) else { return nil }
        let name = url.lastPathComponent
        let parent = url.deletingLastPathComponent()
        let grandParent = parent.deletingLastPathComponent()

        let isNested = (parent.lastPathComponent == "Service Worker" && (name == "CacheStorage" || name == "ScriptCache"))
            || (parent.lastPathComponent == "Crashpad" && name == "completed")
        guard safeLeafNames.contains(name) || isNested else { return nil }

        let appRoot = isNested ? grandParent : parent
        guard isSupportedAppRoot(appRoot, home: home) else { return nil }
        let appName = displayOwnerName(for: appRoot, home: home)
        return "\(appName) 的界面与网页渲染缓存，不影响账号与本地数据，下次启动自动重建。"
    }

    private static func collectLeaves(under root: URL, home: URL, policy: SafetyPolicy?, into out: inout [URL]) {
        for leaf in safeLeafNames {
            let candidate = root.appending(path: leaf)
            if CanonicalPath.isDirect(candidate), isDirectory(candidate),
               !(policy?.isProtected(candidate) ?? false),
               !(policy?.hasProtectedDescendant(candidate) ?? false),
               !BrowserCaches.handles(candidate.path, home: home) {
                out.append(candidate)
            }
        }
        for rel in nestedLeafPaths {
            let candidate = root.appending(path: rel)
            if CanonicalPath.isDirect(candidate), isDirectory(candidate),
               !(policy?.isProtected(candidate) ?? false),
               !(policy?.hasProtectedDescendant(candidate) ?? false),
               !BrowserCaches.handles(candidate.path, home: home) {
                out.append(candidate)
            }
        }
    }

    private static func isSupportedAppRoot(_ root: URL, home: URL) -> Bool {
        let path = root.path
        let appSupportPrefix = home.appending(path: "Library/Application Support").path + "/"
        if path.hasPrefix(appSupportPrefix) {
            let rel = String(path.dropFirst(appSupportPrefix.count))
            let parts = rel.split(separator: "/").map(String.init)
            if parts.isEmpty || SensitiveApps.matches(parts[0]) { return false }
            // Either `<App>` or `<App>/Partitions/<Partition>`
            return parts.count == 1 || (parts.count == 3 && parts[1] == "Partitions")
        }
        let containersPrefix = home.appending(path: "Library/Containers").path + "/"
        if path.hasPrefix(containersPrefix) {
            let rel = String(path.dropFirst(containersPrefix.count))
            let parts = rel.split(separator: "/").map(String.init)
            // `<bundleID>/Data/Library/Application Support/<App>`
            guard parts.count == 5, parts[1] == "Data", parts[2] == "Library", parts[3] == "Application Support" else {
                return false
            }
            return SandboxCaches.isEligibleContainerName(parts[0]) && !SensitiveApps.matches(parts[0])
        }
        return false
    }

    private static func displayOwnerName(for appRoot: URL, home: URL) -> String {
        let appSupportPrefix = home.appending(path: "Library/Application Support").path + "/"
        if appRoot.path.hasPrefix(appSupportPrefix) {
            let first = appRoot.path.dropFirst(appSupportPrefix.count).split(separator: "/").first.map(String.init)
            if let first, !first.isEmpty { return first }
        }
        return appRoot.lastPathComponent
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
