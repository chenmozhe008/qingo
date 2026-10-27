import Foundation

/// Creative and AI tools the scanner recognizes, Chinese and international.
/// Recognition decides ownership only. A tool's folder is read-only as a whole; the only cleanable parts are
/// its folder under ~/Library/Caches, the paths listed in `caches`, and browser-style cache folders
/// (Cache, Code Cache, GPUCache…) directly inside its Application Support folder.
struct CreativeApp: Hashable, Sendable, Identifiable {
    enum Group: String, CaseIterable, Sendable {
        case video = "剪辑与调色"
        case design = "设计与三维"
        case aiCreate = "AI 生图与视频"
        case aiChat = "AI 助手"
        case aiCode = "AI Coding 与智能体"
        case localModel = "本地模型"

        var symbol: String {
            switch self {
            case .video: "film.stack.fill"
            case .design: "paintpalette.fill"
            case .aiCreate: "wand.and.stars"
            case .aiChat: "bubble.left.and.bubble.right.fill"
            case .aiCode: "chevron.left.forwardslash.chevron.right"
            case .localModel: "cpu.fill"
            }
        }

        /// What the read-only part of these tools holds.
        var dataNote: String {
            switch self {
            case .video, .design: "项目、素材和设置"
            case .aiCreate: "模型、工作流和生成的作品"
            case .aiChat: "对话记录和登录状态"
            case .aiCode: "对话记录、扩展和工作区设置"
            case .localModel: "下载的模型，删除后需重新下载"
            }
        }
    }

    let id: String
    let title: String
    let group: Group
    let shortName: String
    /// Bundle ids, or .app name prefixes (e.g. "Adobe Photoshop" matches "Adobe Photoshop 2026").
    let apps: [String]
    /// Folder names under Library/Application Support and Library/Caches (and their Adobe / Blackmagic Design subfolders).
    let folders: [String]
    /// Home-relative data roots. Listed, never cleaned.
    let roots: [String]
    /// Home-relative folders that only hold regenerable cache. Cleanable once the tool is quit.
    let caches: [String]
    /// How to clean what the tool keeps inside its own data.
    let cleanHow: String?
    /// Command-line tools borrow the icon of their maker's app.
    let iconApp: String?

    init(_ id: String, _ title: String, _ group: Group, short: String? = nil, apps: [String] = [], folders: [String] = [],
         roots: [String] = [], caches: [String] = [], cleanHow: String? = nil, iconApp: String? = nil) {
        self.id = id
        self.title = title
        self.group = group
        self.shortName = short ?? title
        self.apps = apps
        self.folders = folders
        self.roots = roots
        self.caches = caches
        self.cleanHow = cleanHow
        self.iconApp = iconApp
    }

