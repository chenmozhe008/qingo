import Foundation
import Darwin

/// What each cleanup moved to the Trash, kept on disk so a problem reported days later can still be traced.
/// Paths under the home folder are stored as "~/…", so the log carries no user name.
enum CleanupLog {
    struct Entry: Codable, Equatable {
        struct Moved: Codable, Equatable {
            let path: String
            let bytes: Int64
        }

        let date: Date
        /// "清理" / "卸载 微信" / "清理残留"
        let action: String
        let moved: [Moved]
        let failedCount: Int
    }

    static let limit = 10

    private static var file: URL { AppHome.resultsDirectory.deletingLastPathComponent().appending(path: "cleanup-log.json") }

    static func load() -> [Entry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    /// Newest first, at most `limit` entries. Nothing moved, nothing recorded.
    static func record(_ action: String, moved: [(url: URL, bytes: Int64)], failedCount: Int, now: Date = Date()) {
        guard !moved.isEmpty else { return }
        let entry = Entry(date: now, action: action,
                          moved: moved.map { Entry.Moved(path: display($0.url), bytes: $0.bytes) }, failedCount: failedCount)
        let entries = Array(([entry] + load()).prefix(limit))
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: file, options: .atomic) }
    }

    static func display(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        let home = AppHome.url.standardizedFileURL.path
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// The text behind 「复制诊断信息」: only what helps trace a bug, shown in full on the feedback page before it is sent.
enum Diagnostics {
    static let listedItems = 15

    static func report(now: Date = Date()) -> String {
        var lines = [AppInfo.diagnostics]
        lines.append("Mac：\(sysctlString("hw.model") ?? "未知")，内存 \(ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory))")
        let volume = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        if let free = volume?.volumeAvailableCapacityForImportantUsage, let total = volume?.volumeTotalCapacity {
            lines.append("可用空间：\(ByteFormat.string(free))，共 \(ByteFormat.string(Int64(total)))")
        }
        let fullDisk = (try? FileManager.default.contentsOfDirectory(atPath: AppHome.url.appending(path: "Library/Safari").path)) != nil
        lines.append("完全磁盘访问：\(fullDisk ? "已开启" : "未开启")")

        lines.append("")
        if let last = CleanupLog.load().first {
            let bytes = last.moved.reduce(Int64(0)) { $0 + $1.bytes }
            let time = last.date.formatted(.dateTime.year().month().day().hour().minute())
            lines.append("最近一次\(last.action)：\(time)，移到废纸篓 \(last.moved.count) 项，共 \(ByteFormat.string(bytes))"
                         + (last.failedCount > 0 ? "，\(last.failedCount) 项未清理" : ""))
            for item in last.moved.sorted(by: { $0.bytes > $1.bytes }).prefix(listedItems) {
                lines.append("  \(item.path)　\(ByteFormat.string(item.bytes))")
            }
            if last.moved.count > listedItems { lines.append("  等 \(last.moved.count - listedItems) 项") }
        } else {
            lines.append("最近一次清理：无记录")
        }

        lines.append("")
        let reports = recentReports(now: now)
        lines.append(reports.isEmpty ? "近 3 天的崩溃与无响应记录：无" : "近 3 天的崩溃与无响应记录：")
        lines += reports.map { "  \($0)" }
        return lines.joined(separator: "\n")
    }

    /// Report file names only, e.g. "Finder 2026-10-30 14:05:12（无响应）". The computer name after the date is dropped.
    static func recentReports(now: Date = Date(), limit: Int = 15) -> [String] {
        let folders = [AppHome.url.appending(path: "Library/Logs/DiagnosticReports"), URL(fileURLWithPath: "/Library/Logs/DiagnosticReports")]
        let kinds = ["ips": "崩溃", "crash": "崩溃", "hang": "无响应", "spin": "无响应"]
        var found: [(date: Date, text: String)] = []
        for folder in folders {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files {
                guard let kind = kinds[file.pathExtension],
                      let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      now.timeIntervalSince(date) < 3 * 86_400,
                      let range = file.lastPathComponent.range(of: #"[-_]\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression)
                else { continue }
                let process = String(file.lastPathComponent[..<range.lowerBound])
                // Shared system reports (ExcUserFault_…, JetsamEvent…) say nothing about one app.
                guard !process.isEmpty, !process.hasPrefix("ExcUserFault"), !process.hasPrefix("JetsamEvent") else { continue }
                found.append((date, "\(process)　\(date.formatted(.dateTime.month().day().hour().minute().second()))（\(kind)）"))
            }
        }
        return found.sorted { $0.date > $1.date }.prefix(limit).map(\.text)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
}
