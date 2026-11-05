import AppKit
import ServiceManagement
import UserNotifications

/// Warns when free space runs low, even while Qingo is closed: a user launch agent (~/Library/LaunchAgents) runs
/// `Qingo --check-space` every 30 minutes; clicking the notification opens Qingo and starts a quick scan.
enum SpaceAlert {
    static let checkArgument = "--check-space"
    private static let notificationID = "low-space"
    private static let gigabyte: Int64 = 1_073_741_824
    private static var agent: SMAppService { .agent(plistName: "io.github.chenmozhe008.qingo.space-check.plist") }

    private enum Keys {
        static let enabled = "spaceAlertEnabled"
        /// Free bytes and time of the last warning; absent while space is fine.
        static let lastFree = "spaceAlertLastFree"
        static let lastDate = "spaceAlertLastDate"
    }

    /// Notification Center throws outside an app bundle (unit tests, a bare `swift run`).
    private static var inAppBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Keys.enabled) }
    }

    /// Warn when space first runs low; again after a day, or once another 5 GB is gone.
    static func shouldWarn(free: Int64, threshold: Int64, lastFree: Int64?, lastDate: Date?, now: Date) -> Bool {
        guard free < threshold else { return false }
        guard let lastFree, let lastDate else { return true }
        return now.timeIntervalSince(lastDate) >= 86_400 || free <= lastFree - 5 * gigabyte
    }

    // MARK: Background check (no UI)

    static func runCheck() {
        guard inAppBundle, isEnabled,
              let values = try? AppHome.url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let measured = values.volumeAvailableCapacityForImportantUsage else { return }
        // `QINGO_PRETEND_FREE=<bytes>` checks the notification without filling the disk.
        let free = ProcessInfo.processInfo.environment["QINGO_PRETEND_FREE"].flatMap { Int64($0) } ?? measured
        let pretending = ProcessInfo.processInfo.environment["QINGO_PRETEND_FREE"] != nil
        let history = SpaceHistory.load()
        if !pretending { SpaceHistory.record(measured) }
        let defaults = UserDefaults.standard
        let threshold = MainView.lowSpaceBytes
        // Back above the line (with a 1 GB margin so hovering around it does not repeat): the next drop warns again.
        if free >= threshold + gigabyte {
            defaults.removeObject(forKey: Keys.lastFree)
            defaults.removeObject(forKey: Keys.lastDate)
            return
        }
        let lastFree = (defaults.object(forKey: Keys.lastFree) as? NSNumber)?.int64Value
        let lastDate = defaults.object(forKey: Keys.lastDate) as? Date
        guard shouldWarn(free: free, threshold: threshold, lastFree: lastFree, lastDate: lastDate, now: Date()) else { return }

        let content = UNMutableNotificationContent()
        content.title = "剩余空间较少"
        content.body = body(free: free, history: history, now: Date())
        content.sound = .default
        let posted = DispatchSemaphore(value: 0)
        // A fixed id replaces the previous warning instead of piling them up in Notification Center.
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notificationID, content: content, trigger: nil)) { error in
            if pretending { print("posted, error: \(String(describing: error))") }
            posted.signal()
        }
        _ = posted.wait(timeout: .now() + 10)
        if pretending {
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                print("authorization: \(settings.authorizationStatus.rawValue), alert style: \(settings.alertStyle.rawValue)")
                posted.signal()
            }
            _ = posted.wait(timeout: .now() + 10)
        }
        defaults.set(free, forKey: Keys.lastFree)
        defaults.set(Date(), forKey: Keys.lastDate)
    }

    /// "可用 8.2 GB，3 天内减少 23.1 GB。…" when the history shows a drop worth naming.
    static func body(free: Int64, history: [SpaceHistory.Sample], now: Date) -> String {
        let freeText = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
        // The oldest sample of the last three days, if it is at least half a day old.
        if let start = history.first(where: { now.timeIntervalSince($0.date) <= 3 * 86_400 }),
           now.timeIntervalSince(start.date) >= 12 * 3600, start.free - free >= 2 * gigabyte {
            let drop = ByteCountFormatter.string(fromByteCount: start.free - free, countStyle: .file)
            return "可用 \(freeText)，\(SpaceGrowth.spanText(since: start.date, now: now))减少 \(drop)。点按以扫描并查看原因。"
        }
        return "可用 \(freeText)。点按以开始快速扫描。"
    }

    // MARK: 普通用户级 LaunchAgent

    private static let agentLabel = "io.github.chenmozhe008.qingo.space-check"
    private static var agentFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents/\(agentLabel).plist")
    }

    /// App 不在了（已卸载）就把任务自己清掉，不留残余
    nonisolated static let agentScript = #"[ -x "$1" ] && exec "$1" --check-space; rm -f "$2"; launchctl bootout "gui/$(id -u)/$3""#

    /// 路径指向当前这份 App；App 被挪动或内容变了就重写并重新加载
    nonisolated static func agentPlist(executable: String, file: String) -> [String: Any] {
        ["Label": "io.github.chenmozhe008.qingo.space-check",
         "ProgramArguments": ["/bin/sh", "-c", agentScript, "qingo-space-check", executable, file, "io.github.chenmozhe008.qingo.space-check"],
         "RunAtLoad": true, "StartInterval": 1800, "ProcessType": "Background",
         "AssociatedBundleIdentifiers": "io.github.chenmozhe008.qingo"]
    }

    private static func launchctl(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func installLaunchAgent() {
        guard let executable = Bundle.main.executablePath,
              let data = try? PropertyListSerialization.data(fromPropertyList: agentPlist(executable: executable, file: agentFile.path), format: .xml, options: 0) else { return }
        let domain = "gui/\(getuid())"
        let loaded = launchctl(["print", "\(domain)/\(agentLabel)"])
        if loaded, (try? Data(contentsOf: agentFile)) == data { return }
        if loaded { _ = launchctl(["bootout", "\(domain)/\(agentLabel)"]) }
        try? FileManager.default.createDirectory(at: agentFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: agentFile, options: .atomic)) != nil else { return }
        _ = launchctl(["bootstrap", domain, agentFile.path])
    }

    private static func removeLaunchAgent() {
        _ = launchctl(["bootout", "gui/\(getuid())/\(agentLabel)"])
        try? FileManager.default.removeItem(at: agentFile)
    }

    // MARK: App side

    /// Keeps the launch agent in step with the setting. `userInitiated`: the menu toggle was just turned on,
    /// so a refused notification permission opens System Settings instead of failing silently.
    @MainActor static func sync(userInitiated: Bool = false) {
        if AppHome.isDemo || !inAppBundle { return }
        // 旧版用 SMAppService 注册的任务要求 App 有 Apple 开发者身份，发布包没有，一启动就被系统杀掉（Launch Constraint Violation）
        if agent.status != .notRegistered { try? agent.unregister() }
        guard isEnabled else {
            removeLaunchAgent()
            return
        }
        installLaunchAgent()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard !granted, userInitiated else { return }
            Task { @MainActor in
                if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=io.github.chenmozhe008.qingo") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    /// Set by `ScanStore`; a click that arrives before the store exists is kept in `openPending`.
    @MainActor static var onOpen: (() -> Void)?
    @MainActor static var openPending = false

    @MainActor static func notificationClicked() {
        if let onOpen { onOpen() } else { openPending = true }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Set before launch finishes, or the click that launched the app is never delivered.
        if Bundle.main.bundleURL.pathExtension == "app" { UNUserNotificationCenter.current().delegate = self }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { SpaceAlert.notificationClicked() }
    }
}
