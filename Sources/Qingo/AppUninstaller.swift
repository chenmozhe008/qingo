import AppKit
import Darwin
import Foundation
import IOKit

struct InstalledApp: Identifiable, Codable, Sendable {
    /// The .app, or for a suite the folder holding it (/Applications/DaVinci Resolve), which goes as a whole.
    let id: URL
    let name: String
    let bundleID: String
    let version: String?
    var appBytes: Int64?
    var traceBytes: Int64?
    var lastUsed: Date?
    /// For a suite: its main app (name, icon, last use) and the bundle ids of every app in the folder.
    var mainApp: URL?
    var memberIDs: [String]?

    var totalBytes: Int64? { appBytes.map { $0 + (traceBytes ?? 0) } }
    /// The .app to read the icon and last use from.
    var appURL: URL { mainApp ?? id }
    var bundleIDs: [String] { memberIDs ?? [bundleID] }
}

/// Where an app left something. Each kind is one row group on the uninstall page.
enum TraceKind: Int, CaseIterable, Sendable {
    case app, support, caches, preferences, background, web, logs, toolData, projects, system

    var title: String {
        switch self {
        case .app: "App 本身"
        case .support: "应用支持文件"
        case .caches: "缓存"
        case .preferences: "偏好设置和窗口状态"
        case .background: "后台和登录项"
        case .web: "网页数据"
        case .logs: "日志"
        case .toolData: "工具数据"
        case .projects: "项目和素材"
        case .system: "系统支持文件"
        }
    }
}

struct AppTrace: Identifiable, Sendable {
    let id: URL
    let kind: TraceKind
    let bytes: Int64
    let identity: FileIdentity
    let isDirectory: Bool
    /// Last change of the item itself; apps touch their preferences, window state and caches whenever they run.
    var modified: Date? = nil
    var url: URL { id }
}

enum AppRecycle {
    static func permissionDenied(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain && [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(error.code) { return true }
        if error.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(error.code) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, permissionDenied(underlying) { return true }
        return (error.userInfo["NSUnderlyingErrors"] as? [NSError] ?? []).contains { permissionDenied($0) }
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func authorizedMove(from source: URL, to destination: URL, identity: FileIdentity) throws {
        let src = shellQuote(source.path)
        let dst = shellQuote(destination.path)
        let expected = "\(identity.device):\(identity.inode)"
        let command = "set -e; test \"$(/usr/bin/stat -f '%d:%i' \(src))\" = \(shellQuote(expected)); test ! -e \(dst) && test ! -L \(dst); /bin/mv -n \(src) \(dst); test ! -e \(src) && test ! -L \(src); test \"$(/usr/bin/stat -f '%d:%i' \(dst))\" = \(shellQuote(expected))"
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        try
            do shell script "\(escaped)" with prompt "小清需要管理员授权来移动你选择的应用。" with administrator privileges
            return "OK"
        on error messageText number errorNumber
            return "ERROR:" & errorNumber & ":" & messageText
        end try
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if process.terminationStatus != 0 || result != "OK" {
            let parts = result.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            let code = parts.count > 1 ? (Int(parts[1]) ?? -1) : -1
            let message = parts.count > 2 ? String(parts[2]) : "授权操作失败"
            throw NSError(domain: "Qingo.Authorization", code: code, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func authorizedTrash(_ source: URL, identity: FileIdentity) throws -> URL {
        let trash = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: source, create: false)
        guard let trashIdentity = TrashService.currentIdentity(trash), trashIdentity.device == identity.device else { throw TrashError.changed }
        let destination = trash.appendingPathComponent("小清-\(UUID().uuidString)-\(source.lastPathComponent)")
        try authorizedMove(from: source, to: destination, identity: identity)
        return destination
    }
}

/// A part an installed app runs without: a hardware utility, an installer it has finished with, a downloadable model.
struct AppSlimItem: Identifiable, Sendable {
    let id: URL
    let title: String
    let note: String
    let bytes: Int64
    let identity: FileIdentity
    var url: URL { id }
}

/// What can be freed without uninstalling. An app bundle itself stays whole: removing architectures or languages
/// from inside it breaks its signature, and the app can refuse to start. Listed only by exact, checked path.
enum AppSlimming {
    struct Part { let url: URL; let title: String; let note: String }

    /// Whether a Blackmagic device (Speed Editor, colour panel, capture box) is on USB right now.
    /// While one is, the tools that set it up are not offered: its owner plainly needs them.
    static func blackmagicHardwareConnected() -> Bool {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary? else { return false }
        matching["idVendor"] = 0x1EDB
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iterator) }
        let device = IOIteratorNext(iterator)
        defer { if device != 0 { IOObjectRelease(device) } }
        return device != 0
    }

    static func parts(for app: InstalledApp, home: URL, system: URL = URL(fileURLWithPath: "/"),
                      hardwareConnected: Bool = blackmagicHardwareConnected()) -> [Part] {
        switch app.bundleID {
        case "com.blackmagic-design.DaVinciResolve":
            let prereqs = system.appending(path: "Library/Application Support/Blackmagic Design/DaVinci Resolve/Prereqs")
            var parts = [Part(url: app.id.appending(path: "Blackmagic Remote Monitor.app"), title: "远程监看工具", note: "仅使用远程监看时需要"),
                         Part(url: app.id.appending(path: "DaVinci Resolve Manual.pdf"), title: "说明书副本", note: "应用内还有一份"),
                         Part(url: prereqs.appending(path: "blackmagic_raw_player_installer.tgz"), title: "RAW 播放器安装包", note: "安装时已使用，重新安装达芬奇时会放回")]
            if !hardwareConnected {
                parts += [Part(url: app.id.appending(path: "DaVinci Control Panels Setup.app"), title: "调色台设置工具", note: "仅连接调色台或剪辑键盘时需要，用于设置和升级固件"),
                          Part(url: app.id.appending(path: "Fairlight Studio Utility.app"), title: "Fairlight 设置工具", note: "仅连接 Fairlight 调音台时需要"),
                          Part(url: prereqs.appending(path: "davinci_panels.tgz"), title: "调色台驱动安装包", note: "安装时已使用，重新安装达芬奇时会放回")]
            }
            return parts
        case "com.lemon.lvpro":
            return [Part(url: home.appending(path: "Movies/JianyingPro/User Data/SupplysStore/local-asr-supplies"), title: "离线字幕识别模型",
                         note: "下次使用离线字幕识别时需重新下载")]
        case _ where app.bundleID.hasPrefix("com.adobe.AfterEffects"):
            // A version whose app is gone: only plug-ins an installer put there remain, and no After Effects loads them.
            let applications = app.id.deletingLastPathComponent()
            let names = (try? FileManager.default.contentsOfDirectory(atPath: applications.path)) ?? []
            return names.filter { $0.hasPrefix("Adobe After Effects ") && $0 != app.id.lastPathComponent }.compactMap { name in
                let folder = applications.appending(path: name)
                let inside = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }
                guard inside == ["Plug-ins"] else { return nil }
                return Part(url: folder, title: "\(name.replacingOccurrences(of: "Adobe After Effects ", with: "AE ")) 遗留插件", note: "该版本已卸载，这些插件不再加载")
            }
        default:
            return []
        }
    }

    /// Where the app itself clears what it generated while working.
    static func inAppPath(for app: InstalledApp) -> String? {
        if app.bundleID == "com.blackmagic-design.DaVinciResolve" { return "播放 → 删除渲染缓存" }
        if app.bundleID == "com.lemon.lvpro" { return "全局设置 → 缓存管理" }
        if app.bundleID.hasPrefix("com.adobe.AfterEffects") { return "编辑 → 清理 → 所有内存与磁盘缓存" }
        return nil
    }

    /// Why the app stays large after everything else is gone.
    static func whyLarge(for app: InstalledApp) -> String? {
        if app.bundleID == "com.blackmagic-design.DaVinciResolve" { return "其余是程序和内置资源，不能单独删除。" }
        if app.bundleID == "com.lemon.lvpro" { return "其余是剪辑引擎和内置组件，不能单独删除。" }
        if app.bundleID.hasPrefix("com.adobe.AfterEffects") { return "其余是程序、内置效果和预设，不能单独删除。" }
        return nil
    }
}

/// Apps of one product line, placed next to each other in the list. Named one by one: a shared vendor prefix is not enough
/// (com.tencent is WeChat, WeCom and Tencent Meeting; com.microsoft is Office and Edge).
enum AppFamily {
    private static let office: Set<String> = ["com.microsoft.Word", "com.microsoft.Excel", "com.microsoft.Powerpoint",
                                              "com.microsoft.onenote.mac", "com.microsoft.Outlook"]

