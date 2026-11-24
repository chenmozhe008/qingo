import Darwin
import Foundation

enum DiagnosticJunk {
    static let note = "30 天前的诊断报告。保留近期报告用于排查故障。"

    private static func roots(_ home: URL) -> [URL] {
        let root = home.appending(path: "Library/Logs/DiagnosticReports")
        return [root, root.appending(path: "Retired")]
    }

    /// Only individual, user-owned reports. The diagnostic directories and ordinary logs stay in place.
    static func recognizes(_ url: URL, home: URL) -> Bool {
        ["ips", "crash", "hang", "spin"].contains(url.pathExtension.lowercased()) &&
            roots(home).contains { $0.path == url.deletingLastPathComponent().path }
    }

    static func eligible(_ url: URL, home: URL, now: Date = Date()) -> Bool {
        guard recognizes(url, home: home), CanonicalPath.isDirect(url) else { return false }
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_size > 0 else { return false }
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        return now.timeIntervalSince(modified) > 30 * 86_400
    }

    static func find(home: URL) -> [URL] {
        let now = Date()
        return roots(home).flatMap { directory in
            guard CanonicalPath.isDirect(directory) else { return [] as [URL] }
            return (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles])) ?? []
        }.filter { eligible($0, home: home, now: now) }
    }
}
