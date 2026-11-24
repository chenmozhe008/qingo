import Foundation

/// 「空间分布」页的数据（2026-11-06 用户看效果图 `output/mockups/s-map/d-combined.png` 后定）：
/// 整台 Mac 按「需要确认 / 无法清理」两区分块，每块写是什么、多大、能去哪里处理。
/// 可直接清理的部分不在这里量，显示时取当前扫描结果（`ScanStore.eligibleItems`）。
struct SpaceMap: Codable, Sendable {
    enum Section: String, Codable, Sendable { case decide, fixed }
    /// 块上的按钮把人带到哪里；nil 表示只显示大小
    enum Action: String, Codable, Sendable { case uninstall, largeFiles, chat, dev, softwareUpdate, trash }

    struct Block: Codable, Sendable, Identifiable {
        let id: String
        let title: String
        let bytes: Int64
        let note: String
        let section: Section
        let action: Action?
    }

    let measuredAt: Date
    let total: Int64
    let available: Int64
    /// 不含「其他」：其他＝已用 − 各块 − 可直接清理，显示时再算（可清理的随扫描变）
    let blocks: [Block]

    struct TrashOccupancy: Codable, Sendable {
        let bytes: Int64?
    }

    var trashOccupancy: TrashOccupancy?
    var sharedBrowserCopies: Leftovers.SharedCopies?

    var used: Int64 { max(total - available, 0) }

    /// 量不到明细的部分：系统数据、沙盒容器、照片图库以外的资料库等
    func remainder(cleanable: Int64) -> Int64 {
        max(used - blocks.reduce(0) { $0 + $1.bytes } - cleanable, 0)
    }

    static var fileURL: URL { AppHome.resultsDirectory.appending(path: "space-map.json") }

    static func load() -> SpaceMap? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(SpaceMap.self, from: data)
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try? encoder.encode(self).write(to: Self.fileURL, options: .atomic)
    }
}

/// 量各块的大小。按已分配空间算（和访达「磁盘上的大小」一致），不读沙盒容器（读了会弹系统授权框）。
/// 很慢（要走遍应用程序和个人文件夹），在后台跑。
struct SpaceMapper: Sendable {
    let home: URL
    let devRoot: URL
    /// 扫描结果里微信、企业微信、飞书的占用（只读量过）
    let chatBytes: Int64

    private static let aiGroups: [CreativeApp.Group] = [.aiChat, .aiCode, .localModel]
    /// 规则里受保护、不登记为工具数据的 AI 目录，量空间时也算进 AI 工具数据
    private static let aiExtraRoots = [".codex"]

