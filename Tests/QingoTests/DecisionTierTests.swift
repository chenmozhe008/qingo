import Foundation
import Testing
@testable import Qingo

/// Second tier: things the user may delete after confirming. Never regenerable, never in "全选".
struct DecisionTierTests {
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    @MainActor
    @Test func onlySafeItemsAndLargeFilesAreSelectable() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dependencies = home.appending(path: "Web/node_modules")
        let build = home.appending(path: "Tool/.build")
        let installer = home.appending(path: "Downloads/Old.dmg")
        for folder in [dependencies, build, installer.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data("{}".utf8).write(to: home.appending(path: "Web/package.json"))
        try Data("// fixture".utf8).write(to: home.appending(path: "Tool/Package.swift"))
        try writeSparse(dependencies.appending(path: "data"), bytes: 60_000_000)
        try Data(repeating: 1, count: 64).write(to: build.appending(path: "object.o"))
        try writeSparse(installer, bytes: 150_000_000)

        let store = ScanStore()
        store.minShownBytes = 0
        store.result = try DiskScanner(policy: SafetyPolicy(home: home)).scan(home)
        // Tests share one defaults domain; never inherit another test's last category.
        store.filter = .caches
        let node = try #require(store.result?.items.first { $0.url.path == CanonicalPath.url(dependencies).path })
        let dmg = try #require(store.result?.items.first { $0.url.path == CanonicalPath.url(installer).path })
        // Dependencies are never offered (the user can't judge them); a large file is the user's call.
        #expect(!store.isSelectable(node))
        #expect(store.isDecidable(dmg) && store.isSelectable(dmg))
        store.selectAllEligible()
        #expect(store.selectedCleanupItems.map(\.url.lastPathComponent) == [".build"])
        store.setCleanupSelected(node, selected: true)
        store.setCleanupSelected(dmg, selected: true)
        #expect(store.selectedCleanupItems.count == 2)
        #expect(store.selectedDecidedItems.map(\.id) == [dmg.id])
        #expect(!ItemFilter.visible.contains(.review))
    }

    @Test func largeFileCanBeTrashedAfterConfirmingButProjectCannot() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = home.appending(path: "Downloads/Old.dmg")
        try FileManager.default.createDirectory(at: installer.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeSparse(installer, bytes: 150_000_000)
        let policy = SafetyPolicy(home: home)
        let item = try #require(DiskScanner(policy: policy).scan(home).items.first { $0.url.path == CanonicalPath.url(installer).path })
        #expect(item.kind == .largeFile && !item.canTrash && policy.decisionNote(for: item) != nil)
        #expect(item.modified != nil)
        let trashed = try TrashService(policy: policy).moveToTrash(item)
        defer { try? FileManager.default.removeItem(at: trashed) }
        #expect(!FileManager.default.fileExists(atPath: installer.path))
        #expect(FileManager.default.fileExists(atPath: trashed.path))
    }

    @Test func largeFileInsideLibraryStaysReadOnly() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let blob = home.appending(path: "Library/SomeApp/blob.bin")
        try FileManager.default.createDirectory(at: blob.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeSparse(blob, bytes: 1_200_000_000)
        let policy = SafetyPolicy(home: home)
        let item = try #require(DiskScanner(policy: policy).scan(home).items.first { $0.url.path == CanonicalPath.url(blob).path })
        #expect(policy.decisionNote(for: item) == nil)
        #expect(throws: TrashError.self) { try TrashService(policy: policy).moveToTrash(item) }
    }

