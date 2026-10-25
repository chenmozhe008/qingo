import Foundation

/// One part of a tool's read-only data folder, named in plain words with what to do about it.
/// Answers "查看位置 opens a folder, but what in it can I delete, and how?".
struct DataPart: Identifiable, Sendable {
    let id: URL
    let label: String
    let advice: String
    let bytes: Int64
    var name: String { id.lastPathComponent }
}

enum DataBreakdown {
    /// Largest parts first; parts under 1 MB are folded into "其他". Bytes already listed as their own rows
    /// (caches, models, old history) are left out, so the parts add up to the read-only row.
    static func parts(of root: URL, app: CreativeApp?, excluding listed: [ScanItem]) -> [DataPart] {
        // A row that is itself one known kind (Codex's sessions folder) is explained as a whole.
        if isKnown(root.lastPathComponent, app: app) {
            let (rootLabel, rootAdvice) = describe(root.lastPathComponent, app: app)
            return [DataPart(id: root, label: rootLabel, advice: rootAdvice, bytes: measured(root, excluding: listed))]
        }
        var folder = root
        // A data folder that is one big subfolder (剪映's "User Data") says nothing; look inside it.
        for _ in 0..<2 {
            let children = entries(of: folder)
            let sizes = children.map { measured($0, excluding: listed) }
            let total = sizes.reduce(0, +)
            // Only into a folder whose name says nothing; a known one (projects = 对话记录) is the answer itself.
            guard let index = sizes.indices.max(by: { sizes[$0] < sizes[$1] }), total > 0,
                  Double(sizes[index]) / Double(total) > 0.8, isDirectory(children[index]),
                  !isKnown(children[index].lastPathComponent, app: app) else { break }
            folder = children[index]
        }
        var parts: [DataPart] = []
        var other: Int64 = 0
        for child in entries(of: folder) {
            let bytes = measured(child, excluding: listed)
            guard bytes > 0 else { continue }
            if bytes < 1_000_000 || !isDirectory(child) {
                other += bytes
                continue
            }
            let (label, advice) = describe(child.lastPathComponent, app: app)
            parts.append(DataPart(id: child, label: label, advice: advice, bytes: bytes))
        }
        parts.sort { $0.bytes > $1.bytes }
        if other > 0 {
            parts.append(DataPart(id: folder.appending(path: "其他"), label: "其他零散文件", advice: "设置和小文件，别动", bytes: other))
        }
        return parts
    }

    static func isKnown(_ name: String, app: CreativeApp?) -> Bool { describe(name, app: app).0 != name }

    /// Plain name and advice for a folder name. Unknown names get an honest "用途不明".
    static func describe(_ name: String, app: CreativeApp?) -> (String, String) {
        let key = name.lowercased()
        let creative = app.map { [.video, .design, .aiCreate].contains($0.group) } ?? false
        let history = SafetyPolicy.oldHistoryDays
        switch key {
        case "projects" where creative, "drafts", "draft", "project", "user data":
            return ("工程和草稿", "你的作品，要删请在软件里删除对应的工程")
        case "projects" where app == .claudeCode:
            return ("对话记录", "Claude Code 默认只留 30 天；想留得更短，把 ~/.claude/settings.json 里的 cleanupPeriodDays 调小")
        case "sessions" where app == .codex:
            return ("最近的对话记录", "\(history) 天以内的对话；更早的已经单独列在上面，可以勾选删除")
        case "projects", "sessions", "archived_sessions", "conversations", "chats", "history", "chat-history", "threads", "local-agent-mode-sessions",
             "claude-code-sessions":
            return ("对话记录", "删了就不能再翻看和接着聊。要删请在软件里删除对话")
        case "generated_images" where app == .codex:
            return ("最近生成的图片", "\(history) 天以内的；更早的已经单独列在上面，可以勾选删除")
        case "generated_images", "outputs", "output", "images", "attachments", "clipboard-images", "playbook-covers":
            return ("生成的作品和附件", "需要的先另存出来，再在软件里删除")
        case "skills", "builtin_skills":
            return ("技能", "你装的技能，不用的在软件里删除")
        case "plugins", "extensions", "connectors", "connectors-marketplace", "mcps", "claude extensions":
            return ("插件和扩展", "不用的在软件里卸载，直接删可能让软件出错")
        case "workspacestorage", "workspace", "workspaces", "file-history", "changes-detail", "shell-snapshots", "backups", "worktrees":
            return ("工作区和改动记录", "软件用来恢复工作现场和撤销改动，别直接删")
        case "models", "hub":
            return ("模型", "删了要用时得重新下载")
        case "binaries", "bin", "versions", "runtimes", "runtime", "node", "python", "builtin", "app", "claude-code", "vm_bundles":
            return ("运行环境", "软件运行要用，删了会出错或重新下载")
        case "memories", "memory", "memories_v2":
            return ("记忆", "AI 记住的关于你的信息，删了要重新积累")
        case "indexeddb", "local storage", "session storage", "cookies", "blob_storage", "webstorage", "partitions", "storage",
             "local_storage", "shared_proto_db", "sharedstorage", "session":
            return ("登录状态和网页数据", "删了要重新登录，别直接删")
        case "sqlite", "database", "db":
            return ("数据库", "软件的索引和记录，别直接删")
        case "security", "audit-log", "telemetry", "sentry":
            return ("安全和统计记录", "软件自己维护，别直接删")
        default:
            return (name, "用途不明，建议别动")
        }
    }

    private static func entries(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map { $0.isDirectory == true && $0.isSymbolicLink != true } ?? false
    }

    private static func measured(_ url: URL, excluding listed: [ScanItem]) -> Int64 {
        let path = url.path
        if listed.contains(where: { $0.url.path == path }) { return 0 }
        let inside = listed.filter { $0.url.path.hasPrefix(path + "/") }.reduce(Int64(0)) { $0 + $1.bytes }
        let total = isDirectory(url) ? AppUninstaller.size(of: url) : Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        return max(total - inside, 0)
    }
}
