import AppKit
import Darwin

/// 常规缓存之外、个人文件夹外面的可再生残留（2026-11-06 调研后加，见 docs/清理能力改进方案-2026-11.md）：
/// - Chromium 系浏览器的签名副本：浏览器每次启动把自己克隆进系统临时目录 X 做签名校验，退出、升级后旧副本常留下来
///   （作者本机 Chrome 10 份，按文件大小量 12.8 GB）。判据照 Mole（tw93/Mole，lib/core/browser_clones.sh）。
/// - Clang 编译缓存（系统缓存目录 C/clang/ModuleCache），下次编译自动重建。
/// 清理前重新核对已安装版本和运行状态。退出浏览器后才允许移动确认过期的副本。
enum Leftovers {
    struct Found {
        let url: URL
        /// 实际能腾出的空间：同一版本的副本之间、与已安装的浏览器共用数据块，按文件大小加总会虚报
        let bytes: Int64
        let note: String
    }

    private struct Browser {
        let folder: String
        let bundleID: String
        let name: String
    }

    private static let browsers = [
        Browser(folder: "com.google.Chrome.code_sign_clone", bundleID: "com.google.Chrome", name: "Google Chrome"),
        Browser(folder: "com.google.Chrome.beta.code_sign_clone", bundleID: "com.google.Chrome.beta", name: "Google Chrome Beta"),
        Browser(folder: "com.google.Chrome.canary.code_sign_clone", bundleID: "com.google.Chrome.canary", name: "Google Chrome Canary"),
        Browser(folder: "org.chromium.Chromium.code_sign_clone", bundleID: "org.chromium.Chromium", name: "Chromium"),
        Browser(folder: "com.microsoft.edgemac.code_sign_clone", bundleID: "com.microsoft.edgemac", name: "Microsoft Edge"),
        Browser(folder: "com.brave.Browser.code_sign_clone", bundleID: "com.brave.Browser", name: "Brave"),
    ]

    /// 编译工具在跑时不动 Clang 缓存（照 Mole 的 clang_module_cache_process_state）
    private static let compilers: Set<String> = ["clang", "clangd", "swiftc", "swift-frontend", "swift-build", "sourcekit-lsp",
                                                 "SourceKitService", "xcodebuild", "Xcode"]

