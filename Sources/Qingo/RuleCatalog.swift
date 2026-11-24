import Foundation

/// Data-driven declarative cleanup rule catalog for universal everyday Mac applications.
/// Supports loading external/community JSON rule packs while shipping a verified built-in catalog.
struct CleanupRule: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let category: String
    let cachePaths: [String]
    let note: String
    let highConfidence: Bool

    init(id: String, name: String, category: String = "universal", cachePaths: [String], note: String, highConfidence: Bool = false) {
        self.id = id
        self.name = name
        self.category = category
        self.cachePaths = cachePaths
        self.note = note
        self.highConfidence = highConfidence
    }
}

enum RuleCatalog {
    /// Parses a JSON array of `CleanupRule` definitions, rejecting any path traversal (`..`) or absolute paths.
    static func decode(from data: Data) throws -> [CleanupRule] {
        let decoded = try JSONDecoder().decode([CleanupRule].self, from: data)
        return decoded.compactMap { rule in
            let safePaths = rule.cachePaths.filter(isSafeRelativePath)
            guard !safePaths.isEmpty else { return nil }
            return CleanupRule(id: rule.id, name: rule.name, category: rule.category,
                               cachePaths: safePaths, note: rule.note, highConfidence: rule.highConfidence)
        }
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
        let parts = path.split(separator: "/")
        return !parts.contains("..") && !parts.contains(".")
    }

    /// Verified universal Mac application cache rules (communication, media, browsers, productivity, dev tools).
    static let universalRules: [CleanupRule] = [
        // 办公与通讯
        CleanupRule(id: "slack", name: "Slack", cachePaths: [
            "Library/Application Support/Slack/Cache",
            "Library/Application Support/Slack/Code Cache",
            "Library/Application Support/Slack/GPUCache",
            "Library/Application Support/Slack/Service Worker/CacheStorage"
        ], note: "Slack 的界面和网页缓存，不影响消息记录和登录状态。"),
        CleanupRule(id: "discord", name: "Discord", cachePaths: [
            "Library/Application Support/discord/Cache",
            "Library/Application Support/discord/Code Cache",
            "Library/Application Support/discord/GPUCache"
        ], note: "Discord 的界面与媒体缓存，下次启动自动重建。"),
        CleanupRule(id: "zoom", name: "Zoom", cachePaths: [
            "Library/Logs/zoom.us",
            "Library/Application Support/zoom.us/data/VirtualBkgnd_Default"
        ], note: "Zoom 的日志与默认虚拟背景缓存，可自动重建。"),
        CleanupRule(id: "dingtalk", name: "钉钉", cachePaths: [
            "Library/Application Support/DingTalkMac/Cache",
            "Library/Application Support/DingTalkMac/GPUCache",
            "Library/Application Support/DingTalkMac/Code Cache"
        ], note: "钉钉的界面缓存，不影响聊天记录和文件。"),
        CleanupRule(id: "tencent-meeting", name: "腾讯会议", cachePaths: [
            "Library/Logs/WeMeet",
            "Library/Application Support/com.tencent.meeting/Cache"
        ], note: "腾讯会议的运行日志与临时缓存，可安全清理。"),
        CleanupRule(id: "teams", name: "Microsoft Teams", cachePaths: [
            "Library/Application Support/Microsoft/Teams/Cache",
            "Library/Application Support/Microsoft/Teams/Code Cache",
            "Library/Application Support/Microsoft/Teams/GPUCache"
        ], note: "Microsoft Teams 的界面与代码缓存，不影响聊天数据。"),

        // 影音与音乐
        CleanupRule(id: "spotify", name: "Spotify", cachePaths: [
            "Library/Application Support/Spotify/PersistentCache/Storage"
        ], note: "Spotify 的在线播放缓存，不影响歌单与收藏。"),
        CleanupRule(id: "netease-music", name: "网易云音乐", cachePaths: [
            "Library/Application Support/NeteaseMusic/Cache",
            "Library/Application Support/NeteaseMusic/GPUCache"
        ], note: "网易云音乐的试听与界面缓存，不影响歌单与已下载歌曲。"),
        CleanupRule(id: "qq-music", name: "QQ 音乐", cachePaths: [
            "Library/Application Support/QQMusicMac/Cache"
        ], note: "QQ 音乐的在线播放缓存，不影响收藏和本地下载。"),
        CleanupRule(id: "bilibili", name: "哔哩哔哩", cachePaths: [
            "Library/Application Support/bilibili/Cache",
            "Library/Application Support/bilibili/Code Cache",
            "Library/Application Support/bilibili/GPUCache"
        ], note: "哔哩哔哩客户端的网页与渲染缓存，不影响离线缓存视频。"),

        // 笔记与效率
        CleanupRule(id: "obsidian", name: "Obsidian", cachePaths: [
            "Library/Application Support/obsidian/Cache",
            "Library/Application Support/obsidian/Code Cache",
            "Library/Application Support/obsidian/GPUCache"
        ], note: "Obsidian 的界面渲染缓存，不影响笔记库和插件。"),
        CleanupRule(id: "wps", name: "WPS Office", cachePaths: [
            "Library/Application Support/Kingsoft/office6/cache"
        ], note: "WPS Office 的界面缓存，不影响本地文档。"),
        CleanupRule(id: "raycast", name: "Raycast", cachePaths: [
            "Library/Caches/com.raycast.macos"
        ], note: "Raycast 的应用缓存，不影响快捷命令和设置。"),

        // 其他主流浏览器
        CleanupRule(id: "arc", name: "Arc", cachePaths: [
            "Library/Caches/company.thebrowser.Browser"
        ], note: "Arc 浏览器的网页缓存，不影响标签页和账号。"),
        CleanupRule(id: "vivaldi", name: "Vivaldi", cachePaths: [
            "Library/Caches/Vivaldi"
        ], note: "Vivaldi 浏览器的网页缓存，下次访问自动重建。"),

        // 开发与 API 工具
        CleanupRule(id: "postman", name: "Postman", cachePaths: [
            "Library/Application Support/Postman/Cache",
            "Library/Application Support/Postman/Code Cache",
            "Library/Application Support/Postman/GPUCache"
        ], note: "Postman 的界面缓存，不影响接口集合和环境变量。"),
        CleanupRule(id: "jetbrains", name: "JetBrains IDE", cachePaths: [
            "Library/Caches/JetBrains"
        ], note: "JetBrains 系列 IDE 的索引与构建缓存，下次打开项目会自动重建。", highConfidence: true),
        CleanupRule(id: "android-studio", name: "Android Studio", cachePaths: [
            "Library/Caches/Google/AndroidStudio"
        ], note: "Android Studio 的索引与编译缓存，下次打开项目会自动重建。", highConfidence: true),
        CleanupRule(id: "steam", name: "Steam", cachePaths: [
            "Library/Application Support/Steam/appcache/httpcache"
        ], note: "Steam 商店网页缓存，不影响已安装游戏与存档。")
    ]

    static func locations(home: URL, rules: [CleanupRule] = universalRules) -> [URL] {
        rules.flatMap { rule in
            rule.cachePaths.map { home.appending(path: $0) }
        }
    }

    static func match(for url: URL, home: URL, rules: [CleanupRule] = universalRules) -> CleanupRule? {
        let path = CanonicalPath.url(url).path
        for rule in rules {
            for rel in rule.cachePaths {
                if home.appending(path: rel).path == path {
                    return rule
                }
            }
        }
        return nil
    }
}
