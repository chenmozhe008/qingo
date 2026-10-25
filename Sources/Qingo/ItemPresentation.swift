import AppKit

/// Human-readable title and icon for a scan item. Raw folder names like `_cacache`
/// or `com.tencent.meeting.UpdateServer` stay visible as the subtitle.
@MainActor
enum ItemPresentation {
    struct Info {
        let title: String
        /// App icon when the item belongs to an installed app.
        let icon: NSImage?
        /// SF Symbol used when there is no app icon.
        let symbol: String
    }

    private static var cache: [URL: Info] = [:]
    private static var appIcons: [String: NSImage] = [:]
    private static var fileIcons: [String: NSImage] = [:]
    private static let policy = SafetyPolicy()

    /// Finder icon of a file or bundle, cached: list rows ask for it on every redraw.
    static func icon(forPath path: String) -> NSImage {
        if let hit = fileIcons[path] { return hit }
        let icon = NSWorkspace.shared.icon(forFile: path)
        fileIcons[path] = icon
        return icon
    }

    /// Folder name → (title, symbol) for tool caches that have no app of their own.
    private static let known: [String: (String, String)] = [
        "_cacache": ("npm 缓存", "shippingbox.fill"),
        "uv": ("uv 包缓存", "shippingbox.fill"),
        "pip": ("pip 包缓存", "shippingbox.fill"),
        "Homebrew": ("Homebrew 下载", "mug.fill"),
        "org.swift.swiftpm": ("Swift 包缓存", "swift"),
        ".build": ("Swift 构建产物", "swift"),
        "__pycache__": ("Python 缓存", "chevron.left.forwardslash.chevron.right"),
        ".pytest_cache": ("pytest 缓存", "chevron.left.forwardslash.chevron.right"),
        ".mypy_cache": ("mypy 缓存", "chevron.left.forwardslash.chevron.right"),
        "node_modules": ("Node 依赖", "shippingbox.fill"),
        ".venv": ("Python 虚拟环境", "shippingbox.fill"),
        "venv": ("Python 虚拟环境", "shippingbox.fill"),
        "target": ("Rust 构建产物", "gearshape.2.fill"),
        "DerivedData": ("Xcode 构建缓存", "hammer.fill"),
        "recordings": ("闪电说旧录音", "waveform"),
        "Service Worker": ("Notion 离线缓存", "doc.text.fill")
    ]

    /// Folders whose name is not the app's bundle id or .app name.
    private static let aliases: [String: (bundleID: String, title: String)] = [
        "LarkShell": ("com.electron.lark", "飞书"),
        "Google": ("com.google.Chrome", "Google Chrome"),
        "Codex": ("com.openai.codex", "Codex"),
        "codex-runtimes": ("com.openai.codex", "Codex 运行时"),
        "Service Worker": ("notion.id", "Notion 离线缓存")
    ]

    static func info(for item: ScanItem) -> Info {
        if let hit = cache[item.id] { return hit }
        let value = resolve(item)
        cache[item.id] = value
        return value
    }

    /// Short part name inside a creative app group, e.g. "磁盘缓存".
    static func partTitle(for item: ScanItem) -> String {
        let name = item.name
        if name == "Render Files" { return "渲染文件 · \(item.url.deletingLastPathComponent().lastPathComponent)" }
        if name == "CacheClip" { return "渲染缓存 CacheClip" }
        if let model = policy.modelName(item.url) { return "模型 \(model)" }
        switch policy.historyKind(item.url) {
        case .conversations:
            // sessions/2026/08/14 → "8月14日"
            let parts = item.url.path.split(separator: "/").suffix(2).compactMap { Int($0) }
            return "\(SafetyPolicy.oldHistoryDays) 天前的对话记录 · " + (parts.count == 2 ? "\(parts[0])月\(parts[1])日" : item.name)
        case .images:
            return "\(SafetyPolicy.oldHistoryDays) 天前生成的图片 · " + (item.modified?.formatted(.dateTime.month().day()) ?? item.name)
        case nil:
            break
        }
        // A read-only row that is one known kind says what it is ("最近的对话记录"), otherwise "本地数据".
        if !item.canTrash {
            return DataBreakdown.isKnown(name, app: CreativeApp.of(item)) ? DataBreakdown.describe(name, app: CreativeApp.of(item)).0 : "本地数据"
        }
        if ["logs", "Logs", "log"].contains(name) || item.url.path.contains("/Library/Logs/") { return "日志" }
        if ["Crashpad", "crashpad"].contains(name) { return "崩溃报告" }
        if name == "cli-connector-cache" { return "连接器下载缓存" }
        if name.hasPrefix("Disk Cache") { return "磁盘缓存" }
        if name.hasPrefix("Media Cache") { return "媒体缓存" }
        if name == "Peak Files" { return "音频峰值文件" }
        if name == "DerivedDataCache" { return "引擎派生数据缓存" }
        if name == "codex-runtimes" { return "运行时缓存" }
        if ["Code Cache", "GPUCache", "CachedData", "CachedExtensionVSIXs"].contains(name) || name.hasSuffix("ShaderCache") || name.hasPrefix("Dawn") {
            return "界面缓存 · \(name)"
        }
        // An embedded webview's cache: its folder is an id like "wb-webview-c71f1ce8-…", which reads as garbage.
        if item.url.path.contains("/Partitions/") { return "内嵌网页缓存" }
        if name == "Cache", item.url.path.contains("/session/") { return "界面缓存 · Cache" }
        return "缓存"
    }

