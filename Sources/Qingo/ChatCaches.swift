import Foundation

/// Folders inside WeChat's, WeCom's and Feishu's data that hold only rebuildable data.
///
/// Everything else stays protected (`SafetyPolicy`): the chat history databases, the pictures and files
/// received in chats, WeCom's WeDrive, the account data, and the embedded browsers' image caches —
/// those come back only by downloading them again, so they are not offered as cleanup.
/// No folder here maps to a single conversation: the apps store files by type and month, not by chat.
enum ChatCache {
    struct Part: Sendable {
        let bundleID: String
        let appName: String
        /// What the row is called, e.g. 程序缓存.
        let title: String
        let note: String
        let url: URL
    }

    struct App: Sendable {
        let bundleID: String
        let name: String
        /// WeChat and WeCom live in a sandbox container; Feishu keeps its data in Application Support.
        let relativeRoot: String
        var isSandboxed: Bool { relativeRoot.hasPrefix("Library/Containers/") }
    }

    static let apps: [App] = [
        App(bundleID: "com.tencent.xinWeChat", name: "微信", relativeRoot: "Library/Containers/com.tencent.xinWeChat"),
        App(bundleID: "com.tencent.WeWorkMac", name: "企业微信", relativeRoot: "Library/Containers/com.tencent.WeWorkMac"),
        App(bundleID: "com.electron.lark", name: "飞书", relativeRoot: "Library/Application Support/LarkShell")
    ]

    /// Where an app keeps its `Data` folder (sandboxed) or its whole data folder (Feishu).
    static func root(of app: App, home: URL) -> URL { home.appending(path: app.relativeRoot) }

    static func dataRoot(of app: App, home: URL) -> URL {
        app.isSandboxed ? root(of: app, home: home).appending(path: "Data") : root(of: app, home: home)
    }

    static func app(for bundleID: String) -> App? { apps.first { $0.bundleID == bundleID } }

    /// The cache folders that exist right now.
    static func parts(home: URL) -> [Part] {
        var found: [Part] = []
        let home = CanonicalPath.url(home)
        for app in apps {
            let data = dataRoot(of: app, home: home)
            guard FileManager.default.fileExists(atPath: data.path) else { continue }
            for (relative, title, note) in layout(app) {
                let url = data.appending(path: relative)
                guard isDirectory(url) else { continue }
                found.append(Part(bundleID: app.bundleID, appName: app.name, title: title, note: note, url: url))
            }
            // WeChat 4 keeps the Moments / Channels cache inside each signed-in account, not in Library/Caches.
            guard app.bundleID == "com.tencent.xinWeChat" else { continue }
            let accounts = data.appending(path: "Documents/xwechat_files")
            for account in (try? FileManager.default.contentsOfDirectory(at: accounts, includingPropertiesForKeys: nil))?.sorted(by: { $0.path < $1.path }) ?? [] {
                let cache = account.appending(path: "cache")
                guard isDirectory(cache) else { continue }
                found.append(Part(bundleID: app.bundleID, appName: app.name, title: "朋友圈缓存",
                                  note: "朋友圈和视频号里的图片、视频缓存，下次查看时重新加载。", url: cache))
            }
        }
        return found
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        // Never turn a symlink (including one in a parent folder) into a cleanup exemption.
        return CanonicalPath.url(url).path == url.path &&
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Paths relative to the app's data folder. Only what the app rebuilds by itself.
    ///
    /// Deliberately missing, because clearing them has a visible cost:
    /// - WeChat's `Documents/app_data`: the signed-in account's own data — deleting it asks for the QR code
    ///   again on the next launch (reported 2026-10-31 after a cleanup).
    /// - WeCom's `Documents/cefcache`, `Library/WebKit` and Feishu's `aha/users/*/profile_explorer`: the
    ///   embedded browser's image cache. Deleting it makes every avatar and preview download again.
    private static func layout(_ app: App) -> [(String, String, String)] {
        switch app.bundleID {
        case "com.tencent.xinWeChat":
            return [("Library/Caches", "程序缓存", "微信运行时的临时数据，下次打开时自动重建。"),
                    (".wxapplet", "小程序缓存", "微信小程序的缓存，下次打开时自动重建。")]
        case "com.electron.lark":
            return [("sdk_storage/log", "日志", "飞书运行日志。"),
                    ("GrShaderCache", "图形缓存", "界面着色器缓存，下次打开时自动重建。"),
                    ("GraphiteDawnCache", "图形缓存", "界面着色器缓存，下次打开时自动重建。"),
                    ("ShaderCache", "图形缓存", "界面着色器缓存，下次打开时自动重建。"),
                    ("CodeCache", "程序缓存", "网页脚本编译缓存，下次打开时自动重建。")]
        default:
            return [("Library/Caches", "程序缓存", "企业微信运行时的临时数据，下次打开时自动重建。"),
                    ("Documents/GYLog", "日志", "运行日志，不包含聊天记录。"),
                    ("Documents/GYOssLog", "日志", "上传日志，不包含聊天记录。"),
                    ("Library/Application Support/WXWork/Log", "日志", "运行日志，不包含聊天记录。")]
        }
    }

    /// The part a path is, when it is one of these folders exactly — never a folder inside them.
    static func part(for url: URL, home: URL) -> Part? {
        let path = CanonicalPath.url(url).path
        return parts(home: home).first { CanonicalPath.url($0.url).path == path }
    }
}
