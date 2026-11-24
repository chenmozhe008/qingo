import Foundation

/// Safe, fixed-command macOS maintenance and Spotlight repair service (inspired by OnyX & Mole).
///
/// Security invariants:
/// - Never interpolates user-controlled paths into privileged shell strings.
/// - Every privileged command is a compile-time constant invoking official Apple system tools (`mdutil`, `du`).
struct SpotlightRepairService: Sendable {
    struct AdminProbeSizes: Equatable, Sendable {
        let spotlightBytes: Int64
        let systemLogsBytes: Int64
        let systemCachesBytes: Int64
        let aerialWallpapersBytes: Int64
    }

    typealias AdminScriptRunner = @Sendable (_ shellCommand: String, _ prompt: String) throws -> String

    let runAdmin: AdminScriptRunner

    init(runAdmin: @escaping AdminScriptRunner = Self.defaultRunAdmin) {
        self.runAdmin = runAdmin
    }

    /// DaisyDisk-style single-prompt read-only probe of root-protected storage black holes.
    func probeSystemBlackHoles() throws -> AdminProbeSizes {
        guard !AppHome.isDemo else {
            return AdminProbeSizes(spotlightBytes: 0, systemLogsBytes: 0, systemCachesBytes: 0, aerialWallpapersBytes: 0)
        }
        let command = """
        k1=$(/usr/bin/du -sk /System/Volumes/Data/.Spotlight-V100 2>/dev/null | /usr/bin/awk '{print $1}'); \
        k2=$(/usr/bin/du -sk /private/var/log 2>/dev/null | /usr/bin/awk '{print $1}'); \
        k3=$(/usr/bin/du -sk /Library/Caches 2>/dev/null | /usr/bin/awk '{print $1}'); \
        k4=$(/usr/bin/du -sk "/Library/Application Support/com.apple.idleassetsd" 2>/dev/null | /usr/bin/awk '{print $1}'); \
        echo "${k1:-0}|${k2:-0}|${k3:-0}|${k4:-0}"
        """
        let out = try runAdmin(command, "小清需要管理员权限以只读方式查看系统级隐藏占用（聚焦搜索索引、系统日志与航拍壁纸）。")
        return Self.parseProbeOutput(out)
    }

    static func parseProbeOutput(_ output: String) -> AdminProbeSizes {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "|").map { Int64($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
        let k1 = parts.count > 0 ? max(0, parts[0]) * 1024 : 0
        let k2 = parts.count > 1 ? max(0, parts[1]) * 1024 : 0
        let k3 = parts.count > 2 ? max(0, parts[2]) * 1024 : 0
        let k4 = parts.count > 3 ? max(0, parts[3]) * 1024 : 0
        return AdminProbeSizes(spotlightBytes: k1, systemLogsBytes: k2, systemCachesBytes: k3, aerialWallpapersBytes: k4)
    }

    /// Rebuilds the macOS Spotlight index safely using Apple's official `mdutil` utility.
    /// Clears corrupted/bloated `.Spotlight-V100` metadata and triggers a clean background re-index.
    func rebuildSpotlightIndex() throws {
        guard !AppHome.isDemo else { return }
        let command = "/usr/bin/mdutil -i off / >/dev/null 2>&1 || true; /usr/bin/mdutil -E / >/dev/null 2>&1; /usr/bin/mdutil -i on / >/dev/null 2>&1"
        _ = try runAdmin(command, "小清需要管理员权限来重置并重建 macOS 聚焦搜索（Spotlight）索引。")
    }

    /// Removes downloaded 4K aerial wallpaper cache videos (macOS re-downloads the active one automatically if needed).
    func cleanAerialWallpaperCache() throws {
        guard !AppHome.isDemo else { return }
        let command = "/usr/bin/find '/Library/Application Support/com.apple.idleassetsd/Customer' -type f -name '*.mov' -delete 2>/dev/null || true"
        _ = try runAdmin(command, "小清需要管理员权限来清理系统下载的 4K 航拍动态壁纸缓存视频。")
    }

    /// Flushes DNS cache and refreshes LaunchServices registration (non-destructive OnyX-style maintenance).
    static func runQuickSystemMaintenance() -> String {
        guard !AppHome.isDemo else { return "演示模式下不执行系统维护。" }
        var done: [String] = []
        if runTool("/usr/bin/qlmanage", ["-r", "cache"]) { done.append("文件预览缩略图缓存") }
        if runTool("/usr/bin/dscacheutil", ["-flushcache"]) { done.append("DNS 缓存") }
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        if FileManager.default.isExecutableFile(atPath: lsregister),
           runTool(lsregister, ["-r", "-domain", "local", "-domain", "user"]) {
            done.append("文件打开方式索引")
        }
        return done.isEmpty ? "未完成系统维护。" : "已刷新：\(done.joined(separator: "、"))。"
    }

    private static func runTool(_ path: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func defaultRunAdmin(_ shellCommand: String, _ prompt: String) throws -> String {
        let escapedCmd = shellCommand.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let escapedPrompt = prompt.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        try
            set res to do shell script "\(escapedCmd)" with prompt "\(escapedPrompt)" with administrator privileges
            return "OK:" & res
        on error messageText number errorNumber
            return "ERROR:" & errorNumber & ":" & messageText
        end try
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        try process.run()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("OK:") {
            return String(text.dropFirst(3))
        }
        let parts = text.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        let code = parts.count > 1 ? (Int(parts[1]) ?? -1) : -1
        let msg = parts.count > 2 ? String(parts[2]) : "管理员授权已取消或执行失败"
        throw NSError(domain: "Qingo.AdminRepair", code: code, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
