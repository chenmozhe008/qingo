import Foundation

/// Safe, allowlisted CLI cleanup adapters that invoke official toolchain prune commands
/// instead of raw `rm` on link-sensitive stores (Homebrew, pnpm, uv, Xcode Simulators, Docker, QuickLook).
///
/// Security invariants:
/// - Never invokes a shell (`/bin/sh -c`); always passes explicit executable paths and argument arrays.
/// - Enforces strict timeouts on every subprocess.
/// - Supports dry-run / inspection before execution so users see what will happen.
struct CLICleanerAdapters: Sendable {
    struct CommandOutput: Equatable, Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    typealias Runner = @Sendable (_ executable: String, _ arguments: [String], _ timeout: TimeInterval) throws -> CommandOutput

    enum AdapterID: String, CaseIterable, Identifiable, Sendable {
        case homebrew
        case pnpm
        case uv
        case xcodeSimulators
        case docker
        case quickLook

        var id: String { rawValue }

        var title: String {
            switch self {
            case .homebrew: "Homebrew 旧安装包与缓存"
            case .pnpm: "pnpm 共享依赖缓存"
            case .uv: "uv 依赖包缓存"
            case .xcodeSimulators: "已失效的旧模拟器设备"
            case .docker: "Docker 构建缓存与悬空镜像"
            case .quickLook: "访达文件预览缩略图缓存"
            }
        }

        var detail: String {
            switch self {
            case .homebrew: "使用官方命令清理旧安装包与下载缓存，不影响当前已装软件。"
            case .pnpm: "仅移除未被项目引用的旧依赖包，不影响现有代码项目。"
            case .uv: "仅移除未被使用的缓存包，不影响现有 Python 环境。"
            case .xcodeSimulators: "移除不再兼容的旧模拟器设备，可按需重新下载。"
            case .docker: "仅清理构建缓存与悬空镜像，不删除容器数据卷。"
            case .quickLook: "重置访达文件预览生成的缩略图缓存，浏览文件时自动重建。"
            }
        }

        var symbol: String {
            switch self {
            case .homebrew: "shippingbox"
            case .pnpm: "square.stack.3d.up"
            case .uv: "cube"
            case .xcodeSimulators: "iphone"
            case .docker: "server.rack"
            case .quickLook: "eye"
            }
        }
    }

    struct ProbeResult: Identifiable, Equatable, Sendable {
        let id: AdapterID
        let available: Bool
        let executablePath: String?
        let estimatedBytes: Int64?
        let summary: String
    }

    struct ExecutionResult: Equatable, Sendable {
        let id: AdapterID
        let succeeded: Bool
        let message: String
    }

    let home: URL
    let run: Runner
    let resolveExecutable: @Sendable (String) -> String?

    init(home: URL = AppHome.url,
         run: @escaping Runner = Self.defaultRun,
         resolveExecutable: @escaping @Sendable (String) -> String? = Self.defaultResolveExecutable) {
        self.home = home
        self.run = run
        self.resolveExecutable = resolveExecutable
    }

    func probeAll() -> [ProbeResult] {
        AdapterID.allCases.map { probe($0) }
    }