    static func name(of app: InstalledApp) -> String? {
        if app.bundleID.hasPrefix("com.blackmagic-design.") { return "Blackmagic Design" }
        if app.bundleID.hasPrefix("com.adobe.") || app.name.hasPrefix("Adobe ") { return "Adobe" }
        if office.contains(app.bundleID) { return "Microsoft Office" }
        return nil
    }
}

/// 删了会丢订阅、登录或密码库的软件：VPN / 代理、密码管理（照 Mole 审计文档的 Protected Categories）。
/// 卸载时它的数据和设置默认不勾，「已删除应用的残留」里默认不选：重装后要重新导入订阅、密码库。
enum SensitiveApps {
    static let names = ["clash", "mihomo", "v2ray", "xray", "shadowsocks", "shadowrocket", "surge", "quantumult", "stash", "loon",
                        "sing-box", "singbox", "nekoray", "hiddify", "tailscale", "wireguard", "openvpn", "tunnelblick", "expressvpn",
                        "nordvpn", "astrill", "1password", "bitwarden", "keepass", "keepassxc", "lastpass", "enpass", "dashlane",
                        "macpass", "authy", "authenticator", "onepassword"]

    /// 按 bundle id / 文件夹名的各段开头比，避免 balloon 被当成 loon
    static func matches(_ name: String) -> Bool {
        let parts = name.lowercased().split(whereSeparator: { ".-_ ".contains($0) }).map(String.init)
        let joined = name.lowercased()
        return names.contains { token in parts.contains { $0.hasPrefix(token) } || (token.contains("-") && joined.contains(token)) }
    }
}

/// Leftovers of an app that is gone, merged by bundle id ("com.vendor.app").
struct OrphanGroup: Identifiable, Sendable {
    let id: String
    let traces: [AppTrace]
    var bytes: Int64 { traces.reduce(0) { $0 + $1.bytes } }
}

/// Finds what an app keeps in ~/Library, and what is left of apps that are gone.
/// Only fixed Library folders are searched, by exact bundle id or app name; Containers are never read.
struct AppUninstaller: Sendable {
    let policy: SafetyPolicy

    private var library: URL { policy.home.appending(path: "Library") }

    // MARK: Installed apps

