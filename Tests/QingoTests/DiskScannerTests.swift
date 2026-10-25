import Foundation
import Testing
@testable import Qingo

struct DiskScannerTests {
    @Test func largeInstallerIsManualReview() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let installer = root.appending(path: "Older-App.dmg")
        FileManager.default.createFile(atPath: installer.path, contents: Data())
        let handle = try FileHandle(forWritingTo: installer)
        try handle.truncate(atOffset: 150_000_000)
        try handle.close()
        let item = try #require(DiskScanner(policy: SafetyPolicy(home: root)).scan(root).items.first { $0.url.path == CanonicalPath.url(installer).path })
        #expect(item.kind == .largeFile && item.risk == .c && !item.canTrash)
    }

    @Test func oldRecordingsAreReviewOnlyAndRecentRecordingsAreExcluded() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recordings = root.appending(path: "Library/Application Support/Shandianshuo/recordings")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let old = recordings.appending(path: "old.m4a")
        let recent = recordings.appending(path: "recent.m4a")
        try Data(repeating: 1, count: 128).write(to: old)
        try Data(repeating: 2, count: 256).write(to: recent)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-20 * 24 * 60 * 60)], ofItemAtPath: old.path)
        let result = try DiskScanner(policy: SafetyPolicy(home: root)).scanKnownCaches()
        let item = try #require(result.items.first { $0.url.path == CanonicalPath.url(recordings).path })
        #expect(item.kind == .review && item.risk == .c && !item.canTrash)
        #expect(item.bytes == 128)
        #expect(item.note.contains("1 条"))
        let full = try DiskScanner(policy: SafetyPolicy(home: root)).scan(root)
        #expect(full.items.contains { $0.url.path == item.url.path && $0.kind == .review && $0.bytes == 128 })
    }

    @Test func updaterIsAAndNotionOfflineCacheIsC() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let updater = root.appending(path: "Library/Application Support/Caches/example-updater")
        let offline = root.appending(path: "Library/Application Support/Notion/Partitions/notion/Service Worker")
        for folder in [updater, offline] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try writeSparse(folder.appending(path: "data"), bytes: 50_000_000)
        }
        let result = try DiskScanner(policy: SafetyPolicy(home: root)).scanKnownCaches()
        #expect(result.items.contains { $0.url.path == CanonicalPath.url(updater).path && $0.risk == .a && $0.canTrash })
        #expect(result.items.contains { $0.url.path == CanonicalPath.url(offline).path && $0.risk == .c && !$0.canTrash })
    }

    @Test func nodeModulesIsManualReviewNotBatchCleanup() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appending(path: "Project")
        let dependencies = package.appending(path: "node_modules")
        try FileManager.default.createDirectory(at: dependencies, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: package.appending(path: "package.json"))
        try writeSparse(dependencies.appending(path: "data"), bytes: 50_000_000)
        let item = try #require(DiskScanner(policy: SafetyPolicy(home: root)).scan(root).items.first { $0.url.path == CanonicalPath.url(dependencies).path })
        #expect(item.kind == .review && item.risk == .c && !item.canTrash)
    }

    @Test func creativeAppCachesAndDataStaySeparate() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ae = root.appending(path: "Library/Caches/Adobe/After Effects/26.5/Disk Cache - Mac.noindex")
        let blenderCache = root.appending(path: "Library/Caches/Blender")
        let figmaData = root.appending(path: "Library/Application Support/Figma")
        let resolveData = root.appending(path: "Library/Application Support/Blackmagic Design/DaVinci Resolve")
        for folder in [ae, blenderCache, figmaData, resolveData] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try writeSparse(folder.appending(path: "data"), bytes: 200_000_000)
        }
        let policy = SafetyPolicy(home: root)
        let quick = try DiskScanner(policy: policy).scanKnownCaches()
        // Caches under ~/Library/Caches are cleanable; the editors' own data folders are read-only.
        #expect(quick.items.contains { CreativeApp.of($0) == .afterEffects && $0.canTrash })
        #expect(quick.items.contains { CreativeApp.of($0) == .blender && $0.canTrash })
        #expect(quick.items.contains { CreativeApp.of($0) == .davinci && !$0.canTrash })
        let full = try DiskScanner(policy: policy).scan(root)
        for folder in [figmaData, resolveData] {
            #expect(full.items.contains { $0.url.path == CanonicalPath.url(folder).path && !$0.canTrash })
        }
    }

    @Test func editorGeneratedMediaRequiresNativeReview() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let render = root.appending(path: "Film.fcpbundle/Event/Render Files")
        let resolve = root.appending(path: "CacheClip")
        for folder in [render, resolve] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try writeSparse(folder.appending(path: "cache"), bytes: 200_000_000)
        }
        let result = try DiskScanner(policy: SafetyPolicy(home: root)).scan(root)
        for folder in [render, resolve] {
            #expect(result.items.contains { $0.url.path == CanonicalPath.url(folder).path && $0.kind == .review && !$0.canTrash })
        }
        #expect(result.items.contains { $0.url.lastPathComponent == "Film.fcpbundle" && $0.kind == .project && !$0.canTrash })
    }

    @Test func quickScanFindsKnownCachesAndSkipsProtectedData() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appending(path: ".cache/codex-runtimes")
        let browser = root.appending(path: "Library/Caches/Microsoft Edge")
        let appleCache = root.appending(path: "Library/Caches/com.apple.example")
        let protected = root.appending(path: "Library/Caches/ms-playwright")
        let codexData = root.appending(path: "Library/Application Support/Codex/sessions")
        let codexCache = root.appending(path: "Library/Application Support/Codex/Cache")
        for folder in [runtime, browser, appleCache, protected, codexData, codexCache] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 100).write(to: folder.appending(path: "data"))
        }
        let policy = SafetyPolicy(home: root)
        let result = try DiskScanner(policy: policy).scanKnownCaches()
        #expect(result.isQuickScan)
        #expect(Set(result.items.map { $0.url.path }) == Set([runtime, browser, codexCache].map { CanonicalPath.url($0).path }))
        #expect(result.totalBytes == 300)
        let full = try DiskScanner(policy: policy).scan(root)
        #expect(full.items.contains { $0.url.path == CanonicalPath.url(codexCache).path && $0.kind == .cache })
        #expect(!full.items.contains { $0.url.path == CanonicalPath.url(codexData).path })
    }

    @MainActor
    @Test func cleanupSelectionIncludesOnlyEligibleCaches() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appending(path: "Film.fcpbundle")
        let build = root.appending(path: "Demo/.build")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try Data("// fixture".utf8).write(to: root.appending(path: "Demo/Package.swift"))
        try Data(repeating: 1, count: 128).write(to: build.appending(path: "object.o"))
        try writeSparse(project.appending(path: "project-data"), bytes: 200_000_000)

        let store = ScanStore()
        store.minShownBytes = 0
        store.result = try DiskScanner(policy: SafetyPolicy(home: root)).scan(root)
        // Tests share one defaults domain; never inherit another test's last category.
        store.filter = .caches
        store.selectAllEligible()
        #expect(store.selectedCleanupItems.count == 1)
        #expect(store.selectedCleanupItems.first?.url.path == CanonicalPath.url(build).path)
        #expect(store.selectedCleanupBytes == 128)
        let protectedProject = try #require(store.result?.items.first { $0.kind == .project })
        store.setCleanupSelected(protectedProject, selected: true)
        #expect(store.selectedCleanupItems.count == 1)
        store.clearCleanupSelection()
        #expect(store.selectedCleanupItems.isEmpty)
    }

    @Test func scanReportsRealVisitedCount() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<201 {
            try Data().write(to: root.appending(path: "file-\(index)"))
        }
        let updates = ProgressRecorder()
        let result = try DiskScanner(policy: SafetyPolicy(home: root)).scan(root) { update in
            updates.append(update.scannedCount)
        }
        #expect(result.scannedCount == 202)
        #expect(updates.values == [0, 200])
    }

    @Test func cancelledScanDoesNotReturnPartialResults() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outcome = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return Result { try DiskScanner(policy: SafetyPolicy(home: root)).scan(root) }
        }.value
        #expect(throws: CancellationError.self) { try outcome.get() }
    }

    @Test func classifiesProjectAndBuildCacheSeparately() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appending(path: "Demo")
        let cache = project.appending(path: ".build")
        let bundle = root.appending(path: "Film.fcpbundle")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("// swift".utf8).write(to: project.appending(path: "Package.swift"))
        try Data(repeating: 1, count: 200).write(to: cache.appending(path: "object.o"))
        try writeSparse(bundle.appending(path: "CurrentVersion.flexolibrary"), bytes: 200_000_000)

        let result = try DiskScanner(policy: SafetyPolicy(home: root)).scan(root)
        #expect(result.items.contains { $0.url.path == CanonicalPath.url(cache).path && $0.canTrash })
        #expect(result.items.contains { $0.url.path == CanonicalPath.url(bundle).path && $0.kind == .project && !$0.canTrash })
        #expect(!result.items.contains { $0.url.path == CanonicalPath.url(project).path && $0.canTrash })
    }

    @Test func protectedPathNeverBecomesTrashCandidate() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let protected = root.appending(path: "Library/Application Support/RecordingInbox")
        let cache = protected.appending(path: "node_modules")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: protected.appending(path: "package.json"))
        let result = try DiskScanner(policy: SafetyPolicy(home: root)).scan(root)
        #expect(!result.items.contains { $0.canTrash })
    }

    @Test func trashRejectsProjectEvenIfCallerRequestsIt() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appending(path: "Important.fcpbundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try writeSparse(bundle.appending(path: "project-data"), bytes: 200_000_000)
        let item = try #require(DiskScanner(policy: SafetyPolicy(home: root)).scan(root).items.first { $0.url.path == CanonicalPath.url(bundle).path })
        #expect(throws: TrashError.self) { try TrashService(policy: SafetyPolicy(home: root)).moveToTrash(item) }
        #expect(FileManager.default.fileExists(atPath: bundle.path))
    }

    @Test func generatedCacheCanBeTrashedAndRestored() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let project = root.appending(path: "Fixture")
        let cache = project.appending(path: ".build")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("// fixture".utf8).write(to: project.appending(path: "Package.swift"))
        try Data(repeating: 7, count: 32).write(to: cache.appending(path: "object.o"))
        let policy = SafetyPolicy(home: root)
        let item = try #require(DiskScanner(policy: policy).scan(root).items.first { $0.url.path == CanonicalPath.url(cache).path })
        let trashed = try TrashService(policy: policy).moveToTrash(item)
        defer {
            if FileManager.default.fileExists(atPath: trashed.path) {
                try? FileManager.default.moveItem(at: trashed, to: cache)
            }
            try? FileManager.default.removeItem(at: root)
        }
        #expect(!FileManager.default.fileExists(atPath: cache.path))
        #expect(FileManager.default.fileExists(atPath: trashed.path))
        try FileManager.default.moveItem(at: trashed, to: cache)
        #expect(FileManager.default.fileExists(atPath: cache.appending(path: "object.o").path))
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Int] = []

    func append(_ count: Int) {
        lock.lock()
        counts.append(count)
        lock.unlock()
    }

    var values: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }
}

func writeSparse(_ url: URL, bytes: UInt64) throws {
    FileManager.default.createFile(atPath: url.path, contents: Data())
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: bytes)
}
