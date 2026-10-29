import AppKit

/// Looks up the latest GitHub release at most once a day: the only time Qingo goes online. Reads one version
/// number, sends nothing about this Mac. Installing stays manual (the app is not notarized, so a self-replacing
/// update would trip Gatekeeper).
@MainActor
final class UpdateChecker: ObservableObject {
    struct Release: Equatable {
        let version: String
        let page: URL
    }

    @Published private(set) var available: Release?
    @Published var automatic = UserDefaults.standard.object(forKey: Keys.automatic) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(automatic, forKey: Keys.automatic)
            if automatic { checkIfDue() } else { available = nil }
        }
    }

    private static let latestAPI = URL(string: "https://api.github.com/repos/chenmozhe008/qingo/releases/latest")!

    private enum Keys {
        static let automatic = "updateAutoCheck"
        static let lastCheck = "updateLastCheck"
        static let latestVersion = "updateLatestVersion"
        static let latestPage = "updateLatestPage"
    }

    /// On launch: use the answer from today's check, or ask GitHub if the last one is a day old.
    func checkIfDue() {
        // `QINGO_PRETEND_UPDATE=9.9.9` shows the notice without a release (screenshots).
        if let pretend = ProcessInfo.processInfo.environment["QINGO_PRETEND_UPDATE"] {
            available = Release(version: pretend, page: AppInfo.repository.appending(path: "releases/latest"))
            return
        }
        guard automatic, !AppHome.isDemo, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: Keys.lastCheck) as? Date, Date().timeIntervalSince(last) < 86_400 {
            if let version = defaults.string(forKey: Keys.latestVersion),
               let page = defaults.string(forKey: Keys.latestPage).flatMap(URL.init(string:)) {
                show(Release(version: version, page: page))
            }
            return
        }
        Task { await check() }
    }

    /// Asks GitHub now. Returns nil when offline or GitHub did not answer.
    @discardableResult
    func check() async -> Release? {
        var request = URLRequest(url: Self.latestAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let release = Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, page: page)
        let defaults = UserDefaults.standard
        defaults.set(Date(), forKey: Keys.lastCheck)
        defaults.set(release.version, forKey: Keys.latestVersion)
        defaults.set(page.absoluteString, forKey: Keys.latestPage)
        show(release)
        return release
    }

    /// The menu's 检查更新…: asks now and says what it found.
    func checkFromMenu() {
        Task {
            let release = await check()
            let alert = NSAlert()
            if let release, Self.isNewer(release.version, than: AppInfo.version) {
                alert.messageText = "新版本 \(release.version) 可用"
                alert.informativeText = "当前版本 \(AppInfo.version)。下载后替换「应用程序」中的小清即可。"
                alert.addButton(withTitle: "前往下载")
                alert.addButton(withTitle: "以后")
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.page) }
            } else {
                alert.messageText = release == nil ? "无法检查更新" : "小清已是最新版本"
                alert.informativeText = release == nil ? "未能连接 GitHub，请检查网络后重试。" : "当前版本 \(AppInfo.version)。"
                alert.runModal()
            }
        }
    }

    func openDownload() {
        if let available { NSWorkspace.shared.open(available.page) }
    }

    private func show(_ release: Release) {
        available = automatic && Self.isNewer(release.version, than: AppInfo.version) ? release : nil
    }

    /// Numeric, part by part: 1.10.0 is newer than 1.9.2. A development build ("开发版") never asks.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let parse = { (value: String) in value.split(separator: ".").map { Int($0) } }
        let new = parse(candidate), old = parse(current)
        guard !new.contains(nil), !old.contains(nil), !old.isEmpty else { return false }
        for index in 0..<max(new.count, old.count) {
            let a = index < new.count ? new[index]! : 0
            let b = index < old.count ? old[index]! : 0
            if a != b { return a > b }
        }
        return false
    }
}