    func installedApps() -> [InstalledApp] {
        let roots = [URL(fileURLWithPath: "/Applications"), policy.home.appending(path: "Applications")]
        var apps: [InstalledApp] = []
        for root in roots {
            for child in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                if child.pathExtension == "app" {
                    if let app = single(child) { apps.append(app) }
                } else if (try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map({ $0.isDirectory == true && $0.isSymbolicLink != true }) == true {
                    // A folder of apps (/Applications/DaVinci Resolve: the editor, its uninstaller, utilities) is one
                    // product: listed once, removed as a whole folder.
                    let bundles = ((try? FileManager.default.contentsOfDirectory(at: child, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "app" }
                    if bundles.count == 1, let app = single(bundles[0]) {
                        apps.append(app)
                    } else if let suite = suite(child, bundles: bundles) {
                        apps.append(suite)
                    }
                }
            }
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func single(_ url: URL) -> InstalledApp? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !id.hasPrefix("com.apple."), id != Bundle.main.bundleIdentifier,
              !Self.isBackgroundOnly(bundle), !Self.isRuntimeLauncher(id) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        return InstalledApp(id: url, name: name, bundleID: id, version: bundle.infoDictionary?["CFBundleShortVersionString"] as? String)
    }

    /// A helper with no interface at all (LSBackgroundOnly), started by something else: not an app anyone
    /// opens or would think to uninstall, and removing it breaks whatever relies on it (e.g. a helper that
    /// holds a permission for an automation). Menu-bar apps (LSUIElement) have an interface and stay listed.
    static func isBackgroundOnly(_ bundle: Bundle) -> Bool {
        let value = bundle.infoDictionary?["LSBackgroundOnly"]
        return (value as? Bool) == true || (value as? String) == "1" || (value as? String)?.uppercased() == "YES"
    }

    /// Python's IDLE and launcher: the interpreter scripts run on lives in /Library/Frameworks, so the launcher's
    /// "last used" says nothing about the runtime, and removing the folder frees nothing and leaves the runtime behind.
    static func isRuntimeLauncher(_ id: String) -> Bool { id.hasPrefix("org.python.") }

    private func suite(_ folder: URL, bundles: [URL]) -> InstalledApp? {
        let members = bundles.compactMap { url -> (URL, Bundle, String)? in
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !id.hasPrefix("com.apple.") else { return nil }
            return (url, bundle, id)
        }
        guard !members.isEmpty, !members.allSatisfy({ Self.isRuntimeLauncher($0.2) }) else { return nil }
        // The main app is the one named like the folder, else the largest that is not an uninstaller.
        let name = folder.lastPathComponent
        let candidates = members.filter { !$0.0.lastPathComponent.lowercased().contains("uninstall") }
        guard let main = candidates.first(where: { $0.0.deletingPathExtension().lastPathComponent == name })
                ?? candidates.max(by: { Self.size(of: $0.0) < Self.size(of: $1.0) }) ?? members.first else { return nil }
        return InstalledApp(id: folder, name: name, bundleID: main.2, version: main.1.infoDictionary?["CFBundleShortVersionString"] as? String,
                            mainApp: main.0, memberIDs: members.map(\.2))
    }

    /// Spotlight's last-used date when it has one (often it does not), or the newest change the app made
    /// to its own preferences, window state, caches or support files, whichever is later.
    static func lastUsed(_ url: URL, traces: [AppTrace]) -> Date? {
        let spotlight = NSMetadataItem(url: url)?.value(forAttribute: "kMDItemLastUsedDate") as? Date
        let touched = traces.filter { [.support, .caches, .preferences, .web].contains($0.kind) }.compactMap(\.modified).max()
        if let date = [spotlight, touched].compactMap({ $0 }).max() { return date }
        // Sandboxed apps keep everything in their container, which is not read here: fall back to when the
        // executable was last read, which launching it does.
        var info = stat()
        guard let executable = Bundle(url: url)?.executableURL, lstat(executable.path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_atimespec.tv_sec))
    }

    // MARK: Traces of one app

    /// Everything to move when uninstalling: the bundle first, then ~/Library leftovers.
    func traces(for app: InstalledApp) -> [AppTrace] {
        var found: [(URL, TraceKind)] = [(app.id, .app)]
        let ids = app.bundleIDs
        // Executable names are skipped: every Electron app's is "Electron", and its folders are shared.
        let generic: Set<String> = ["electron", "chromium", "helper", "app", "application", "launcher", "updater"]
        let names = Set(ids + [app.name, Bundle(url: app.appURL)?.infoDictionary?["CFBundleName"] as? String].compactMap { $0 }
            .filter { $0.count > 2 && !generic.contains($0.lowercased()) })
        let tool = CreativeApp.allCases.first { $0.isInstalled && ids.contains($0.bundleID) }
        // An editor's own data is the user's work, not a tool's settings: kept unless asked for.
        let dataKind: TraceKind = tool.map { [.video, .design].contains($0.group) } == true ? .projects : .toolData
        for name in names {
            let support = library.appending(path: "Application Support/\(name)")
            found.append((support, tool == nil ? .support : dataKind))
            found.append((library.appending(path: "Caches/\(name)"), .caches))
            found.append((library.appending(path: "Logs/\(name)"), .logs))
        }
        for id in ids {
            found += namespaced(in: "Preferences", id: id, suffix: ".plist").map { ($0, .preferences) }
            found.append((library.appending(path: "Saved Application State/\(id).savedState"), .preferences))
            found += [library.appending(path: "HTTPStorages/\(id)"), library.appending(path: "HTTPStorages/\(id).binarycookies"),
                      library.appending(path: "WebKit/\(id)"), library.appending(path: "Cookies/\(id).binarycookies")].map { ($0, .web) }
        }
        found += launchAgents(for: app).map { ($0, .background) }
        // A recognized tool's own data roots (conversations, models…): listed, never picked by default.
        if let tool {
            found += tool.roots.map { (policy.home.appending(path: $0), dataKind) }
            for prefix in [""] + CreativeApp.vendorFolders.map({ $0 + "/" }) {
                found += tool.folders.map { (library.appending(path: "Application Support/\(prefix)\($0)"), dataKind) }
                found += tool.folders.map { (library.appending(path: "Caches/\(prefix)\($0)"), .caches) }
            }
        }
        found += Self.systemFolders(for: app).map { ($0, .system) }
        // Grouped by kind, the app first and a tool's own data last.
        return measured(found).enumerated().sorted { ($0.element.kind.rawValue, $0.offset) < ($1.element.kind.rawValue, $1.offset) }.map(\.element)
    }

    /// What the installer put outside ~/Library, by exact path. Resolve's holds only its own parts, but its LUT folder
    /// is also where people add their own LUTs, so this is never picked by default.
    static func systemFolders(for app: InstalledApp) -> [URL] {
        guard app.bundleID == "com.blackmagic-design.DaVinciResolve" else { return [] }
        return [URL(fileURLWithPath: "/Library/Application Support/Blackmagic Design")]
    }

    /// Whether the app keeps a sandbox container. Only checks existence; reading it would ask the user for permission.
    func hasContainer(_ app: InstalledApp) -> Bool {
        app.bundleIDs.contains { FileManager.default.fileExists(atPath: library.appending(path: "Containers/\($0)").path) }
    }

    /// Uninstalling means not wanting the app any more: what it left goes (用户定，2026-10-25), and all of it lands in
    /// the Trash. Projects and drafts stay unless picked (用户定，2026-11-03): emptying the Trash would lose the work.
    static func pickedByDefault(_ trace: AppTrace) -> Bool {
        if [.projects, .system].contains(trace.kind) { return false }
        // VPN / 代理 / 密码管理的数据和设置里是订阅和密码库：要删得自己勾
        if [.support, .toolData, .preferences].contains(trace.kind), SensitiveApps.matches(trace.url.lastPathComponent) { return false }
        return true
    }

    private func namespaced(in folder: String, id: String, suffix: String) -> [URL] {
        let directory = library.appending(path: folder)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0 == id + suffix || ($0.hasPrefix(id + ".") && $0.hasSuffix(suffix)) }.map { directory.appending(path: $0) }
    }

    private func launchAgents(for app: InstalledApp) -> [URL] {
        let directory = library.appending(path: "LaunchAgents")
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { file in
            guard file.pathExtension == "plist" else { return false }
            if app.bundleIDs.contains(where: { file.lastPathComponent.hasPrefix($0) }) { return true }
            // Agents named after the vendor still point into the bundle.
            guard let plist = NSDictionary(contentsOf: file) else { return false }
            let program = (plist["Program"] as? String) ?? ((plist["ProgramArguments"] as? [String])?.first ?? "")
            return program.hasPrefix(app.id.path + "/")
        }
    }

    /// Existing, unprotected, non-overlapping paths with their size and identity.
    private func measured(_ candidates: [(URL, TraceKind)]) -> [AppTrace] {
        var traces: [AppTrace] = []
        for (url, kind) in candidates {
            let path = url.standardizedFileURL.path
            guard kind == .app || kind == .system || isAllowedTrace(url), !traces.contains(where: { $0.url.path == path }) else { continue }
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            let type = info.st_mode & mode_t(S_IFMT)
            guard type != mode_t(S_IFLNK) else { continue }
            let isDirectory = type == mode_t(S_IFDIR)
            traces.append(AppTrace(id: url.standardizedFileURL, kind: kind, bytes: isDirectory ? Self.size(of: url) : Int64(info.st_size),
                                   identity: FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino)), isDirectory: isDirectory,
                                   modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))))
        }
        // A parent already covers its children.
        return traces.filter { trace in !traces.contains { $0.url != trace.url && trace.url.path.hasPrefix($0.url.path + "/") } }
    }

    /// Leftovers may only come from these ~/Library folders, or from a recognized tool's data roots.
    func isAllowedTrace(_ url: URL) -> Bool {
        let path = CanonicalPath.url(url).path
        guard !policy.isProtected(url) else { return false }
        let folders = ["Application Support", "Caches", "Preferences", "Saved Application State", "HTTPStorages", "WebKit", "Cookies",
                       "Logs", "LaunchAgents"]
        for folder in folders {
            let base = CanonicalPath.url(library.appending(path: folder)).path
            // Direct children only (or Application Support/<vendor>/<tool> for recognized tools).
            if CanonicalPath.url(url.deletingLastPathComponent()).path == base { return true }
        }
        let relative = path.hasPrefix(policy.home.path + "/") ? String(path.dropFirst(policy.home.path.count + 1)) : ""
        let prefixes = [""] + CreativeApp.vendorFolders.map { $0 + "/" }
        return CreativeApp.allCases.contains { app in
            app.roots.contains(relative) || app.folders.contains { folder in
                prefixes.contains { relative == "Library/Application Support/\($0)\(folder)" || relative == "Library/Caches/\($0)\(folder)" }
            }
        }
    }

    static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    // MARK: Slimming without uninstalling

    /// The parts of this app that exist on this Mac, largest first.
    func slimItems(for app: InstalledApp) -> [AppSlimItem] {
        AppSlimming.parts(for: app, home: policy.home).compactMap { part in
            var info = stat()
            guard lstat(part.url.path, &info) == 0, info.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) else { return nil }
            let bytes = info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) ? Self.size(of: part.url) : Int64(info.st_size)
            return AppSlimItem(id: part.url, title: part.title, note: part.note, bytes: bytes,
                               identity: FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino)))
        }
        .sorted { $0.bytes > $1.bytes }
    }

    /// Moves one part to the Trash, asking for the administrator password when the system requires it.
    func moveSlimItem(_ item: AppSlimItem, of app: InstalledApp) throws -> URL {
        guard AppSlimming.parts(for: app, home: policy.home).contains(where: { $0.url.path == item.url.path }) else { throw TrashError.notEligible }
        guard TrashService.currentIdentity(item.url) == item.identity else { throw TrashError.changed }
        do {
            var resulting: NSURL?
            try FileManager.default.trashItem(at: item.url, resultingItemURL: &resulting)
            return resulting as URL? ?? item.url
        } catch let error as NSError where AppRecycle.permissionDenied(error) {
            return try AppRecycle.authorizedTrash(item.url, identity: item.identity)
        }
    }

    // MARK: Leftovers of apps that are gone

    /// Bundle-id-named items whose vendor has no installed app at all, merged per id.
    /// Only ids that left what apps leave (support files, caches or window state) count: preferences or network
    /// storage alone are just as often written by helpers, installers and SDKs inside apps that are still here.
    func orphans(installed: [InstalledApp]) -> [OrphanGroup] {
        let vendors = Set(installed.map { Self.vendor($0.bundleID) })
        // Ids a recognized, installed tool is known to use besides its main bundle id.
        let toolIDs = Set(CreativeApp.allCases.filter(\.isInstalled).flatMap { $0.apps + $0.folders }.map { $0.lowercased() })
        let folders: [(String, String)] = [("Application Support", ""), ("Caches", ""), ("Preferences", ".plist"),
                                           ("Saved Application State", ".savedState"), ("HTTPStorages", ""), ("WebKit", ""), ("Logs", "")]
        var byID: [String: [(URL, TraceKind)]] = [:]
        for (folder, suffix) in folders {
            let directory = library.appending(path: folder)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
                var id = name
                if !suffix.isEmpty {
                    guard name.hasSuffix(suffix) else { continue }
                    id = String(name.dropLast(suffix.count))
                }
                if folder == "HTTPStorages", id.hasSuffix(".binarycookies") { id = String(id.dropLast(".binarycookies".count)) }
                guard Self.looksLikeBundleID(id), !vendors.contains(Self.vendor(id)), !toolIDs.contains(id.lowercased()),
                      !Self.sdkVendors.contains(Self.vendor(id)) else { continue }
                let url = directory.appending(path: name)
                guard CreativeApp.dataOwner(url, home: policy.home) == nil else { continue }
                let kind: TraceKind = folder == "Caches" ? .caches : folder == "Logs" ? .logs : folder == "HTTPStorages" || folder == "WebKit" ? .web
                    : folder == "Application Support" ? .support : .preferences
                byID[id, default: []].append((url, kind))
            }
        }
        return byID.compactMap { id, candidates -> OrphanGroup? in
            guard candidates.contains(where: { [.support, .caches].contains($0.1) || $0.0.pathExtension == "savedState" }) else { return nil }
            // LaunchServices knows apps outside /Applications too (Setapp, external disks, other folders).
            guard !Self.isRegistered(id) else { return nil }
            let traces = measured(candidates)
            return traces.isEmpty ? nil : OrphanGroup(id: id, traces: traces)
        }
        .sorted { $0.bytes > $1.bytes }
    }

    /// Namespaces of SDKs and system or developer tools, not apps: their data belongs to whatever still uses them.
    static let sdkVendors: Set<String> = ["com.segment", "com.revenuecat", "com.launchdarkly", "com.bugsnag", "com.plausiblelabs",
                                          "com.telemetrydeck", "com.crashlytics", "io.sentry", "com.google", "org.sparkle-project",
                                          "org.cups", "org.swift", "net.java", "com.github", "org.python", "org.nodejs", "com.mixpanel",
                                          "com.amplitude", "io.realm", "com.firebase", "com.microsoft"]

    static func vendor(_ id: String) -> String { id.split(separator: ".").prefix(2).joined(separator: ".").lowercased() }

    static func looksLikeBundleID(_ id: String) -> Bool {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty && !$0.contains(" ") }) else { return false }
        let lower = id.lowercased()
        return !["com.apple.", "group.", "systemgroup.", "com.microsoft.autoupdate"].contains { lower.hasPrefix($0) }
            && parts[0].allSatisfy({ $0.isLetter }) && ["com", "org", "net", "io", "cn", "ai", "dev", "app", "co", "me", "tv", "us"].contains(parts[0].lowercased())
    }

    static func isRegistered(_ id: String) -> Bool {
        var parts = id.split(separator: ".").map(String.init)
        while parts.count >= 3 {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: parts.joined(separator: ".")) != nil { return true }
            parts.removeLast()
        }
        return false
    }

    // MARK: Moving

    /// Re-checks one leftover and moves it to the Trash.
    func moveTrace(_ trace: AppTrace, of app: InstalledApp? = nil) throws -> URL {
        if trace.kind == .system {
            guard let app, Self.systemFolders(for: app).contains(where: { $0.path == trace.url.path }) else { throw TrashError.notEligible }
            guard TrashService.currentIdentity(trace.url) == trace.identity else { throw TrashError.changed }
            // Root-owned: the system asks for the administrator password.
            return try AppRecycle.authorizedTrash(trace.url, identity: trace.identity)
        }
        guard trace.kind != .app, isAllowedTrace(trace.url) else { throw TrashError.notEligible }
        var info = stat()
        guard lstat(trace.url.path, &info) == 0,
              FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino)) == trace.identity else { throw TrashError.changed }
        try TrashService.ensureUnused(trace.url, isDirectory: trace.isDirectory)
        var resulting: NSURL?
        try FileManager.default.trashItem(at: trace.url, resultingItemURL: &resulting)
        return resulting as URL? ?? trace.url
    }
}

