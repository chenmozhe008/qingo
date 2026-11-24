import Darwin
import Foundation

/// Sparkle and Electron updaters have a different lifecycle from regular regenerable app caches.
struct AppUpdateStaging: Sendable {
    let home: URL

    private let sparkle = "org.sparkle-project.Sparkle"
    private let safeCacheLeaves = ["Cache", "Code Cache", "GPUCache", "ShaderCache", "GrShaderCache"]

    func root(containing path: String) -> String? {
        let caches = home.path + "/Library/Caches/"
        let support = home.path + "/Library/Application Support/Caches/"
        if path.hasPrefix(caches) {
            let components = path.dropFirst(caches.count).split(separator: "/", omittingEmptySubsequences: true)
            guard let app = components.first else { return nil }
            if app.hasSuffix("-updater") || app.hasSuffix(".ShipIt") { return caches + app }
            if components.count > 1, components[1] == sparkle {
                return caches + app + "/" + sparkle
            }
        }
        if path.hasPrefix(support),
           let app = path.dropFirst(support.count).split(separator: "/").first,
           app.hasSuffix("-updater") || app.hasSuffix(".ShipIt") {
            return support + app
        }
        return nil
    }

    func note(for url: URL) -> String? {
        let path = CanonicalPath.url(url).path
        guard root(containing: path) == path else { return nil }
        return "应用更新暂存。可能包含待安装的更新，由对应应用管理。"
    }

    func protectedChild(of cache: URL) -> URL? {
        guard cache.deletingLastPathComponent().path == home.path + "/Library/Caches" else { return nil }
        let child = cache.appending(path: sparkle)
        var info = stat()
        // A symlink or an unreadable child is also enough to withhold the enclosing directory.
        return lstat(child.path, &info) == 0 || errno == EACCES || errno == EPERM ? child : nil
    }

    func cacheLeaf(_ url: URL) -> Bool {
        safeCacheLeaves.contains(url.lastPathComponent) && protectedChild(of: url.deletingLastPathComponent()) != nil
    }

    func splitCacheRoot(_ url: URL) -> [URL] {
        guard let child = protectedChild(of: url) else { return [url] }
        return [child] + safeCacheLeaves.map { url.appending(path: $0) }
    }
}