    /// 当前用户的系统临时目录（/private/var/folders/xx/…），C 是缓存、T 是临时、X 是签名副本
    static let darwinUserRoot: URL? = {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count) > 0 else { return nil }
        let cache = CanonicalPath.url(URL(fileURLWithPath: buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }, isDirectory: true))
        let root = cache.deletingLastPathComponent()
        return root.path.hasPrefix("/private/var/folders/") ? root : nil
    }()

    static var clangCache: URL? { darwinUserRoot?.appending(path: "C/clang/ModuleCache") }

    static func find() -> [Found] {
        guard !AppHome.isDemo else { return [] }
        return browserClones() + clang()
    }

    /// 清理前再判断一次；不认识的路径返回 nil
    static func note(for url: URL) -> String? {
        guard let root = darwinUserRoot else { return nil }
        let path = CanonicalPath.url(url).path
        guard path.hasPrefix(root.path + "/") else { return nil }
        if path == clangCache.map({ CanonicalPath.url($0).path }) { return compilersIdle() ? clangNote : nil }
        return cloneNote(url)
    }

    // MARK: 浏览器签名副本

    struct SharedCopies: Codable, Sendable {
        let count: Int
        let countedBytes: Int64
    }

    /// Same-version clones may share the installed app's data. Their summed allocation is informational only.
    static func sharedBrowserCopies() -> SharedCopies? {
        guard !AppHome.isDemo, darwinUserRoot != nil else { return nil }
        var count = 0
        var bytes: Int64 = 0
        for browser in browsers {
            guard let installed = installedVersion(browser.bundleID) else { continue }
            for clone in cloneEntries(browser) where cloneVersion(clone) == installed {
                count += 1
                bytes += allocatedSize(clone)
            }
        }
        return SharedCopies(count: count, countedBytes: bytes)
    }

    private static func browserClones() -> [Found] {
        var found: [Found] = []
        for browser in browsers {
            guard let installed = installedVersion(browser.bundleID),
                  NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID).isEmpty else { continue }
            let clones = cloneEntries(browser).compactMap { url -> (URL, String)? in
                guard let version = cloneVersion(url), isObsolete(version, installed: installed) else { return nil }
                return (url, version)
            }
            // Each old version is counted once because copies of that version can share blocks.
            for (version, members) in Dictionary(grouping: clones, by: { $0.1 }) {
                let bytes = allocatedSize(members[0].0) / Int64(members.count)
                for member in members {
                    found.append(Found(url: member.0, bytes: bytes, note: oldCopyNote(browser, version: version)))
                }
            }
        }
        return found
    }

    private static func cloneEntries(_ browser: Browser) -> [URL] {
        guard let root = darwinUserRoot else { return [] }
        let folder = root.appending(path: "X/\(browser.folder)")
        guard CanonicalPath.isDirect(folder) else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter(isOwnedClone)
    }

    private static func isOwnedClone(_ url: URL) -> Bool {
        var info = stat()
        return url.lastPathComponent.range(of: #"^code_sign_clone\.[A-Za-z0-9]{6}$"#, options: .regularExpression) != nil &&
            CanonicalPath.isDirect(url) && lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR &&
            info.st_uid == getuid()
    }

    static func isObsolete(_ version: String, installed: String) -> Bool {
        let pattern = #"^[0-9]+(?:\.[0-9]+)+$"#
        guard version.range(of: pattern, options: .regularExpression) != nil,
              installed.range(of: pattern, options: .regularExpression) != nil else { return false }
        return version.compare(installed, options: .numeric) == .orderedAscending
    }

    private static func cloneNote(_ url: URL) -> String? {
        guard let root = darwinUserRoot else { return nil }
        let parent = url.deletingLastPathComponent()
        guard parent.deletingLastPathComponent().path == root.appending(path: "X").path,
              let browser = browsers.first(where: { $0.folder == parent.lastPathComponent }),
              isOwnedClone(url), let installed = installedVersion(browser.bundleID),
              let version = cloneVersion(url), isObsolete(version, installed: installed),
              NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID).isEmpty else { return nil }
        return oldCopyNote(browser, version: version)
    }

    private static func oldCopyNote(_ browser: Browser, version: String) -> String {
        "\(browser.name) \(version) 留下的旧版签名副本。多个副本可能共享数据，大小为估算值。"
    }

    private static func cloneVersion(_ url: URL) -> String? {
        let bundle = ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
            .first { $0.pathExtension == "app" || $0.lastPathComponent.hasSuffix(".app.bundle") }
        return bundle.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }
            ?? bundle.flatMap { NSDictionary(contentsOf: $0.appending(path: "Contents/Info.plist"))?["CFBundleShortVersionString"] as? String }
    }

    private static func installedVersion(_ bundleID: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }
    }

    /// 签名副本属于哪个浏览器，列表上显示它的名字和图标
    static func browser(of url: URL) -> (name: String, bundleID: String)? {
        guard let root = darwinUserRoot,
              CanonicalPath.url(url.deletingLastPathComponent().deletingLastPathComponent()).path == root.appending(path: "X").path,
              let browser = browsers.first(where: { $0.folder == url.deletingLastPathComponent().lastPathComponent }) else { return nil }
        return (browser.name, browser.bundleID)
    }

    // MARK: Clang

    private static let clangNote = "Clang 编译缓存，下次编译时自动重建。"

    private static func clang() -> [Found] {
        guard let url = clangCache, FileManager.default.fileExists(atPath: url.path), compilersIdle() else { return [] }
        return [Found(url: url, bytes: allocatedSize(url), note: clangNote)]
    }

    private static func compilersIdle() -> Bool { runningProcessNames().isDisjoint(with: compilers) }

    private static func runningProcessNames() -> Set<String> {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        var names = Set<String>()
        var buffer = [CChar](repeating: 0, count: 1024)
        for pid in pids.prefix(max(count, 0)) where pid > 0 {
            if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 { names.insert(buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }) }
        }
        return names
    }

    // MARK: 大小

    static func allocatedSize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
