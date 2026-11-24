import Foundation

/// Reads Playwright's registrations and browser manifests without invoking Playwright or executing package code.
enum PlaywrightPreview {
    enum State: Equatable, Sendable {
        case registered
        case unlisted
        case unknown
        case incomplete

        var title: String {
            switch self {
            case .registered: "已有登记使用"
            case .unlisted: "未找到引用"
            case .unknown: "登记不完整，需核实"
            case .incomplete: "安装标记缺失"
            }
        }
    }

    struct Entry: Identifiable, Sendable {
        let url: URL
        let bytes: Int64?
        let state: State
        var id: URL { url }
    }

    struct Result: Sendable {
        let root: URL
        let entries: [Entry]
        let registrations: Int
        let unreadableRegistrations: Int
        let isInstalling: Bool
        let customRoot: Bool
    }

    private struct Manifest: Decodable {
        struct Browser: Decodable {
            let name: String
            let revision: String
            let revisionOverrides: [String: String]?
        }
        let browsers: [Browser]
    }

    private static let names: Set<String> = [
        "chromium", "chromium_headless_shell", "chromium_tip_of_tree", "chromium_tip_of_tree_headless_shell",
        "firefox", "firefox_beta", "webkit", "ffmpeg", "winldd"
    ]

    static func scan(home: URL, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Result {
        let root = home.appending(path: "Library/Caches/ms-playwright")
        let override = environment["PLAYWRIGHT_BROWSERS_PATH"]
        let custom = override.map { !$0.isEmpty && $0 != root.path } ?? false
        let fm = FileManager.default
        do {
            _ = try fm.attributesOfItem(atPath: root.path)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
            return Result(root: root, entries: [], registrations: 0, unreadableRegistrations: 0,
                          isInstalling: false, customRoot: custom)
        }
        guard CanonicalPath.isDirect(root) else { throw ScanError.unreadable(root) }
        let registry = root.appending(path: ".links")
        let links = CanonicalPath.isDirect(registry)
            ? (try? fm.contentsOfDirectory(at: registry, includingPropertiesForKeys: nil)) : nil
        let installing = hasEntry(root.appending(path: "__dirlock"))

        var registered = Set<String>()
        var good = 0
        var bad = 0
        for link in links ?? [] {
            try Task.checkCancellation()
            guard let identifiers = readRegistration(link) else { bad += 1; continue }
            registered.formUnion(identifiers)
            good += 1
        }

        let folders = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                  options: [.skipsHiddenFiles])
        let entries = try folders.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { url -> Entry? in
                try Task.checkCancellation()
                let name = url.lastPathComponent
                guard isBrowserDirectory(name), CanonicalPath.isDirect(url),
                      try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { return nil }
                let state: State
                if registered.contains(name) {
                    state = .registered
                } else if installing || good == 0 || bad > 0 || custom {
                    state = .unknown
                } else if !CanonicalPath.isDirect(url.appending(path: "INSTALLATION_COMPLETE")) {
                    state = .incomplete
                } else {
                    state = .unlisted
                }
                return Entry(url: url, bytes: DirectoryOccupancy.bytes(at: url), state: state)
            }
        try Task.checkCancellation()
        // An install can start during the preview. Do not present new candidates from a changing registry.
        let installStarted = !installing && hasEntry(root.appending(path: "__dirlock"))
        let final = installStarted ? entries.map {
            Entry(url: $0.url, bytes: $0.bytes, state: $0.state == .unlisted ? .unknown : $0.state)
        } : entries
        return Result(root: root, entries: final, registrations: good, unreadableRegistrations: bad,
                      isInstalling: installing || installStarted, customRoot: custom)
    }

    private static func isBrowserDirectory(_ value: String) -> Bool {
        guard let dash = value.lastIndex(of: "-"), numericRevision(String(value[value.index(after: dash)...])) else { return false }
        let name = String(value[..<dash])
        if names.contains(name) { return true }
        return names.contains { name.hasPrefix($0 + "_special_") }
    }

    private static func numericRevision(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func readRegistration(_ url: URL) -> Set<String>? {
        guard CanonicalPath.isDirect(url), let data = smallFile(url, limit: 8192),
              let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              line.hasPrefix("/"), !line.contains("\n"), !line.contains("\0") else { return nil }
        let package = URL(fileURLWithPath: line)
        let manifest = package.appending(path: "browsers.json")
        guard let data = smallFile(manifest, limit: 256 * 1024),
              let browsers = try? JSONDecoder().decode(Manifest.self, from: data).browsers, !browsers.isEmpty else { return nil }
        var identifiers = Set<String>()
        for browser in browsers {
            let name = browser.name.replacingOccurrences(of: "-", with: "_")
            guard names.contains(name), numericRevision(browser.revision) else { continue }
            identifiers.insert(name + "-" + browser.revision)
            for (platform, revision) in browser.revisionOverrides ?? [:]
            where platform.hasPrefix("mac") && numericRevision(revision) {
                // Preserve both naming forms used by different registry generations.
                identifiers.insert(name + "-" + revision)
                identifiers.insert(name + "_special_" + platform + "-" + revision)
            }
        }
        return identifiers.isEmpty ? nil : identifiers
    }

    private static func smallFile(_ url: URL, limit: Int) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink == false,
              let length = values.fileSize, length > 0, length <= limit,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: limit + 1), bytes.count <= limit else { return nil }
        return bytes
    }

    private static func hasEntry(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }
}