    @Test func modelsAreListedOneByOneAndTheRestStaysReadOnly() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let hfModel = home.appending(path: ".cache/huggingface/hub/models--Qwen--Qwen2.5-7B")
        let hfToken = home.appending(path: ".cache/huggingface/settings")
        let lmModel = home.appending(path: ".lmstudio/models/lmstudio-community/gemma-3")
        let lmChats = home.appending(path: ".lmstudio/conversations")
        for folder in [hfModel, hfToken, lmModel, lmChats] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try writeSparse(folder.appending(path: "data"), bytes: 3_000_000)
        }
        let policy = SafetyPolicy(home: home)
        let result = try DiskScanner(policy: policy).scanKnownCaches()
        func row(_ path: String) -> ScanItem? { result.items.first { $0.url.path == CanonicalPath.url(home.appending(path: path)).path } }
        let hf = try #require(row(".cache/huggingface/hub/models--Qwen--Qwen2.5-7B"))
        let lm = try #require(row(".lmstudio/models/lmstudio-community/gemma-3"))
        #expect(policy.modelName(hf.url) == "Qwen/Qwen2.5-7B" && policy.modelName(lm.url) == "lmstudio-community/gemma-3")
        for model in [hf, lm] {
            #expect(!model.canTrash && policy.decisionNote(for: model) != nil && model.bytes == 3_000_000)
        }
        // The tool rows keep only what is left, and stay read-only.
        for path in [".cache/huggingface", ".lmstudio"] {
            let tool = try #require(row(path))
            #expect(tool.bytes == 3_000_000 && policy.decisionNote(for: tool) == nil)
        }
        #expect(result.totalBytes == 12_000_000)
    }

    @Test func virtualEnvironmentIsDecidedRustTargetAndDerivedDataAreCaches() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let venv = home.appending(path: "Py/.venv")
        let target = home.appending(path: "Rs/target")
        let derived = home.appending(path: "Library/Developer/Xcode/DerivedData/App-abc")
        let archives = home.appending(path: "Library/Developer/Xcode/Archives/2026")
        for folder in [venv, target, derived, archives] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try writeSparse(folder.appending(path: "data"), bytes: 60_000_000)
        }
        try Data("home = /usr/bin".utf8).write(to: venv.appending(path: "pyvenv.cfg"))
        try Data("[package]".utf8).write(to: home.appending(path: "Rs/Cargo.toml"))
        let policy = SafetyPolicy(home: home)
        let result = try DiskScanner(policy: policy).scan(home)
        func row(_ url: URL) -> ScanItem? { result.items.first { $0.url.path == CanonicalPath.url(url).path } }
        let venvRow = try #require(row(venv))
        #expect(venvRow.kind == .review && policy.decisionNote(for: venvRow) != nil)
        #expect(row(target).map { $0.kind == .cache && $0.canTrash && $0.risk == .a } == true)
        #expect(row(derived.deletingLastPathComponent()).map { $0.kind == .cache && $0.canTrash } == true)
        #expect(!result.items.contains { $0.url.path.contains("/Archives") })
        let quick = try DiskScanner(policy: policy).scanKnownCaches()
        #expect(quick.items.contains { $0.url.lastPathComponent == "DerivedData" && $0.canTrash })
    }

    @MainActor
    @Test func cleanupUpdatesResultWithoutRescanAndUndoPutsItBack() async throws {
        let home = try makeHome()
        let build = home.appending(path: "Tool/.build")
        let dependencies = home.appending(path: "Downloads/Old.dmg")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dependencies.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("// fixture".utf8).write(to: home.appending(path: "Tool/Package.swift"))
        try Data(repeating: 1, count: 64).write(to: build.appending(path: "object.o"))
        try writeSparse(dependencies, bytes: 150_000_000)
        // The store saves the edited result under this location's key; remove that file afterwards.
        let key = CanonicalPath.url(home).path
        let saved = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Qingo/results/\(Data(key.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")).json")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: saved)
        }

        let store = ScanStore()
        store.minShownBytes = 0
        store.setRoot(CanonicalPath.url(home))
        store.result = try DiskScanner(policy: SafetyPolicy(home: home)).scan(home)
        store.filter = .large
        let before = try #require(store.result).items.count
        for item in store.result?.items ?? [] where store.isSelectable(item) { store.setCleanupSelected(item, selected: true) }
        #expect(store.selectedCleanupItems.count == 2)
        store.trashSelectedItems()
        while store.isCleaning { try await Task.sleep(for: .milliseconds(20)) }

        #expect(!store.isScanning && store.filter == .large)
        #expect(store.result?.items.count == before - 2)
        #expect(store.cleanupReport?.movedCount == 2 && store.undoable.count == 2)
        #expect(!FileManager.default.fileExists(atPath: build.path) && !FileManager.default.fileExists(atPath: dependencies.path))

        store.undoLastCleanup()
        while store.isRestoring { try await Task.sleep(for: .milliseconds(20)) }
        #expect(FileManager.default.fileExists(atPath: build.appending(path: "object.o").path))
        #expect(FileManager.default.fileExists(atPath: dependencies.path))
        #expect(store.result?.items.count == before && store.undoable.isEmpty)
    }
}
