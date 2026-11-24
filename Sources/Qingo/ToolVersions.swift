import Darwin
import Foundation

struct ToolVersions: Sendable {
    let home: URL

    struct Tool: Sendable {
        let name: String
        let versions: String
        let launcher: String
        let executable: String?
        let pattern: String

        static let supported = [
            Tool(name: "Claude Code", versions: ".local/share/claude/versions", launcher: ".local/bin/claude",
                 executable: nil, pattern: #"^[0-9]+\.[0-9]+\.[0-9]+$"#),
            Tool(name: "Cursor Agent", versions: ".local/share/cursor-agent/versions", launcher: ".local/bin/cursor-agent",
                 executable: "cursor-agent", pattern: #"^[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9a-f]{7,40}$"#)
        ]
    }

    func tool(for url: URL) -> Tool? {
        Tool.supported.first { tool in
            url.deletingLastPathComponent().path == home.appending(path: tool.versions).path &&
                url.lastPathComponent.range(of: tool.pattern, options: .regularExpression) != nil
        }
    }

    func candidates(for tool: Tool) -> [URL] {
        let root = home.appending(path: tool.versions, directoryHint: .isDirectory)
        let launcher = home.appending(path: tool.launcher)
        guard CanonicalPath.url(root).path == root.path,
              CanonicalPath.url(launcher.deletingLastPathComponent()).path == launcher.deletingLastPathComponent().path,
              let info = try? launcher.resourceValues(forKeys: [.isSymbolicLinkKey]), info.isSymbolicLink == true,
              let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }

        let active = CanonicalPath.url(launcher).path
        let installed = entries.filter { entry in
            self.tool(for: entry) != nil && ownedExecutable(at: executable(in: entry, for: tool)) &&
                (tool.executable == nil || owned(entry, type: S_IFDIR))
        }
        guard let current = installed.first(where: { executable(in: $0, for: tool).path == active }) else { return [] }
        let older = installed.filter {
            $0.lastPathComponent.compare(current.lastPathComponent, options: .numeric) == .orderedAscending &&
                // Cursor builds can share a date; their commit hashes do not establish release order.
                (tool.executable == nil || $0.lastPathComponent.prefix(10) < current.lastPathComponent.prefix(10))
        }
        if tool.executable != nil {
            guard let previous = older.map({ $0.lastPathComponent.prefix(10) }).max() else { return [] }
            return older.filter { $0.lastPathComponent.prefix(10) < previous }
        }
        return Array(older.sorted {
            $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending
        }.dropFirst())
    }

    func find() -> [Leftovers.Found] {
        Tool.supported.flatMap { tool in
            candidates(for: tool).compactMap { url in
                guard (try? TrashService.ensureUnused(url, isDirectory: tool.executable != nil)) != nil else { return nil }
                let bytes: Int64
                if tool.executable == nil {
                    bytes = Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
                } else {
                    bytes = Leftovers.allocatedSize(url)
                }
                return Leftovers.Found(url: url, bytes: bytes,
                    note: "\(tool.name) 的旧版本。保留当前版本和上一版。")
            }
        }
    }

    private func executable(in entry: URL, for tool: Tool) -> URL {
        tool.executable.map { entry.appending(path: $0) } ?? entry
    }

    private func ownedExecutable(at url: URL) -> Bool {
        owned(url, type: S_IFREG) && FileManager.default.isExecutableFile(atPath: url.path)
    }

    private func owned(_ url: URL, type: mode_t) -> Bool {
        var info = stat()
        return CanonicalPath.url(url).path == url.path && lstat(url.path, &info) == 0 &&
            info.st_uid == getuid() && (info.st_mode & S_IFMT) == type
    }
}