    static func appIcon(bundleID: String) -> NSImage? {
        guard !bundleID.isEmpty else { return nil }
        if let hit = appIcons[bundleID] { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        appIcons[bundleID] = icon
        return icon
    }

    static func runningOwner(of item: ScanItem) -> String? {
        if let app = CreativeApp.of(item) {
            let running = NSWorkspace.shared.runningApplications.first { running in
                guard let id = running.bundleIdentifier else { return false }
                return id == app.bundleID || app.apps.contains { id == $0 || id.hasPrefix($0 + ".") || (running.localizedName ?? "").hasPrefix($0) }
            }
            if let running { return running.localizedName ?? app.title }
        }
        let alias = aliases[item.name]?.bundleID
        let applicationURL = alias.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            ?? application(for: item.name)
        guard let applicationURL, let identifier = Bundle(url: applicationURL)?.bundleIdentifier else { return nil }
        return NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == identifier }?.localizedName
    }

    private static func resolve(_ item: ScanItem) -> Info {
        let name = item.name
        if let app = CreativeApp.of(item) {
            return Info(title: "\(app.title) \(partTitle(for: item))", icon: appIcon(bundleID: app.bundleID), symbol: app.group.symbol)
        }
        if let alias = aliases[name], let icon = appIcon(bundleID: alias.bundleID) {
            return Info(title: alias.title, icon: icon, symbol: "app.fill")
        }
        if item.kind == .largeFile || item.kind == .project {
            // Real document icons (Keynote, PPT, PSD, Final Cut library…) read better than a generic glyph.
            return Info(title: name, icon: NSWorkspace.shared.icon(forFile: item.url.path), symbol: symbol(for: item))
        }
        if item.kind == .cache, let app = application(for: name) {
            let title = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
            return Info(title: title, icon: NSWorkspace.shared.icon(forFile: app.path), symbol: "app.fill")
        }
        if let (title, symbol) = known[name] { return Info(title: title, icon: nil, symbol: symbol) }
        if name.hasSuffix("-updater") {
            return Info(title: "\(name.dropLast("-updater".count)) 更新包", icon: nil, symbol: "arrow.down.circle.fill")
        }
        return Info(title: name, icon: nil, symbol: symbol(for: item))
    }

    private static func symbol(for item: ScanItem) -> String {
        switch item.kind {
        case .cache: "arrow.triangle.2.circlepath"
        case .project: "film.stack.fill"
        case .largeFile: ["dmg", "pkg"].contains(item.url.pathExtension.lowercased()) ? "externaldrive.fill" : "doc.fill"
        case .review: "hand.raised.fill"
        case .folder: "folder.fill"
        }
    }

    private static func application(for name: String) -> URL? {
        // Bundle-id style folders: try the full id, then drop trailing parts
        // (com.tencent.meeting.UpdateServer → com.tencent.meeting).
        if name.contains("."), !name.hasPrefix(".") {
            var parts = name.split(separator: ".").map(String.init)
            while parts.count >= 3 {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: parts.joined(separator: ".")) { return url }
                parts.removeLast()
            }
            return nil
        }
        // Plain names like "Microsoft Edge".
        for directory in ["/Applications", NSHomeDirectory() + "/Applications"] {
            let url = URL(fileURLWithPath: directory).appending(path: name + ".app")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}