/// State of the "卸载应用" page.
@MainActor
final class UninstallStore: ObservableObject {
    enum Sort: String, CaseIterable, Identifiable {
        case size = "按大小", idle = "按上次使用时间"
        var id: String { rawValue }
    }

    @Published var apps: [InstalledApp] = []
    @Published var isLoading = false
    @Published var sort: Sort = .size
    @Published var search = ""
    /// Selected app, or nil when the leftovers of removed apps are shown.
    @Published var selectedID: URL?
    @Published var showOrphans = false
    /// Whether the merged "相关文件" row of the selected app is opened up.
    @Published var showRelated = false
    @Published var showToolData = false
    @Published private(set) var traces: [URL: [AppTrace]] = [:]
    @Published private(set) var slimItems: [URL: [AppSlimItem]] = [:]
    @Published var picked: Set<URL> = []
    @Published var orphans: [OrphanGroup]?
    @Published var pickedOrphans: Set<String> = []
    @Published var showConfirm = false
    @Published var confirmDecided = false
    @Published var isWorking = false
    private let resultDismissTimer = ResultDismissTimer()
    @Published var report: CleanupReport? {
        didSet {
            resultDismissTimer.cancel()
            if report != nil { resultDismissTimer.schedule { [weak self] in self?.report = nil } }
        }
    }
    @Published var message: String?
    @Published private(set) var undoable: [(original: URL, trashed: URL)] = []
    private var undoAppOriginal: URL?

