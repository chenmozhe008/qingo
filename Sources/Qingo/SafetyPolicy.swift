import Foundation

struct SafetyPolicy: Sendable {
    let home: URL
    let protectedRoots: [URL]
    let extraProtectedRoots: [URL]

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, extraProtected: [URL] = []) {
        let canonicalHome = CanonicalPath.url(home)
        self.home = canonicalHome
        self.extraProtectedRoots = extraProtected.map(CanonicalPath.url)
        let names = [
            "Library/Application Support/RecordingInbox",
            "Library/Application Support/LarkShell",
            "Library/Application Support/Codex",
            "Library/Application Support/Shandianshuo",
            "Library/Containers/com.tencent.xinWeChat",
            "Library/Containers/com.tencent.WeWorkMac",
            "Library/Caches/ms-playwright",
            ".cache/whisper",
            "Library/Developer/Xcode",
            ".ssh", ".aws", ".codex", ".Trash"
        ]
        protectedRoots = names.map { canonicalHome.appending(path: $0) }
            + extraProtectedRoots
    }

    func isProtected(_ url: URL) -> Bool {
        let path = CanonicalPath.url(url).path
        if extraProtectedRoots.contains(where: { path == $0.path || path.hasPrefix($0.path + "/") }) { return true }
        let allowedInside = ["Library/Application Support/Codex/Cache", "Library/Application Support/Codex/Code Cache",
                             "Library/Application Support/Shandianshuo/recordings", "Library/Developer/Xcode/DerivedData"]
            .map { home.appending(path: $0).path }
        if allowedInside.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return false }
        return protectedRoots.contains { protected in
            path == protected.path || path.hasPrefix(protected.path + "/")
        }
    }

    func allowedChildren(ofProtectedRoot url: URL) -> [URL]? {
        let path = CanonicalPath.url(url).path
        if extraProtectedRoots.contains(where: { path == $0.path || path.hasPrefix($0.path + "/") }) { return nil }
        if path == home.appending(path: "Library/Application Support/Codex").path {
            return ["Cache", "Code Cache"].map { url.appending(path: $0) }
        }
        if path == home.appending(path: "Library/Application Support/Shandianshuo").path {
            return [url.appending(path: "recordings")]
        }
        // Only Xcode's build cache; Archives, device support and the rest stay protected.
        if path == home.appending(path: "Library/Developer/Xcode").path {
            return [url.appending(path: "DerivedData")]
        }
        return nil
    }

    func isProject(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ["fcpbundle", "xcodeproj", "xcworkspace", "logicx", "band", "als",
            "aep", "aepx", "blend", "blend1", "blend2", "drp", "dra", "fig",
            "psd", "psb", "prproj", "ai", "aepx", "sesx", "lrcat", "lrcat-data"].contains(ext) {
            return true
        }
        let path = CanonicalPath.url(url).path
        return ["Library/Application Support/Figma", "Library/Application Support/Blender",
                "Library/Application Support/Blackmagic Design/DaVinci Resolve"]
            .contains { path == home.appending(path: $0).path }
    }

    func reviewDescription(for url: URL, isDirectory: Bool) -> String? {
        guard isDirectory, !isProtected(url) else { return nil }
        let path = CanonicalPath.url(url).path
        // One downloaded model inside a model tool's folder: listed on its own so it can be picked.
        if let model = modelName(url) {
            return "下载的模型 \(model)，删除后需重新下载。"
        }
        if isVirtualEnvironment(url) {
            return "Python 虚拟环境，删除后需重新创建并安装依赖。"
        }
        // Only the outermost folder of a recognized tool; its cleanable caches are listed separately.
        if let app = CreativeApp.dataOwner(url, home: home), CreativeApp.cacheNote(url, home: home) == nil,
           CreativeApp.dataOwner(url.deletingLastPathComponent(), home: home) != app || isProtected(url.deletingLastPathComponent()) {
            return app.dataDescription
        }
        // Only the outermost node_modules; nested ones are already counted inside it.
        if url.lastPathComponent == "node_modules", hasNodeManifest(near: url),
           !url.deletingLastPathComponent().path.contains("/node_modules") {
            return "项目依赖文件夹，删除后需重新安装。"
        }
        if path == home.appending(path: "Library/Application Support/Shandianshuo/recordings").path {
            return "闪电说的录音，仅统计超过 15 天的旧录音，需逐条确认。"
        }
        if path == home.appending(path: "Library/Application Support/Notion/Partitions/notion/Service Worker").path {
            return "Notion 的离线缓存可能包含未同步的改动，仅显示占用。"
        }
        if url.lastPathComponent == "Render Files", path.contains(".fcpbundle/") {
            return "Final Cut 的渲染文件。请在 Final Cut 中选中资源库，选择「文件 → 删除已生成的资源库文件」。此处不直接清理。"
        }
        if url.lastPathComponent == "CacheClip" {
            return "达芬奇的渲染缓存。请在达芬奇中使用「删除渲染缓存」清理，此处不直接清理。"
        }
        return nil
    }

    func cacheDescription(for url: URL, isDirectory: Bool) -> String? {
        guard isDirectory, !isProtected(url) else { return nil }
        if let note = CreativeApp.cacheNote(url, home: home) { return note }
        guard !isProject(url), CreativeApp.dataOwner(url, home: home) == nil else { return nil }
        let name = url.lastPathComponent
        let path = CanonicalPath.url(url).path

        // Library/Caches is a cache namespace, but only its direct children become actions.
        let libraryCaches = home.appending(path: "Library/Caches").path
        if CanonicalPath.url(url.deletingLastPathComponent()).path == libraryCaches {
            if name.hasPrefix("com.apple.") || ["GeoServices", "SharedImageCache", "OTFileCache", "CloudKit", "FamilyCircle", "familycircled"].contains(name) {
                return nil
            }
            if name == "Adobe" {
                return nil
            }
            if name == "Blender" {
                return "Blender 的应用缓存，不包含 .blend 工程和用户设置，下次打开时会重新生成。"
            }
            if name == "Homebrew" {
                return "Homebrew 的下载缓存。清理旧版本请使用 brew cleanup，小清不会自动运行。"
            }
            return "应用缓存，下次使用时自动重建。"
        }
        let appSupportCaches = home.appending(path: "Library/Application Support/Caches").path
        if CanonicalPath.url(url.deletingLastPathComponent()).path == appSupportCaches,
           name.hasSuffix("-updater") {
            return "应用更新时下载的安装包，下次更新时可能需要重新下载。"
        }

        let directCaches = [
            ("Library/Developer/Xcode/DerivedData", "Xcode 的构建缓存和索引，下次打开工程时会重新生成。"),
            (".cache/uv", "uv 的包缓存，下次安装依赖时可能需要重新下载。"),
            (".cache/pip", "pip 的包缓存，下次安装依赖时可能需要重新下载。"),
            (".npm/_cacache", "npm 的包缓存，下次安装依赖时可能需要重新下载。"),
            ("Library/Application Support/Notion/Partitions/notion/Cache", "Notion 的浏览器缓存，下次打开时自动重建。"),
            ("Library/Application Support/Notion/Partitions/notion/Code Cache", "Notion 的代码缓存，下次打开时自动重建。")
        ]
        if let match = directCaches.first(where: { path == home.appending(path: $0.0).path }) {
            return match.1
        }

        // Build artifacts inside projects. The source and the project root stay untouched.
        if name == ".build", FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appending(path: "Package.swift").path) {
            return "Swift 的构建产物，下次构建时会重新生成。"
        }
        if name == "target", FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appending(path: "Cargo.toml").path) {
            return "Rust 的构建产物，下次构建时会重新生成。"
        }
        if ["__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache"].contains(name) {
            return "开发工具生成的缓存，运行时会重新生成。"
        }
        // Front-end build caches, only next to the project manifest that produces them.
        if let tool = Self.frontEndCaches[name], hasNodeManifest(near: url) {
            return "\(tool) 的构建缓存，下次构建时会重新生成。"
        }
        if name == ".gradle", ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]
            .contains(where: { FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appending(path: $0).path) }) {
            return "Gradle 的工程缓存，下次构建时会重新生成。"
        }
        if name == "cache", url.deletingLastPathComponent().lastPathComponent == ".next" {
            return "Next.js 的构建缓存，下次构建时会重新生成。"
        }
        // Never infer that arbitrary folders named Cache inside a bundle are safe.
        if path.contains(".fcpbundle/") { return nil }
        return nil
    }

    var quickScanLocations: [URL] {
        let libraryCaches = home.appending(path: "Library/Caches")
        let cacheChildren = (try? FileManager.default.contentsOfDirectory(at: libraryCaches, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let extra = [
            ".cache/uv", ".cache/pip", ".npm/_cacache", "Library/Developer/Xcode/DerivedData",
            "Library/Application Support/Codex/Cache", "Library/Application Support/Codex/Code Cache",
            "Library/Application Support/Notion/Partitions/notion/Cache",
            "Library/Application Support/Notion/Partitions/notion/Code Cache",
            "Library/Application Support/Notion/Partitions/notion/Service Worker"
        ].map { home.appending(path: $0) }
        let updaterRoot = home.appending(path: "Library/Application Support/Caches")
        let updaters = (try? FileManager.default.contentsOfDirectory(at: updaterRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let recordings = home.appending(path: "Library/Application Support/Shandianshuo/recordings")
        let toolData = CreativeApp.dataLocations(home: home).filter { !isProtected($0) }
        let locations = Set(cacheChildren + extra + updaters + [recordings] + toolData).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true &&
                (cacheDescription(for: $0, isDirectory: true) != nil || reviewDescription(for: $0, isDirectory: true) != nil)
        }
        // A parent owns its whole measured subtree; never scan/count the same data twice.
        return locations.filter { child in
            !locations.contains { parent in child != parent && child.path.hasPrefix(parent.path + "/") }
        }.sorted { $0.path < $1.path }
    }

    func risk(for url: URL, kind: ScanKind) -> ScanRisk {
        guard kind == .cache else { return .c }
        let path = CanonicalPath.url(url).path
        let relative = path.hasPrefix(home.path + "/") ? String(path.dropFirst(home.path.count + 1)) : ""
        if relative.hasPrefix(".cache/") || relative == ".npm/_cacache" || relative == "Library/Developer/Xcode/DerivedData" ||
            (relative.hasPrefix("Library/Application Support/Caches/") && relative.hasSuffix("-updater")) ||
            relative == "Library/Caches/Homebrew" ||
            relative.hasPrefix("Library/Application Support/Adobe/Common/") ||
            relative.hasPrefix("Library/Caches/Adobe/After Effects/") {
            return .a
        }
        // Build artifacts and tool caches regenerate on the next build/run; no app needs quitting.
        let name = url.lastPathComponent
        if [".build", "target", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".gradle"].contains(name) ||
            Self.frontEndCaches[name] != nil ||
            (name == "cache" && url.deletingLastPathComponent().lastPathComponent == ".next") {
            return .a
        }
        return .b
    }

    static let frontEndCaches = [".turbo": "Turborepo", ".parcel-cache": "Parcel", ".nuxt": "Nuxt", ".svelte-kit": "SvelteKit"]

    /// What deleting this costs, for items the user may delete after confirming (not regenerable caches).
    /// nil means it is not offered for deletion here. `TrashService` re-checks this before moving anything.
    func decisionNote(for item: ScanItem) -> String? {
        let url = item.url
        guard !isProtected(url) else { return nil }
        switch item.kind {
        case .review:
            if url.lastPathComponent == "node_modules", hasNodeManifest(near: url),
               !url.deletingLastPathComponent().path.contains("/node_modules") {
                return "删除后需重新安装依赖（npm install 等），依赖它的定时任务会停止。"
            }
            if isVirtualEnvironment(url) { return "删除后需重新创建虚拟环境并安装依赖，依赖它的定时任务会停止。" }
            if modelName(url) != nil { return "删除后，使用该模型需重新下载。" }
            return nil
        case .largeFile:
            // The user's own files; anything inside ~/Library belongs to an app.
            let path = CanonicalPath.url(url).path
            guard !path.hasPrefix(home.appending(path: "Library").path + "/") else { return nil }
            if ["dmg", "pkg"].contains(url.pathExtension.lowercased()) { return "安装包，删除后如需使用需重新下载。" }
            return "删除后无法自动恢复，请确认不再需要。"
        default:
            return nil
        }
    }

    /// Whether a folder found inside a tool's data is listed on its own (a model) rather than counted in the data row.
    func isOwnRowInToolData(_ url: URL) -> Bool { modelName(url) != nil }

    /// "Qwen/Qwen2.5-7B" for a Hugging Face hub model or an LM Studio model folder, nil otherwise.
    func modelName(_ url: URL) -> String? {
        let path = CanonicalPath.url(url).path
        let parent = CanonicalPath.url(url.deletingLastPathComponent()).path
        let name = url.lastPathComponent
        if parent == home.appending(path: ".cache/huggingface/hub").path, name.hasPrefix("models--") {
            return name.dropFirst("models--".count).replacingOccurrences(of: "--", with: "/")
        }
        for root in [".lmstudio/models", ".cache/lm-studio/models"] {
            let base = home.appending(path: root).path + "/"
            guard path.hasPrefix(base) else { continue }
            let parts = path.dropFirst(base.count).split(separator: "/")
            if parts.count == 2 { return parts.joined(separator: "/") }
        }
        return nil
    }

    private func isVirtualEnvironment(_ url: URL) -> Bool {
        [".venv", "venv"].contains(url.lastPathComponent)
            && FileManager.default.fileExists(atPath: url.appending(path: "pyvenv.cfg").path)
    }

    private func hasNodeManifest(near url: URL) -> Bool {
        let parent = url.deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: parent.appending(path: "package.json").path)
    }
}