    /// Products of one maker shown as one card ("Adobe"), instead of a card per app with a few MB each.
    var family: String? {
        ["ae", "premiere", "ame", "audition", "adobe-common", "ps", "ai", "lr"].contains(id) ? "Adobe" : nil
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var hint: String {
        cleanHow ?? "缓存可在此清理；\(group.dataNote)仅显示大小"
    }

    var dataDescription: String {
        "\(title) 的\(group.dataNote)。仅显示大小，不会删除。" + (cleanHow.map { "\($0)。" } ?? "")
    }

    /// How to slim down a VS Code-style editor: extensions are the big part and are removed in the editor.
    static func editorHow(_ name: String) -> String {
        "缓存可在此清理；不需要的扩展请在\(name)的「扩展」面板中卸载"
    }

    // MARK: Catalog

    // 剪辑与调色
    static let afterEffects = CreativeApp("ae", "After Effects", .video, short: "AE", apps: ["com.adobe.AfterEffects", "Adobe After Effects"],
                                          folders: ["After Effects", "Adobe After Effects"], cleanHow: "也可在 AE 中选择「编辑 → 清理 → 所有内存与磁盘缓存」")
    static let premiere = CreativeApp("premiere", "Premiere Pro", .video, short: "Premiere", apps: ["Adobe Premiere Pro"],
                                      folders: ["Premiere Pro", "Adobe Premiere Pro"], cleanHow: "媒体缓存也可在 Premiere「设置 → 媒体缓存」中删除")
    static let mediaEncoder = CreativeApp("ame", "Media Encoder", .video, apps: ["Adobe Media Encoder"], folders: ["Media Encoder", "Adobe Media Encoder"])
    static let audition = CreativeApp("audition", "Audition", .video, apps: ["Adobe Audition"], folders: ["Audition", "Adobe Audition"])
    static let adobeMedia = CreativeApp("adobe-common", "Adobe 媒体缓存", .video, short: "Adobe 软件",
                                        caches: ["Library/Application Support/Adobe/Common/Media Cache Files",
                                                 "Library/Application Support/Adobe/Common/Media Cache",
                                                 "Library/Application Support/Adobe/Common/Peak Files"],
                                        cleanHow: "AE、Premiere 共用的媒体缓存")
    static let finalCut = CreativeApp("fcp", "Final Cut Pro", .video, short: "Final Cut", apps: ["com.apple.FinalCut"],
                                      cleanHow: "渲染文件请在 Final Cut 中选中资源库，选择「文件 → 删除已生成的资源库文件」")
    static let davinci = CreativeApp("resolve", "DaVinci Resolve", .video, short: "达芬奇", apps: ["com.blackmagic-design.DaVinciResolve", "DaVinci Resolve"],
                                     folders: ["DaVinci Resolve"], cleanHow: "渲染缓存请在达芬奇中选择「播放 → 删除渲染缓存」")
    static let jianying = CreativeApp("jianying", "剪映专业版", .video, short: "剪映", apps: ["com.lemon.lvpro", "剪映专业版", "VideoFusion-macOS"],
                                      roots: ["Movies/JianyingPro"], caches: ["Movies/JianyingPro/User Data/Cache"],
                                      cleanHow: "缓存可在此清理，不影响草稿；也可在剪映「全局设置 → 清理缓存」中清理")
    static let capcut = CreativeApp("capcut", "CapCut", .video, apps: ["com.lemon.lvoverseas", "CapCut"],
                                    roots: ["Movies/CapCut"], caches: ["Movies/CapCut/User Data/Cache"])
    static let filmora = CreativeApp("filmora", "万兴喵影 Filmora", .video, short: "Filmora", apps: ["Wondershare Filmora", "万兴喵影"],
                                     folders: ["Wondershare Filmora", "Filmora"])
    static let obs = CreativeApp("obs", "OBS Studio", .video, short: "OBS", apps: ["com.obsproject.obs-studio"], folders: ["obs-studio"])
    static let topaz = CreativeApp("topaz", "Topaz Video", .video, apps: ["com.topazlabs.Topaz-Video", "Topaz Video"], folders: ["Topaz Labs LLC"])

    // 设计与三维
    static let photoshop = CreativeApp("ps", "Photoshop", .design, apps: ["Adobe Photoshop"], folders: ["Photoshop", "Adobe Photoshop"])
    static let illustrator = CreativeApp("ai", "Illustrator", .design, apps: ["Adobe Illustrator"], folders: ["Illustrator", "Adobe Illustrator"])
    static let lightroom = CreativeApp("lr", "Lightroom", .design, apps: ["Adobe Lightroom"], folders: ["Lightroom", "Adobe Lightroom", "Adobe Lightroom Classic"],
                                       roots: ["Pictures/Lightroom"], cleanHow: "预览文件请在 Lightroom「目录设置 → 文件处理」中调整")
    static let figma = CreativeApp("figma", "Figma", .design, apps: ["com.figma.Desktop"], folders: ["Figma", "com.figma.Desktop"])
    static let sketch = CreativeApp("sketch", "Sketch", .design, apps: ["com.bohemiancoding.sketch3"], folders: ["com.bohemiancoding.sketch3"])
    static let mastergo = CreativeApp("mastergo", "MasterGo", .design, apps: ["MasterGo"], folders: ["MasterGo"])
    static let jsDesign = CreativeApp("jsdesign", "即时设计", .design, apps: ["即时设计", "JsDesign"], folders: ["即时设计", "js-design", "JsDesign"])
    static let canva = CreativeApp("canva", "Canva 可画", .design, short: "Canva", apps: ["com.canva.CanvaDesktop", "Canva"], folders: ["Canva"])
    static let blender = CreativeApp("blender", "Blender", .design, apps: ["org.blenderfoundation.blender"], folders: ["Blender"])
    static let cinema4D = CreativeApp("c4d", "Cinema 4D", .design, short: "C4D", apps: ["Cinema 4D", "Maxon Cinema 4D"], folders: ["Maxon", "Redshift"])
    static let houdini = CreativeApp("houdini", "Houdini", .design, apps: ["Houdini"], roots: ["Library/Preferences/houdini"])
    static let unreal = CreativeApp("unreal", "Unreal Engine", .design, short: "虚幻引擎", apps: ["com.epicgames.EpicGamesLauncher", "Epic Games Launcher"],
                                    folders: ["Epic"], caches: ["Library/Application Support/Epic/UnrealEngine/Common/DerivedDataCache"])
    static let unity = CreativeApp("unity", "Unity", .design, apps: ["com.unity3d.unityhub", "Unity Hub"], folders: ["UnityHub", "Unity"],
                                   roots: ["Library/Unity"], caches: ["Library/Unity/cache"])

    // AI 生图与视频
    static let comfyUI = CreativeApp("comfyui", "ComfyUI", .aiCreate, apps: ["ComfyUI"], folders: ["ComfyUI"], roots: ["Documents/ComfyUI", "ComfyUI"])
    static let diffusionBee = CreativeApp("diffusionbee", "DiffusionBee", .aiCreate, apps: ["DiffusionBee"], roots: [".diffusionbee"])
    static let sdWebUI = CreativeApp("sdwebui", "Stable Diffusion WebUI", .aiCreate, short: "SD WebUI",
                                     roots: ["stable-diffusion-webui", "stable-diffusion-webui-forge"])
    static let fooocus = CreativeApp("fooocus", "Fooocus", .aiCreate, roots: ["Fooocus"])
    static let pinokio = CreativeApp("pinokio", "Pinokio", .aiCreate, apps: ["Pinokio"], folders: ["Pinokio"], roots: ["pinokio"])
    static let jimeng = CreativeApp("jimeng", "即梦", .aiCreate, apps: ["即梦", "Dreamina"], folders: ["即梦", "Dreamina", "dreamina"], roots: [".dreamina"])
    static let minimax = CreativeApp("minimax", "MiniMax Design", .aiCreate, apps: ["com.minimax.hub"], folders: ["MiniMax Design", "com.minimax.hub"])
    static let artcraft = CreativeApp("artcraft", "ArtCraft", .aiCreate, apps: ["ai.storyteller.artcraft-launcher"],
                                      folders: ["ArtCraft Launcher", "ai.storyteller.artcraft-launcher"])
    static let aigcTool = CreativeApp("aigc", "AIGC 创作辅助工具", .aiCreate, apps: ["com.aigc.director-tool"],
                                      folders: ["AIGC创作辅助工具", "com.aigc.director-tool"])

    // AI 助手
    static let chatgpt = CreativeApp("chatgpt", "ChatGPT", .aiChat, apps: ["ChatGPT", "com.openai.chat"], folders: ["ChatGPT", "com.openai.chat"])
    static let claude = CreativeApp("claude", "Claude", .aiChat, apps: ["com.anthropic.claudefordesktop"], folders: ["Claude", "Claude-3p", "com.anthropic.claudefordesktop"])
    static let perplexity = CreativeApp("perplexity", "Perplexity", .aiChat, apps: ["ai.perplexity.mac", "Perplexity"], folders: ["Perplexity"])
    static let doubao = CreativeApp("doubao", "豆包", .aiChat, apps: ["豆包", "Doubao"], folders: ["豆包", "Doubao", "doubao"])
    static let kimi = CreativeApp("kimi", "Kimi", .aiChat, apps: ["Kimi"], folders: ["Kimi", "kimi"])
    static let qianwen = CreativeApp("qianwen", "通义千问", .aiChat, short: "千问", apps: ["千问", "通义", "Qwen", "Tongyi"], folders: ["千问", "通义", "Qwen", "Tongyi", "通义千问"])
    static let yuanbao = CreativeApp("yuanbao", "腾讯元宝", .aiChat, short: "元宝", apps: ["元宝", "腾讯元宝", "Yuanbao"], folders: ["元宝", "腾讯元宝", "Yuanbao", "yuanbao"])
    static let cherryStudio = CreativeApp("cherry", "Cherry Studio", .aiChat, apps: ["Cherry Studio"], folders: ["Cherry Studio", "CherryStudio"])
    static let chatbox = CreativeApp("chatbox", "Chatbox", .aiChat, apps: ["xyz.chatboxapp.app", "Chatbox"], folders: ["xyz.chatboxapp.app", "Chatbox"])

    // AI Coding 与智能体
    static let cursor = CreativeApp("cursor", "Cursor", .aiCode, apps: ["Cursor"], folders: ["Cursor"], roots: [".cursor"], cleanHow: editorHow("Cursor"))
    static let windsurf = CreativeApp("windsurf", "Windsurf", .aiCode, apps: ["Windsurf"], folders: ["Windsurf"], roots: [".windsurf", ".codeium"],
                                      cleanHow: editorHow("Windsurf"))
    static let trae = CreativeApp("trae", "Trae", .aiCode, apps: ["Trae"], folders: ["Trae", "Trae CN"], roots: [".trae", ".trae-cn"], cleanHow: editorHow("Trae"))
    static let qoder = CreativeApp("qoder", "Qoder", .aiCode, apps: ["Qoder"], folders: ["Qoder"], roots: [".qoder"], cleanHow: editorHow("Qoder"))
    static let codebuddy = CreativeApp("codebuddy", "CodeBuddy", .aiCode, apps: ["CodeBuddy"], folders: ["CodeBuddy", "CodeBuddy CN", "CodeBuddyExtension"], roots: [".codebuddy"])
    static let workbuddy = CreativeApp("workbuddy", "WorkBuddy", .aiCode, apps: ["com.tencent.workbuddy.mac", "com.workbuddy.workbuddy", "WorkBuddy"],
                                       folders: ["WorkBuddy", "com.tencent.workbuddy.mac", "com.workbuddy.workbuddy"], roots: [".workbuddy"],
                                       caches: [".workbuddy/binaries/node/cli-connector-cache"])
    static let kiro = CreativeApp("kiro", "Kiro", .aiCode, apps: ["Kiro"], folders: ["Kiro"], roots: [".kiro"], cleanHow: editorHow("Kiro"))
    static let vscode = CreativeApp("vscode", "VS Code", .aiCode, apps: ["com.microsoft.VSCode"], folders: ["Code", "com.microsoft.VSCode"], roots: [".vscode"],
                                    cleanHow: editorHow(" VS Code "))
    static let zed = CreativeApp("zed", "Zed", .aiCode, apps: ["dev.zed.Zed"], folders: ["Zed", "dev.zed.Zed"])
    static let lingma = CreativeApp("lingma", "通义灵码", .aiCode, short: "灵码", roots: [".lingma"])
    static let comate = CreativeApp("comate", "文心快码", .aiCode, short: "Comate", roots: [".comate"])
    static let claudeCode = CreativeApp("claude-code", "Claude Code", .aiCode, folders: ["claude-cli-nodejs"], roots: [".claude"],
                                         cleanHow: "对话记录位于 ~/.claude/projects；调小 ~/.claude/settings.json 中的 cleanupPeriodDays，Claude Code 会自动删除更早的对话",
                                         iconApp: "com.anthropic.claudefordesktop")
    static let codex = CreativeApp("codex", "Codex", .aiCode, apps: ["com.openai.codex"], folders: ["Codex", "com.openai.codex"], caches: [".cache/codex-runtimes"])
    static let geminiCLI = CreativeApp("gemini-cli", "Gemini CLI", .aiCode, roots: [".gemini"])
    static let opencode = CreativeApp("opencode", "OpenCode", .aiCode, roots: [".opencode", ".local/share/opencode"])
    static let openclaw = CreativeApp("openclaw", "OpenClaw", .aiCode, roots: [".openclaw"])

    // 本地模型
    static let ollama = CreativeApp("ollama", "Ollama", .localModel, apps: ["com.electron.ollama", "Ollama"], folders: ["Ollama"], roots: [".ollama"],
                                    cleanHow: "Ollama 的模型文件相互共用，需在终端用 ollama rm 删除，此处仅显示大小")
    static let lmStudio = CreativeApp("lmstudio", "LM Studio", .localModel, apps: ["LM Studio"], folders: ["LM Studio"], roots: [".lmstudio", ".cache/lm-studio"])
    static let localModels = CreativeApp("huggingface", "Hugging Face 模型", .localModel, short: "Hugging Face", roots: [".cache/huggingface"])
    static let jan = CreativeApp("jan", "Jan", .localModel, apps: ["Jan"], folders: ["Jan"], roots: ["jan"])
    static let gpt4all = CreativeApp("gpt4all", "GPT4All", .localModel, apps: ["GPT4All"], folders: ["nomic.ai"])
    static let torch = CreativeApp("torch", "PyTorch 模型", .localModel, short: "PyTorch", roots: [".cache/torch"])

    static let allCases: [CreativeApp] = [
        afterEffects, premiere, mediaEncoder, audition, adobeMedia, finalCut, davinci, jianying, capcut, filmora, obs, topaz,
        photoshop, illustrator, lightroom, figma, sketch, mastergo, jsDesign, canva, blender, cinema4D, houdini, unreal, unity,
        comfyUI, diffusionBee, sdWebUI, fooocus, pinokio, jimeng, minimax, artcraft, aigcTool,
        chatgpt, claude, perplexity, doubao, kimi, qianwen, yuanbao, cherryStudio, chatbox,
        cursor, windsurf, trae, qoder, codebuddy, workbuddy, kiro, vscode, zed, lingma, comate, claudeCode, codex, geminiCLI, opencode, openclaw,
        ollama, lmStudio, localModels, jan, gpt4all, torch
    ]

    // MARK: Installed apps

    private struct InstalledApp: Sendable { let name: String; let id: String }
    private static let installedApps: [InstalledApp] = {
        // A demo shows only its prepared data, never which apps this Mac has.
        if AppHome.isDemo { return [] }
        let roots = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications")]
        var applications: [URL] = []
        for root in roots {
            let children = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for child in children {
                if child.pathExtension == "app" { applications.append(child) }
                else if child.lastPathComponent.hasPrefix("Adobe") || ["DaVinci Resolve", "Maxon Cinema 4D", "Blackmagic Design"].contains(child.lastPathComponent) {
                    applications += ((try? FileManager.default.contentsOfDirectory(at: child, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "app" }
                }
            }
        }
        return applications.compactMap { url in
            guard let id = Bundle(url: url)?.bundleIdentifier else { return nil }
            return InstalledApp(name: url.deletingPathExtension().lastPathComponent, id: id)
        }
    }()

    private var installedMatch: InstalledApp? {
        Self.installedApps.first { app in
            apps.contains { key in app.id == key || app.id.hasPrefix(key + ".") || app.name.hasPrefix(key) }
        }
    }

    var isInstalled: Bool { installedMatch != nil }

    /// Bundle id of the installed app (for its icon and to check whether it is running).
    var bundleID: String {
        installedMatch?.id ?? iconApp ?? apps.first { $0.hasPrefix("com.") || $0.hasPrefix("org.") || $0.hasPrefix("ai.") || $0.hasPrefix("dev.") } ?? ""
    }

    // MARK: Ownership

    private static let folderOwners: [String: CreativeApp] = {
        var owners: [String: CreativeApp] = [:]
        for app in allCases { for name in app.folders { owners[name.lowercased()] = app } }
        return owners
    }()

    /// Adobe and Blackmagic keep one folder per app inside a vendor folder ("Adobe Photoshop 2026").
    private static func vendorChild(_ name: String) -> CreativeApp? {
        if let match = folderOwners[name.lowercased()] { return match }
        return allCases.first { app in app.folders.contains { name.hasPrefix($0 + " ") } }
    }

    static let vendorFolders: Set<String> = ["Adobe", "Blackmagic Design"]

    /// Owner of a home-relative path, and whether that path lies inside the tool's ~/Library/Caches folder.
    private static func owner(relativePath: String) -> (app: CreativeApp, inCaches: Bool)? {
        for app in allCases {
            for root in app.roots + app.caches where relativePath == root || relativePath.hasPrefix(root + "/") { return (app, false) }
        }
        // ~/Library/Logs/<tool> is regenerable like Caches, not the tool's data.
        for base in ["Library/Application Support/", "Library/Caches/", "Library/Logs/"] where relativePath.hasPrefix(base) {
            let parts = relativePath.dropFirst(base.count).split(separator: "/").map(String.init)
            guard let first = parts.first else { continue }
            let inCaches = base != "Library/Application Support/"
            if first == "Adobe", parts.count > 1, parts[1] == "Common" { return inCaches ? nil : (adobeMedia, false) }
            if vendorFolders.contains(first) { return parts.count > 1 ? vendorChild(parts[1]).map { ($0, inCaches) } : nil }
            return folderOwners[first.lowercased()].map { ($0, inCaches) }
        }
        return nil
    }

    private static func relative(_ url: URL, home: URL) -> String? {
        let path = url.standardizedFileURL.path
        let prefix = home.standardizedFileURL.path + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }

    /// The tool whose data folder contains this path. Its ~/Library/Caches folder is cache, not data.
    static func dataOwner(_ url: URL, home: URL) -> CreativeApp? {
        guard let relative = relative(url, home: home), let match = owner(relativePath: relative), !match.inCaches else { return nil }
        return match.app
    }

    /// Browser-engine caches inside a tool's Application Support folder; the app rebuilds them on launch.
    private static let engineCaches: Set<String> = ["Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
                                                    "GrShaderCache", "ShaderCache", "CachedData", "CachedExtensionVSIXs", "CachedProfilesData"]

    /// Note for a cleanable cache folder that belongs to a recognized tool, nil otherwise.
    static func cacheNote(_ url: URL, home: URL) -> String? {
        guard let relative = relative(url, home: home), let match = owner(relativePath: relative) else { return nil }
        let app = match.app
        let quit = ""
        if app.caches.contains(relative) { return "\(app.title) 的缓存，下次使用时会重新生成。\(quit)" }
        let parts = relative.split(separator: "/").map(String.init)
        // ~/Library/Caches/<tool>, ~/Library/Logs/<tool> (or under Adobe / Blackmagic Design).
        if match.inCaches, parts.count >= 3, parts.count == (vendorFolders.contains(parts[2]) ? 4 : 3) {
            if parts[1] == "Logs" { return "\(app.title) 的日志，清理不影响使用。" }
            return "\(app.title) 的缓存，下次打开时会重新生成。\(quit)"
        }
        guard !match.inCaches, let name = parts.last else { return nil }
        // ~/Library/Application Support/<tool>/<engine cache>.
        if parts.count == 4, parts[0] == "Library", parts[1] == "Application Support",
           !vendorFolders.contains(parts[2]), engineCaches.contains(name) {
            return "\(app.title) 的界面缓存，下次打开时会重新生成。\(quit)"
        }
        let parent = url.deletingLastPathComponent()
        // Deeper, only inside an embedded browser profile (Electron keeps it in ~/.<tool>/app/session,
        // Partitions/<webview>…). The profile is what proves the folder is the engine's cache.
        if engineCaches.contains(name), isBrowserProfile(parent) {
            return "\(app.title) 的界面缓存，下次打开时会重新生成。\(quit)"
        }
        // Crash reports, anywhere in the tool's data.
        if ["Crashpad", "crashpad"].contains(name) {
            return "\(app.title) 的崩溃报告，清理不影响使用。"
        }
        // The tool's own log folder, directly in its top folder.
        if ["logs", "Logs", "log"].contains(name), isTopFolder(String(relative.dropLast(name.count + 1)), of: app) {
            return "\(app.title) 的日志，清理不影响使用。\(quit)"
        }
        return nil
    }

    /// A Chromium / Electron profile folder: it has a Preferences or Local State file, or sits in Partitions.
    private static func isBrowserProfile(_ url: URL) -> Bool {
        url.deletingLastPathComponent().lastPathComponent == "Partitions"
            || ["Preferences", "Local State"].contains { FileManager.default.fileExists(atPath: url.appending(path: $0).path) }
    }

    /// The tool's root folder: one of its `roots`, or its folder under Application Support (or a vendor folder there).
    private static func isTopFolder(_ relative: String, of app: CreativeApp) -> Bool {
        if app.roots.contains(relative) { return true }
        let parts = relative.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "Library", parts[1] == "Application Support" else { return false }
        return parts.count == (vendorFolders.contains(parts[2]) ? 4 : 3)
    }

    /// Existing top-level folders the quick scan should walk for recognized tools.
    static func dataLocations(home: URL) -> [URL] {
        var candidates: [URL] = allCases.flatMap { ($0.roots + $0.caches).map { home.appending(path: $0) } }
        for base in ["Library/Application Support", "Library/Caches", "Library/Logs"] {
            let root = home.appending(path: base)
            let children = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for child in children {
                if vendorFolders.contains(child.lastPathComponent) {
                    candidates += (try? FileManager.default.contentsOfDirectory(at: child, includingPropertiesForKeys: nil)) ?? []
                } else if folderOwners[child.lastPathComponent.lowercased()] != nil {
                    candidates.append(child)
                }
            }
        }
        return candidates.filter { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
            return dataOwner(url, home: home) != nil || cacheNote(url, home: home) != nil
        }
    }

    /// Render caches that must be cleaned inside the editor; listed at any size.
    static func isReviewCache(_ url: URL) -> Bool {
        url.lastPathComponent == "CacheClip" || (url.lastPathComponent == "Render Files" && url.path.contains(".fcpbundle/"))
    }

    /// Owner by path. Views ask this for every row on every redraw, and the answer never changes for a path.
    private static let ownerCache = OwnerCache()

    static func of(_ item: ScanItem) -> CreativeApp? {
        if let hit = ownerCache.value(for: item.url.path) { return hit.app }
        let app = resolveOwner(item)
        ownerCache.store(app, for: item.url.path)
        return app
    }

    private static func resolveOwner(_ item: ScanItem) -> CreativeApp? {
        let path = item.url.path
        if item.name == "Render Files", path.contains(".fcpbundle/") { return .finalCut }
        if item.name == "CacheClip" { return .davinci }
        let home = AppHome.url.standardizedFileURL.path
        if path.hasPrefix(home + "/"), let match = owner(relativePath: String(path.dropFirst(home.count + 1))) { return match.app }
        // Scans of a custom home (tests, other volumes): fall back to the first Library/ or dot-folder marker.
        for marker in ["/Library/", "/.cache/", "/.local/share/", "/Movies/", "/Pictures/", "/Documents/"] {
            if let range = path.range(of: marker),
               let match = owner(relativePath: String(path[path.index(after: range.lowerBound)...])) { return match.app }
        }
        for app in allCases {
            for root in app.roots where !root.contains("/") && (path.hasSuffix("/" + root) || path.contains("/" + root + "/")) { return app }
        }
        return nil
    }
}

/// Thread-safe memo for `CreativeApp.of`; scanning runs off the main thread too.
private final class OwnerCache: @unchecked Sendable {
    struct Entry { let app: CreativeApp? }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func value(for path: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[path]
    }

    func store(_ app: CreativeApp?, for path: String) {
        lock.lock()
        entries[path] = Entry(app: app)
        lock.unlock()
    }
}

/// Chat apps are never cleaned here; this is the guide shown on their page.
/// Paths are as the user clicked through them on 2026-10-25 (WeChat 4 and WeCom for Mac).
enum ChatGuide {
    /// The menu path to the app's storage page.
    static func path(for bundleID: String) -> [String] {
        bundleID == "com.tencent.xinWeChat"
            ? ["左下角「≡」", "设置", "账号与存储", "存储空间「管理」"]
            : ["左上角「企业微信」", "设置", "存储管理", "前往清理"]
    }

    /// What to click on that page, in order, and which part of the data each step frees.
    static func steps(for bundleID: String) -> [(title: String, text: String, kinds: [ChatPart.Kind])] {
        if bundleID == "com.tencent.xinWeChat" {
            return [("清理「缓存」", "临时文件，不影响聊天记录。", [.cache]),
                    ("管理「聊天记录」", "各聊天按占用从大到小排列，选择不需要的删除。删除后无法在本机恢复，需保留的图片和文件请先另存。", [.media, .records])]
        }
        return [("清理「缓存」", "临时文件，不影响聊天记录。", [.cache]),
                ("管理「聊天中的文件」", "文件按占用从大到小排列，选择不需要的删除。删除后无法在本机恢复，需保留的请先另存。", [.media])]
    }
}