    func probe(_ id: AdapterID) -> ProbeResult {
        switch id {
        case .homebrew:
            guard let bin = resolveExecutable("brew") else {
                return ProbeResult(id: id, available: false, executablePath: nil, estimatedBytes: nil, summary: "未安装 Homebrew")
            }
            let cacheSize = Self.directoryAllocatedSize(home.appending(path: "Library/Caches/Homebrew"))
            if let out = try? run(bin, ["cleanup", "--prune=all", "-n"], 12), out.status == 0 {
                let count = out.stdout.split(whereSeparator: \.isNewline).filter { $0.contains("Would remove:") }.count
                let text = count > 0 ? "可清理 \(count) 项旧包与缓存" : (cacheSize > 0 ? "下载缓存约 \(ByteFormat.string(cacheSize))" : "当前无需清理")
                return ProbeResult(id: id, available: true, executablePath: bin, estimatedBytes: cacheSize > 0 ? cacheSize : nil, summary: text)
            }
            return ProbeResult(id: id, available: true, executablePath: bin, estimatedBytes: cacheSize > 0 ? cacheSize : nil, summary: "已安装，可执行 brew cleanup")

        case .pnpm:
            guard let bin = resolveExecutable("pnpm") else {
                return ProbeResult(id: id, available: false, executablePath: nil, estimatedBytes: nil, summary: "未安装 pnpm")
            }
            let store = home.appending(path: "Library/pnpm/store")
            let bytes = Self.directoryAllocatedSize(store)
            let summary = bytes > 0 ? "共享存储总计约 \(ByteFormat.string(bytes))，可清理未使用的旧包" : "已安装 pnpm"
            return ProbeResult(id: id, available: true, executablePath: bin, estimatedBytes: bytes > 0 ? bytes : nil, summary: summary)

        case .uv:
            guard let bin = resolveExecutable("uv") else {
                return ProbeResult(id: id, available: false, executablePath: nil, estimatedBytes: nil, summary: "未安装 uv")
            }
            let bytes = Self.directoryAllocatedSize(home.appending(path: ".cache/uv"))
                + Self.directoryAllocatedSize(home.appending(path: "Library/Caches/uv"))
            let summary = bytes > 0 ? "包缓存总计约 \(ByteFormat.string(bytes))，可安全清理" : "已安装 uv"
            return ProbeResult(id: id, available: true, executablePath: bin, estimatedBytes: bytes > 0 ? bytes : nil, summary: summary)

        case .xcodeSimulators:
            guard let bin = resolveExecutable("xcrun"),
                  let out = try? run(bin, ["simctl", "list", "devices", "unavailable"], 10),
                  out.status == 0 else {
                return ProbeResult(id: id, available: false, executablePath: nil, estimatedBytes: nil, summary: "未检测到 Xcode 模拟器工具")
            }
            let count = out.stdout.split(whereSeparator: \.isNewline).filter { $0.contains("(") && $0.contains(")") && !$0.hasPrefix("--") }.count
            let summary = count > 0 ? "发现 \(count) 个不可用旧模拟器设备" : "当前无不可用模拟器"
            return ProbeResult(id: id, available: true, executablePath: bin, estimatedBytes: nil, summary: summary)

        case .docker:
            guard let bin = resolveExecutable("docker") else {
                return ProbeResult(id: id, available: false, executablePath: nil, estimatedBytes: nil, summary: "未安装 Docker")
            }
            guard let out = try? run(bin, ["system", "df", "--format", "{{.Type}}:{{.Reclaimable}}"], 8), out.status == 0 else {
                return ProbeResult(id: id, available: true, executablePath: bin, estimatedBytes: nil, summary: "Docker 未运行，启动后可清理")
            }
            let lines = out.stdout.split(whereSeparator: \.isNewline).map(String.init)
            let summary = lines.isEmpty ? "Docker 运行中，可安全清理无用镜像与缓存" : lines.joined(separator: " / ")
            return ProbeResult(id: id, available: true, executablePath: bin, estimatedBytes: nil, summary: summary)

        case .quickLook:
            let bin = "/usr/bin/qlmanage"
            guard FileManager.default.isExecutableFile(atPath: bin) else {
                return ProbeResult(id: id, available: false, executablePath: nil, estimatedBytes: nil, summary: "系统工具不可用")
            }
            return ProbeResult(id: id, available: true, executablePath: bin, estimatedBytes: nil, summary: "重置文件预览缩略图缓存")
        }
    }