    /// App name to select once it is measured (`--select-app=` launch argument, for screenshots).
    var pendingSelection: String?

    let policy = SafetyPolicy()
    private var uninstaller: AppUninstaller { AppUninstaller(policy: policy) }
    private var loaded = false

    var visibleApps: [InstalledApp] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let filtered = query.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
        let sorted: [InstalledApp]
        switch sort {
        case .size: sorted = filtered.sorted { ($0.totalBytes ?? -1) > ($1.totalBytes ?? -1) }
        case .idle: sorted = filtered.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        }
        return Self.keepingFamiliesTogether(sorted)
    }

    /// Each app keeps its own row; the rest of its family follows the first member the sort puts in the list.
    private static func keepingFamiliesTogether(_ sorted: [InstalledApp]) -> [InstalledApp] {
        let families = Dictionary(grouping: sorted.filter { AppFamily.name(of: $0) != nil }) { AppFamily.name(of: $0)! }
        var placed: Set<String> = []
        return sorted.flatMap { app -> [InstalledApp] in
            guard let name = AppFamily.name(of: app) else { return [app] }
            return placed.insert(name).inserted ? families[name] ?? [app] : []
        }
    }

    var selectedApp: InstalledApp? { apps.first { $0.id == selectedID } }


    private func tool(for app: InstalledApp) -> CreativeApp? {
        CreativeApp.allCases.first { tool in
            tool.apps.contains { key in app.bundleIDs.contains { $0 == key || $0.hasPrefix(key + ".") } || app.name.hasPrefix(key) }
        }
    }

    /// What a tool's own data is, in its own terms: a video editor keeps projects, not conversations.
    func dataNote(for app: InstalledApp) -> String {
        tool(for: app)?.group.dataNote ?? "对话、模型和设置"
    }

    /// The last list, for the overview, without measuring anything. The page itself still refreshes it on first visit.
    func showCachedList() {
        if apps.isEmpty { apps = Self.loadCache() }
    }

    /// Apps not opened for three months: the ones worth looking at first.
    var idleApps: [InstalledApp] {
        let cutoff = Date().addingTimeInterval(-90 * 86_400)
        return apps.filter { ($0.lastUsed ?? .distantFuture) < cutoff }
    }

    func isRunning(_ app: InstalledApp) -> Bool {
        app.bundleIDs.contains { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
    }

    /// First visit: list apps right away, then fill in sizes, last-used dates and leftovers in the background.
    func loadIfNeeded() {
        guard !loaded else { return }
        reload()
    }

    /// Shows the last list at once (sizes included), then refreshes it in the background without
    /// blanking anything: opening the page should not feel like a scan.
    func reload() {
        loaded = true
        isLoading = true
        if apps.isEmpty { apps = Self.loadCache() }
        let uninstaller = self.uninstaller
        Task.detached(priority: .userInitiated) { [weak self] in
            let fresh = uninstaller.installedApps()
            await MainActor.run {
                guard let self else { return }
                // Keep known sizes until they are measured again.
                let known = Dictionary(self.apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                self.apps = fresh.map { app in
                    var app = app
                    app.appBytes = known[app.id]?.appBytes
                    app.traceBytes = known[app.id]?.traceBytes
                    app.lastUsed = known[app.id]?.lastUsed
                    return app
                }
                if !fresh.contains(where: { $0.id == self.selectedID }) { self.selectedID = nil }
            }
            // A few at a time: sizes fill in quickly without hogging the disk.
            await withTaskGroup(of: Void.self) { group in
                var pending = fresh[...]
                func next() -> InstalledApp? { pending.popFirst() }
                for _ in 0..<4 {
                    guard let app = next() else { break }
                    group.addTask { await self?.measure(app, with: uninstaller) }
                }
                while await group.next() != nil {
                    if let app = next() { group.addTask { await self?.measure(app, with: uninstaller) } }
                }
            }
            let orphans = uninstaller.orphans(installed: fresh)
            await MainActor.run {
                guard let self else { return }
                self.orphans = orphans
                // The rules that find these are strict enough to clean them without asking.
                self.pickedOrphans = Set(orphans.filter { !SensitiveApps.matches($0.id) }.map(\.id))
                self.isLoading = false
                Self.saveCache(self.apps)
            }
        }
    }

    nonisolated private func measure(_ app: InstalledApp, with uninstaller: AppUninstaller) async {
        let traces = uninstaller.traces(for: app)
        let slim = uninstaller.slimItems(for: app)
        let used = AppUninstaller.lastUsed(app.appURL, traces: traces)
        await MainActor.run { self.apply(traces, slim: slim, lastUsed: used, to: app) }
    }

    private func apply(_ traces: [AppTrace], slim: [AppSlimItem], lastUsed: Date?, to app: InstalledApp) {
        guard let index = apps.firstIndex(where: { $0.id == app.id }) else { return }
        let firstLook = self.traces[app.id] == nil
        self.traces[app.id] = traces
        slimItems[app.id] = slim
        apps[index].appBytes = traces.first { $0.kind == .app }?.bytes
        apps[index].traceBytes = traces.filter { $0.kind != .app }.reduce(0) { $0 + $1.bytes }
        apps[index].lastUsed = lastUsed
        if selectedID == app.id, firstLook { pickDefaults(for: app) }
        if pendingSelection == app.name {
            pendingSelection = nil
            select(apps[index])
        }
    }

    private static var cacheURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Qingo/results")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "apps.json")
    }

    private static func loadCache() -> [InstalledApp] {
        guard let data = try? Data(contentsOf: cacheURL), let apps = try? JSONDecoder().decode([InstalledApp].self, from: data) else { return [] }
        return apps.filter { FileManager.default.fileExists(atPath: $0.id.path) }
    }

    private static func saveCache(_ apps: [InstalledApp]) {
        if let data = try? JSONEncoder().encode(apps) { try? data.write(to: cacheURL, options: .atomic) }
    }

    func select(_ app: InstalledApp) {
        showOrphans = false
        showRelated = false
        showToolData = false
        selectedID = app.id
        report = nil
        message = nil
        pickDefaults(for: app)
        // Not measured yet in this session: measure this one now rather than wait for its turn.
        if traces[app.id] == nil {
            let uninstaller = self.uninstaller
            Task.detached(priority: .userInitiated) { [weak self] in await self?.measure(app, with: uninstaller) }
        }
    }

    func selectOrphans() {
        showOrphans = true
        selectedID = nil
        report = nil
        message = nil
        pickedOrphans = Set((orphans ?? []).filter { !SensitiveApps.matches($0.id) }.map(\.id))
    }

    private func pickDefaults(for app: InstalledApp) {
        picked = Set((traces[app.id] ?? []).filter(AppUninstaller.pickedByDefault).map(\.id))
    }

    /// Picks or unpicks a set of leftovers at once (the merged "相关文件" row).
    func toggle(_ group: [AppTrace]) {
        let ids = Set(group.map(\.id))
        if ids.isSubset(of: picked) { picked.subtract(ids) } else { picked.formUnion(ids) }
    }

    func toggle(_ trace: AppTrace) {
        // The bundle itself always goes; that is what uninstalling means.
        guard trace.kind != .app else { return }
        if picked.contains(trace.id) { picked.remove(trace.id) } else { picked.insert(trace.id) }
    }

    func toggleOrphan(_ group: OrphanGroup) {
        if pickedOrphans.contains(group.id) { pickedOrphans.remove(group.id) } else { pickedOrphans.insert(group.id) }
    }

    func hasContainer(_ app: InstalledApp) -> Bool { uninstaller.hasContainer(app) }

    func reviewCleanup() {
        confirmDecided = false
        showConfirm = true
    }

    // MARK: Uninstall

    func uninstall() {
        guard let app = selectedApp, let traces = traces[app.id], !isWorking else { return }
        showConfirm = false
        guard !isRunning(app) else {
            message = "\(app.name) 正在运行，请先退出再卸载"
            return
        }
        isWorking = true
        report = nil
        message = nil
        let leftovers = traces.filter { $0.kind != .app && picked.contains($0.id) }
        let uninstaller = self.uninstaller
        let identity = traces.first { $0.kind == .app }?.identity
        NSWorkspace.shared.recycle([app.id]) { [weak self] moved, error in
            Task { @MainActor in
                guard let self else { return }
                var trashedApp = moved[app.id]
                if trashedApp == nil, let error = error as NSError?, AppRecycle.permissionDenied(error), let identity,
                   TrashService.currentIdentity(app.id) == identity, !self.isRunning(app) {
                    do {
                        trashedApp = try await Task.detached { try AppRecycle.authorizedTrash(app.id, identity: identity) }.value
                    } catch {
                        self.message = (error as NSError).code == -128 ? "已取消授权，未卸载 \(app.name)" : "无法卸载 \(app.name)：\(error.localizedDescription)"
                    }
                }
                guard let trashedApp else {
                    self.isWorking = false
                    if self.message != nil { return }
                    if let error = error as NSError?, AppRecycle.permissionDenied(error) {
                        self.message = "没有权限卸载 \(app.name)，可在访达中移到废纸篓并按系统提示输入管理员密码"
                    } else {
                        self.message = "无法将 \(app.name) 移到废纸篓：\(error.map { TrashService.reason(for: $0) } ?? "系统未返回移动结果")"
                    }
                    return
                }
                Task.detached(priority: .userInitiated) { [weak self] in
                    let result = Self.move(leftovers, of: app, with: uninstaller)
                    await MainActor.run {
                        guard let self else { return }
                        self.isWorking = false
                        self.undoable = [(app.id, trashedApp)] + result.moved
                        self.undoAppOriginal = app.id
                        let bytes = (traces.first { $0.kind == .app }?.bytes ?? 0) + leftovers.filter { t in result.moved.contains { $0.original == t.url } }.reduce(0) { $0 + $1.bytes }
                        self.report = CleanupReport(movedCount: result.moved.count + 1, movedBytes: bytes, failures: result.failures)
                        let sizes = Dictionary(traces.map { ($0.url.path, $0.bytes) }, uniquingKeysWith: { first, _ in first })
                        CleanupLog.record("卸载 \(app.name)", moved: [(app.id, traces.first { $0.kind == .app }?.bytes ?? 0)]
                                          + result.moved.map { ($0.original, sizes[$0.original.path] ?? 0) }, failedCount: result.failures.count)
                        self.apps.removeAll { $0.id == app.id }
                        self.traces[app.id] = nil
                        self.selectedID = nil
                    }
                }
            }
        }
    }

    /// Moves one part of the selected app to the Trash; the app stays installed.
    func removeSlimItem(_ item: AppSlimItem, of app: InstalledApp) {
        guard !isWorking else { return }
        guard !isRunning(app) else {
            message = "\(app.name) 正在运行，请先退出再移除"
            return
        }
        isWorking = true
        report = nil
        message = nil
        let uninstaller = self.uninstaller
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = Result { try uninstaller.moveSlimItem(item, of: app) }
            await MainActor.run {
                guard let self else { return }
                self.isWorking = false
                switch outcome {
                case .success(let trashed):
                    self.undoable = [(item.url, trashed)]
                    self.undoAppOriginal = item.url
                    self.report = CleanupReport(movedCount: 1, movedBytes: item.bytes, failures: [])
                    CleanupLog.record("移除 \(app.name) 的 \(item.title)", moved: [(item.url, item.bytes)], failedCount: 0)
                case .failure(let error):
                    self.message = (error as NSError).code == -128 ? "已取消授权，未移除 \(item.title)" : "无法移除 \(item.title)：\(TrashService.reason(for: error))"
                }
            }
            await self?.measure(app, with: uninstaller)
        }
    }

    func removeOrphans() {
        let groups = (orphans ?? []).filter { pickedOrphans.contains($0.id) }
        guard !groups.isEmpty, !isWorking else { return }
        showConfirm = false
        isWorking = true
        report = nil
        message = nil
        let traces = groups.flatMap(\.traces)
        let uninstaller = self.uninstaller
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Self.move(traces, with: uninstaller)
            await MainActor.run {
                guard let self else { return }
                self.isWorking = false
                self.undoable = result.moved
                self.undoAppOriginal = nil
                let movedPaths = Set(result.moved.map(\.original.path))
                let bytes = traces.filter { movedPaths.contains($0.url.path) }.reduce(0) { $0 + $1.bytes }
                self.report = CleanupReport(movedCount: result.moved.count, movedBytes: bytes, failures: result.failures)
                let sizes = Dictionary(traces.map { ($0.url.path, $0.bytes) }, uniquingKeysWith: { first, _ in first })
                CleanupLog.record("清理残留", moved: result.moved.map { ($0.original, sizes[$0.original.path] ?? 0) },
                                  failedCount: result.failures.count)
                self.orphans = self.orphans?.compactMap { group in
                    let left = group.traces.filter { !movedPaths.contains($0.url.path) }
                    return left.isEmpty ? nil : OrphanGroup(id: group.id, traces: left)
                }
                self.pickedOrphans.removeAll()
            }
        }
    }

    nonisolated private static func move(_ traces: [AppTrace], of app: InstalledApp? = nil, with uninstaller: AppUninstaller)
        -> (moved: [(original: URL, trashed: URL)], failures: [CleanupReport.Failure]) {
        var moved: [(original: URL, trashed: URL)] = []
        var failures: [CleanupReport.Failure] = []
        for trace in traces {
            do {
                moved.append((trace.url, try uninstaller.moveTrace(trace, of: app)))
            } catch {
                failures.append(CleanupReport.Failure(id: trace.url, name: trace.url.lastPathComponent, reason: TrashService.reason(for: error)))
            }
        }
        return (moved, failures)
    }

    func undo() {
        let entries = undoable
        let appOriginal = undoAppOriginal
        guard !entries.isEmpty, !isWorking else { return }
        undoable = []
        isWorking = true
        Task.detached(priority: .userInitiated) { [weak self] in
            var back = TrashService.putBack(entries)
            let home = FileManager.default.homeDirectoryForCurrentUser.path + "/"
            for (index, entry) in entries.enumerated() where !back[index] && (entry.original == appOriginal || !entry.original.path.hasPrefix(home)) {
                guard let identity = TrashService.currentIdentity(entry.trashed), !FileManager.default.fileExists(atPath: entry.original.path) else { continue }
                do {
                    try AppRecycle.authorizedMove(from: entry.trashed, to: entry.original, identity: identity)
                    back[index] = true
                } catch { }
            }
            let restored = back.filter { $0 }.count
            await MainActor.run {
                guard let self else { return }
                self.isWorking = false
                self.report = nil
                self.undoable = zip(entries, back).compactMap { entry, restored in restored ? nil : entry }
                self.undoAppOriginal = self.undoable.contains { $0.original == appOriginal } ? appOriginal : nil
                self.message = restored == entries.count ? "已恢复 \(restored) 项" : "已恢复 \(restored) 项，\(entries.count - restored) 项未恢复"
                self.reload()
            }
        }
    }
}
