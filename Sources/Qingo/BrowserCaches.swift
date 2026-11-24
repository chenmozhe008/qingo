import AppKit

/// Browser profiles store state and cache in distinct locations. Only named cache leaves are candidates.
enum BrowserCaches {
    struct Browser {
        let name: String
        let bundleID: String
        let folder: String

        var roots: [String] { ["Library/Caches/" + folder, "Library/Application Support/" + folder] }
    }

    static let browsers = [
        Browser(name: "Google Chrome", bundleID: "com.google.Chrome", folder: "Google/Chrome"),
        Browser(name: "Google Chrome Beta", bundleID: "com.google.Chrome.beta", folder: "Google/Chrome Beta"),
        Browser(name: "Google Chrome Canary", bundleID: "com.google.Chrome.canary", folder: "Google/Chrome Canary"),
        Browser(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", folder: "Microsoft Edge"),
        Browser(name: "Brave", bundleID: "com.brave.Browser", folder: "BraveSoftware/Brave-Browser"),
        Browser(name: "Chromium", bundleID: "org.chromium.Chromium", folder: "Chromium")
    ]
    private static let firefox = Browser(name: "Firefox", bundleID: "org.mozilla.firefox", folder: "Firefox")
    private static let renderCaches: Set<String> = [
        "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache", "GraphiteDawnCache", "ShaderCache", "GrShaderCache"
    ]

    static func handles(_ path: String, home: URL) -> Bool {
        // In particular, Library/Caches/Google and BraveSoftware must not be picked as a whole.
        guard path.hasPrefix(home.path + "/Library/Caches/") ||
              path.hasPrefix(home.path + "/Library/Application Support/") else { return false }
        return (browsers + [firefox]).contains { browser in
            browser.roots.contains {
                let root = home.path + "/" + $0
                return path == root || path.hasPrefix(root + "/") || root.hasPrefix(path + "/")
            }
        }
    }

    static func owner(of url: URL, home: URL) -> Browser? {
        let path = url.path
        let name = url.lastPathComponent
        let parent = url.deletingLastPathComponent()
        if name == "cache2" && parent.deletingLastPathComponent().path == home.path + "/Library/Caches/Firefox/Profiles" {
            return firefox
        }
        for browser in browsers {
            for root in browser.roots.map({ home.path + "/" + $0 }) where path.hasPrefix(root + "/") {
                if parent.path == root, renderCaches.contains(name) { return browser }
                if parent.deletingLastPathComponent().path == root, isProfile(parent.lastPathComponent),
                   renderCaches.contains(name) || ["Cache", "Code Cache"].contains(name) { return browser }
            }
        }
        return nil
    }

    static func locations(home: URL) -> [URL] {
        let firefoxProfiles = home.appending(path: "Library/Caches/Firefox/Profiles")
        let firefoxCaches = CanonicalPath.isDirect(firefoxProfiles)
            ? ((try? FileManager.default.contentsOfDirectory(at: firefoxProfiles, includingPropertiesForKeys: nil,
                                                             options: [.skipsHiddenFiles])) ?? [])
                .map { $0.appending(path: "cache2") } : []
        return firefoxCaches + browsers.flatMap { browser in
            browser.roots.flatMap { relative -> [URL] in
                let root = home.appending(path: relative)
                guard CanonicalPath.isDirect(root) else { return [] }
                let fm = FileManager.default
                let profiles = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
                return ([root] + profiles.filter { isProfile($0.lastPathComponent) && CanonicalPath.isDirect($0) })
                    .flatMap { parent in
                        let names = parent.path == root.path ? renderCaches : renderCaches.union(["Cache", "Code Cache"])
                        return names.map { parent.appending(path: $0) }
                    }
            }
        }
    }

    private static func isProfile(_ name: String) -> Bool {
        name == "Default" || name == "Guest Profile" ||
            name.range(of: #"^Profile [0-9]+$"#, options: .regularExpression) != nil
    }
}