    func execute(_ id: AdapterID) -> ExecutionResult {
        guard !AppHome.isDemo else {
            return ExecutionResult(id: id, succeeded: false, message: "演示模式下不执行系统命令。")
        }
        switch id {
        case .homebrew:
            guard let bin = resolveExecutable("brew") else {
                return ExecutionResult(id: id, succeeded: false, message: "未找到 brew 可执行文件。")
            }
            return runSimple(id: id, executable: bin, arguments: ["cleanup", "--prune=all"], timeout: 120, successLabel: "Homebrew 缓存已清理。")

        case .pnpm:
            guard let bin = resolveExecutable("pnpm") else {
                return ExecutionResult(id: id, succeeded: false, message: "未找到 pnpm 可执行文件。")
            }
            return runSimple(id: id, executable: bin, arguments: ["store", "prune"], timeout: 120, successLabel: "pnpm 共享存储已清理。")

        case .uv:
            guard let bin = resolveExecutable("uv") else {
                return ExecutionResult(id: id, succeeded: false, message: "未找到 uv 可执行文件。")
            }
            return runSimple(id: id, executable: bin, arguments: ["cache", "prune"], timeout: 120, successLabel: "uv 缓存已清理。")

        case .xcodeSimulators:
            guard let bin = resolveExecutable("xcrun") else {
                return ExecutionResult(id: id, succeeded: false, message: "未找到 xcrun。")
            }
            return runSimple(id: id, executable: bin, arguments: ["simctl", "delete", "unavailable"], timeout: 60, successLabel: "不可用模拟器已清理。")

        case .docker:
            guard let bin = resolveExecutable("docker") else {
                return ExecutionResult(id: id, succeeded: false, message: "未找到 docker。")
            }
            let builder = runSimple(id: id, executable: bin, arguments: ["builder", "prune", "-f"], timeout: 120, successLabel: "构建缓存已清理")
            guard builder.succeeded else { return builder }
            let images = runSimple(id: id, executable: bin, arguments: ["image", "prune", "-f"], timeout: 120, successLabel: "Docker 构建缓存与悬空镜像已清理。")
            return images

        case .quickLook:
            return runSimple(id: id, executable: "/usr/bin/qlmanage", arguments: ["-r", "cache"], timeout: 20, successLabel: "QuickLook 缩略图缓存已重置。")
        }
    }

    private func runSimple(id: AdapterID, executable: String, arguments: [String], timeout: TimeInterval, successLabel: String) -> ExecutionResult {
        do {
            let out = try run(executable, arguments, timeout)
            if out.status == 0 {
                return ExecutionResult(id: id, succeeded: true, message: successLabel)
            }
            let detail = (out.stderr.isEmpty ? out.stdout : out.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            return ExecutionResult(id: id, succeeded: false, message: detail.isEmpty ? "命令执行失败（退出码 \(out.status)）。" : String(detail.prefix(180)))
        } catch {
            return ExecutionResult(id: id, succeeded: false, message: "命令执行超时或无法启动。")
        }
    }

    static func defaultResolveExecutable(_ name: String) -> String? {
        let searchPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            NSHomeDirectory() + "/.local/bin",
            NSHomeDirectory() + "/.cargo/bin",
            NSHomeDirectory() + "/Library/pnpm"
        ]
        let fm = FileManager.default
        for dir in searchPaths {
            let candidate = dir + "/" + name
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static func defaultRun(_ executable: String, _ arguments: [String], _ timeout: TimeInterval) throws -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        let extraPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = extraPath + ":" + (env["PATH"] ?? "")
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()

        // Drain stdout and stderr concurrently BEFORE waiting for exit to prevent the 64KB Unix pipe deadlock.
        final class PipeBuffer: @unchecked Sendable {
            private let lock = NSLock()
            private var data = Data()
            func set(_ d: Data) { lock.withLock { data = d } }
            func get() -> Data { lock.withLock { data } }
        }
        let stdoutBuf = PipeBuffer()
        let stderrBuf = PipeBuffer()
        let ioGroup = DispatchGroup()

        ioGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutBuf.set(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            ioGroup.leave()
        }

        ioGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrBuf.set(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            ioGroup.leave()
        }

        if done.wait(timeout: .now() + timeout) != .success {
            process.terminate()
            _ = ioGroup.wait(timeout: .now() + 2)
            throw NSError(domain: "Qingo.CLICleaner", code: -1, userInfo: [NSLocalizedDescriptionKey: "timeout"])
        }
        _ = ioGroup.wait(timeout: .now() + 5)
        return CommandOutput(
            status: process.terminationStatus,
            stdout: String(decoding: stdoutBuf.get(), as: UTF8.self),
            stderr: String(decoding: stderrBuf.get(), as: UTF8.self)
        )
    }

    private static func directoryAllocatedSize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return 0 }
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