    func measure(onProgress: @Sendable (String) -> Void = { _ in }) -> SpaceMap {
        let volume = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]))
        let total = Int64(volume?.volumeTotalCapacity ?? 0)
        let available = volume?.volumeAvailableCapacityForImportantUsage ?? 0
        var blocks: [SpaceMap.Block] = []
        let fm = FileManager.default
        // 应用程序、Homebrew、系统数据属于整台 Mac：只在量当前用户自己的个人文件夹时带上（演示、测试用的是别的文件夹）
        let wholeMac = !AppHome.isDemo && CanonicalPath.url(home) == CanonicalPath.url(fm.homeDirectoryForCurrentUser)

        onProgress("应用程序")
        let appRoots = !wholeMac ? [] : [URL(fileURLWithPath: "/Applications"), home.appending(path: "Applications")]
        blocks.append(.init(id: "apps", title: "应用程序", bytes: appRoots.reduce(0) { $0 + Self.size(of: $1) },
                            note: "长期不用的可以卸载", section: .decide, action: .uninstall))

        // AI 工具的对话、模型：~/.codex、~/.claude 这类，加上它们在 Application Support 里的文件夹
        onProgress("AI 工具数据")
        let aiTools = CreativeApp.allCases.filter { Self.aiGroups.contains($0.group) }
        let aiRoots = Set((aiTools.flatMap(\.roots) + Self.aiExtraRoots).map { home.appending(path: $0).standardizedFileURL.path })
        let aiSupport = Set(aiTools.flatMap(\.folders))
        let support = home.appending(path: "Library/Application Support")
        var aiBytes = aiRoots.reduce(Int64(0)) { $0 + Self.size(of: URL(fileURLWithPath: $1)) }
        for name in aiSupport { aiBytes += Self.size(of: support.appending(path: name)) }
        blocks.append(.init(id: "ai", title: "AI 工具数据", bytes: aiBytes,
                            note: "对话记录和模型", section: .decide, action: nil))

        onProgress("开发项目")
        let dev = fm.fileExists(atPath: devRoot.path) ? Self.size(of: devRoot) : 0
        blocks.append(.init(id: "dev", title: "开发项目", bytes: dev, note: devRoot.path.replacingOccurrences(of: home.path, with: "~"),
                            section: .decide, action: .dev))

        // 资料：个人文件夹里看得见的文件夹和文件，去掉资源库、应用程序和开发项目
        onProgress("资料与作品")
        var documents: Int64 = 0
        let devPath = devRoot.standardizedFileURL.path
        for entry in (try? fm.contentsOfDirectory(at: home, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
            let name = entry.lastPathComponent
            guard !["Library", "Applications"].contains(name) else { continue }
            let path = entry.standardizedFileURL.path
            if path == devPath { continue }
            var bytes = Self.size(of: entry)
            if devPath.hasPrefix(path + "/") { bytes = max(bytes - dev, 0) }
            documents += bytes
        }
        blocks.append(.init(id: "documents", title: "资料与作品", bytes: documents, note: "文稿、下载、图片等",
                            section: .decide, action: .largeFiles))

        blocks.append(.init(id: "chat", title: "微信等聊天", bytes: chatBytes, note: "在应用里管理聊天记录",
                            section: .decide, action: .chat))

        // 废纸篓：清空后才腾出空间，单独列出提醒（小清不替用户清空）
        let trashOccupancy = trashOccupancyForHome()
        if let trash = trashOccupancy.bytes, trash > 0 {
            blocks.append(.init(id: "trash", title: "废纸篓", bytes: trash, note: "仍占用磁盘空间，可在访达中查看。",
                                section: .decide, action: .trash))
        }

        // 开发环境：个人文件夹里的隐藏目录（语言环境、包缓存、命令行工具），加上 Homebrew
        onProgress("开发环境")
        var tooling: Int64 = 0
        for entry in (try? fm.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? [] {
            let name = entry.lastPathComponent
            guard name.hasPrefix("."), name != ".Trash", !aiRoots.contains(entry.standardizedFileURL.path) else { continue }
            tooling += Self.size(of: entry)
        }
        if wholeMac {
            for path in ["/opt/homebrew", "/usr/local"] { tooling += Self.size(of: URL(fileURLWithPath: path)) }
        }
        blocks.append(.init(id: "tooling", title: "开发环境", bytes: tooling, note: "语言环境和命令行工具",
                            section: .fixed, action: nil))

        onProgress("macOS")
        blocks.append(.init(id: "system", title: "macOS 系统", bytes: Self.systemVolumesBytes(),
                            note: "系统和恢复分区", section: .fixed, action: nil))

        // 其他 App 的数据：Application Support 里除聊天和 AI 工具以外的文件夹
        onProgress("其他 App 的数据")
        let chatRoots = Set(ChatCache.apps.map { ChatCache.root(of: $0, home: home).standardizedFileURL.path })
        var appData: Int64 = 0
        for entry in (try? fm.contentsOfDirectory(at: support, includingPropertiesForKeys: nil)) ?? [] {
            let path = entry.standardizedFileURL.path
            guard !chatRoots.contains(path), !aiSupport.contains(entry.lastPathComponent) else { continue }
            appData += Self.size(of: entry)
        }
        blocks.append(.init(id: "appdata", title: "其他 App 的数据", bytes: appData, note: "各应用的设置和资料",
                            section: .fixed, action: nil))

        // 系统数据：系统资源和模型、日志、临时文件、所有用户共用的文件（只读得到的部分）
        if wholeMac {
            onProgress("系统数据")
            var systemData: Int64 = 0
            for path in ["/Library", "/System/Volumes/Data/System/Library/AssetsV2", "/Users/Shared"] {
                systemData += Self.size(of: URL(fileURLWithPath: path))
            }
            // 虚拟内存（vm）是单独的卷，已算进 macOS 系统
            for entry in (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "/private/var"), includingPropertiesForKeys: nil)) ?? []
            where entry.lastPathComponent != "vm" {
                systemData += Self.size(of: entry)
            }
            blocks.append(.init(id: "systemdata", title: "系统数据", bytes: systemData, note: "系统资源、日志和临时文件",
                                section: .fixed, action: nil))
        }

        return SpaceMap(measuredAt: Date(), total: total, available: available, blocks: blocks,
                        trashOccupancy: trashOccupancy, sharedBrowserCopies: wholeMac ? Leftovers.sharedBrowserCopies() : nil)
    }

    private func trashOccupancyForHome() -> SpaceMap.TrashOccupancy {
        SpaceMap.TrashOccupancy(bytes: DirectoryOccupancy.bytes(at: home.appending(path: ".Trash"), missingIsEmpty: true))
    }

    /// 已分配空间（底层 `getattrlistbulk` 批量读取，不跟随符号链接，硬链接去重，读不了的跳过）
    static func size(of url: URL) -> Int64 {
        FastSizeCalculator.allocatedBytes(of: url)
    }

    /// 启动盘所在 APFS 容器里系统、预启动、恢复、虚拟内存几个卷的占用（`diskutil apfs list -plist`）
    static func systemVolumesBytes() -> Int64 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["apfs", "list", "-plist"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return 0 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let containers = plist["Containers"] as? [[String: Any]] else { return 0 }
        let wanted: Set<String> = ["System", "Preboot", "Recovery", "VM"]
        for container in containers {
            let volumes = container["Volumes"] as? [[String: Any]] ?? []
            let roles = volumes.map { Set($0["Roles"] as? [String] ?? []) }
            // 有「系统」和「数据」两个卷的那个容器就是启动盘
            guard roles.contains(where: { $0.contains("System") }), roles.contains(where: { $0.contains("Data") }) else { continue }
            return zip(volumes, roles).reduce(Int64(0)) { sum, pair in
                pair.1.isDisjoint(with: wanted) ? sum : sum + ((pair.0["CapacityInUse"] as? NSNumber)?.int64Value ?? 0)
            }
        }
        return 0
    }
}
