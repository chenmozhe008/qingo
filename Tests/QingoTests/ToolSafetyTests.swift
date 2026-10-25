import Foundation
import Testing
@testable import Qingo

struct ToolSafetyTests {
    @Test func agentDataIsMeasuredOnceAndNeverBecomesCleanup() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let data = home.appending(path: "Library/Application Support/WorkBuddy")
        let nested = data.appending(path: "workspace/.build")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("project".utf8).write(to: nested.deletingLastPathComponent().appending(path: "Package.swift"))
        try writeSparse(nested.appending(path: "active-model"), bytes: 2_000_000)
        let policy = SafetyPolicy(home: home)
        let result = try DiskScanner(policy: policy).scanKnownCaches()
        let item = try #require(result.items.first)
        #expect(result.items.count == 1)
        #expect(item.bytes == 2_000_007 && result.totalBytes == 2_000_007)
        #expect(CreativeApp.of(item) == .workbuddy)
        #expect(!item.canTrash && item.kind == .review)
        #expect(policy.cacheDescription(for: nested, isDirectory: true) == nil)
        let forged = ScanItem(id: item.id, url: item.url, kind: .cache, risk: .a,
                              bytes: item.bytes, note: "", canTrash: true, identity: item.identity)
        #expect(throws: TrashError.self) { try TrashService(policy: policy).moveToTrash(forged) }
        #expect(FileManager.default.fileExists(atPath: nested.appending(path: "active-model").path))
    }

    @Test func toolCachesAreCleanableButModelsAndDataStayReadOnly() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = ["Library/Caches/Adobe/Adobe Photoshop 2026/__pycache__", ".cache/huggingface/models", ".ollama/models",
                     "Library/Application Support/Cursor/User", "Library/Application Support/Cursor/GPUCache",
                     "Movies/JianyingPro/User Data/Projects", "Movies/JianyingPro/User Data/Cache"]
        for path in paths {
            let folder = home.appending(path: path)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try writeSparse(folder.appending(path: "important"), bytes: 2_000_000)
        }
        let result = try DiskScanner(policy: SafetyPolicy(home: home)).scanKnownCaches()
        func row(_ path: String) -> ScanItem? { result.items.first { $0.url.path == CanonicalPath.url(home.appending(path: path)).path } }
        #expect(result.totalBytes == 14_000_000)
        #expect(row("Library/Caches/Adobe/Adobe Photoshop 2026").map { $0.canTrash && CreativeApp.of($0) == .photoshop } == true)
        #expect(row("Library/Application Support/Cursor/GPUCache").map { $0.canTrash && CreativeApp.of($0) == .cursor } == true)
        #expect(row("Movies/JianyingPro/User Data/Cache").map { $0.canTrash && CreativeApp.of($0) == .jianying } == true)
        for path in [".cache/huggingface", ".ollama", "Library/Application Support/Cursor", "Movies/JianyingPro"] {
            let item = try #require(row(path))
            #expect(!item.canTrash && item.risk == .c && item.bytes == 2_000_000)
        }
        #expect(!result.items.contains { $0.url.path.hasSuffix("/User") || $0.url.path.hasSuffix("/Projects") })
    }

    @Test func absentAndEmptyToolsProduceNoCards() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appending(path: "Library/Application Support/Trae"), withIntermediateDirectories: true)
        let result = try DiskScanner(policy: SafetyPolicy(home: home)).scanKnownCaches()
        #expect(result.items.isEmpty)
    }

    @Test func openFileBlocksCleanupAndClosedFilePassesUsageCheck() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "in-use")
        try Data([1]).write(to: file)
        let handle = try FileHandle(forReadingFrom: file)
        #expect(throws: TrashError.self) { try TrashService.ensureUnused(folder) }
        try handle.close()
        try TrashService.ensureUnused(folder)
    }

    @Test func protectedToolSymlinkIsNeverTraversed() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let actual = home.appending(path: "private")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: actual.appending(path: "conversation"))
        let support = home.appending(path: "Library/Application Support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: support.appending(path: "WorkBuddy"), withDestinationURL: actual)
        let result = try DiskScanner(policy: SafetyPolicy(home: home)).scanKnownCaches()
        #expect(result.items.isEmpty)
        #expect(result.totalBytes == 0)
        #expect(try Data(contentsOf: actual.appending(path: "conversation")) == Data([1, 2, 3]))
    }

    @Test func embeddedBrowserCachesLogsAndCrashReportsAreCleanableDataStays() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appending(path: ".workbuddy")
        let session = root.appending(path: "app/session")
        let cleanable = [session.appending(path: "Code Cache"), session.appending(path: "Partitions/preview/Cache"),
                         root.appending(path: "logs"), root.appending(path: "app/Crashpad"),
                         root.appending(path: "binaries/node/cli-connector-cache"), home.appending(path: "Library/Logs/WorkBuddy")]
        let kept = [root.appending(path: "plugins/cache"), root.appending(path: "projects"), session.appending(path: "Local Storage"),
                    root.appending(path: "projects/demo/Cache"), root.appending(path: "projects/demo/logs")]
        for folder in cleanable + kept {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try writeSparse(folder.appending(path: "data"), bytes: 2_000_000)
        }
        try Data("{}".utf8).write(to: session.appending(path: "Preferences"))
        let result = try DiskScanner(policy: SafetyPolicy(home: home)).scanKnownCaches()
        for folder in cleanable {
            let item = result.items.first { $0.url.path == CanonicalPath.url(folder).path }
            #expect(item.map { $0.canTrash && CreativeApp.of($0) == .workbuddy } == true, "\(folder.path) should be cleanable")
        }
        for folder in kept {
            #expect(!result.items.contains { $0.canTrash && $0.url.path == CanonicalPath.url(folder).path }, "\(folder.path) must stay")
        }
        // Everything else is one read-only row.
        let data = try #require(result.items.first { $0.url.path == CanonicalPath.url(root).path })
        #expect(!data.canTrash && data.bytes >= 10_000_000 && data.bytes < 10_001_000)
    }

    @Test func oldCodexHistoryIsOfferedCredentialsStayProtected() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let codex = home.appending(path: ".codex")
        let oldDay = codex.appending(path: "sessions/2026/05/01")
        let newDay = codex.appending(path: "sessions/2026/10/24")
        let oldImages = codex.appending(path: "generated_images/old-session")
        for folder in [oldDay, newDay, oldImages, codex.appending(path: "memories")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try writeSparse(folder.appending(path: "data"), bytes: 2_000_000)
        }
        try Data("secret".utf8).write(to: codex.appending(path: "auth.json"))
        let old = Date().addingTimeInterval(-60 * 86_400)
        for file in [oldDay.appending(path: "data"), oldImages.appending(path: "data")] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        }
        let policy = SafetyPolicy(home: home)
        let result = try DiskScanner(policy: policy).scanKnownCaches()
        func row(_ url: URL) -> ScanItem? { result.items.first { $0.url.path == CanonicalPath.url(url).path } }
        for folder in [oldDay, oldImages] {
            let item = try #require(row(folder))
            #expect(!item.canTrash && policy.decisionNote(for: item) != nil && CreativeApp.of(item) == .codex)
            let trashed = try TrashService(policy: policy).moveToTrash(item)
            try? FileManager.default.removeItem(at: trashed)
        }
        // Recent days stay in the read-only sessions row; nothing outside the three folders is even listed.
        #expect(row(newDay) == nil)
        let sessions = try #require(row(codex.appending(path: "sessions")))
        #expect(!sessions.canTrash && policy.decisionNote(for: sessions) == nil && sessions.bytes == 2_000_000)
        #expect(!result.items.contains { $0.url.path.contains("memories") || $0.url.path.hasSuffix("auth.json") })
        #expect(policy.isProtected(codex.appending(path: "auth.json")))
    }
}
