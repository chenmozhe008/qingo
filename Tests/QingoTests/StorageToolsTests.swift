import Foundation
import Testing
@testable import Qingo

struct StorageToolsTests {
    @Test func duplicateScanChecksSizeAndContentsAndSkipsProtectedFiles() throws {
        try withHome { home in
            let first = try fixture("a.mov", home: home)
            let second = try fixture("b.mov", home: home)
            _ = try fixture("different.mov", home: home, marker: 1)
            _ = try fixture("ignored.mov", home: home)
            _ = try fixture("Library/protected.mov", home: home)
            _ = try fixture("Movie.fcpbundle/project.mov", home: home)
            _ = try fixture("Small.mov", home: home, bytes: DuplicateFiles.minimumBytes - 1)
            let hardlink = try fixture("linked.mov", home: home)
            try FileManager.default.linkItem(at: hardlink, to: home.appending(path: "hardlink.mov"))
            try FileManager.default.createSymbolicLink(at: home.appending(path: "symlink.mov"), withDestinationURL: first)
            let scanner = DuplicateFiles(policy: SafetyPolicy(home: home))
            let result = try scanner.scan(home, ignoring: [home.appending(path: "ignored.mov").path])
            #expect(result.groups.count == 1)
            #expect(result.groups.first?.files.map(\.url.path) == [first.path, second.path])
        }
    }

    @Test func duplicatesKeepOneFileAndRejectChangesAfterScanning() throws {
        try withHome { home in
            let a = try fixture("a.mov", home: home)
            let b = try fixture("b.mov", home: home)
            let scanner = DuplicateFiles(policy: SafetyPolicy(home: home))
            let group = try #require(scanner.scan(home).groups.first)
            let keeper = group.files[0]
            let copy = group.files[1]
            #expect(throws: TrashError.changed) { try scanner.move(copy, keeping: copy, in: group) }

            let trashed = try scanner.move(copy, keeping: keeper, in: group)
            #expect(FileManager.default.fileExists(atPath: a.path))
            #expect(!FileManager.default.fileExists(atPath: b.path))
            #expect(TrashService.putBack([(b, trashed)]) == [true])

            let updated = try #require(scanner.scan(home).groups.first)
            let handle = try FileHandle(forWritingTo: a)
            try handle.write(contentsOf: Data([1]))
            try handle.close()
            #expect(throws: TrashError.changed) {
                try scanner.move(updated.files[1], keeping: updated.files[0], in: updated)
            }
            #expect(FileManager.default.fileExists(atPath: b.path))
        }
    }

    @Test func installedToolVersionsAreKeptAndActiveLinkIsRechecked() throws {
        try withHome { home in
            let versions = ToolVersions(home: home)
            let tool = try #require(ToolVersions.Tool.supported.first)
            let root = home.appending(path: tool.versions, directoryHint: .isDirectory)
            let old = try fixture("2.1.9", home: root, bytes: 8192, executable: true)
            _ = try fixture("2.1.10", home: root, bytes: 8192, executable: true)
            let current = try fixture("2.1.11", home: root, bytes: 8192, executable: true)
            _ = try fixture("2.1.12", home: root, bytes: 8192, executable: true)
            _ = try fixture("notes", home: root, bytes: 8192, executable: true)
            let launcher = home.appending(path: tool.launcher)
            try FileManager.default.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
            #expect(versions.candidates(for: tool).isEmpty)
            try FileManager.default.createSymbolicLink(at: launcher, withDestinationURL: current)
            #expect(versions.candidates(for: tool).map(\.path) == [old.path])

            let policy = SafetyPolicy(home: home)
            let scan = try DiskScanner(policy: policy).scanKnownCaches()
            let item = try #require(scan.items.first { $0.url.path == old.path })
            let handle = try FileHandle(forReadingFrom: old)
            #expect(throws: TrashError.inUse) { try TrashService(policy: policy).moveToTrash(item) }
            try handle.close()

            let trashed = try TrashService(policy: policy).moveToTrash(item)
            #expect(TrashService.putBack([(old, trashed)]) == [true])
            try FileManager.default.removeItem(at: launcher)
            try FileManager.default.createSymbolicLink(at: launcher, withDestinationURL: old)
            #expect(throws: TrashError.notEligible) { try TrashService(policy: policy).moveToTrash(item) }
        }
    }

    @Test func cursorKeepsEveryBuildFromThePreviousReleaseDate() throws {
        try withHome { home in
            let tool = try #require(ToolVersions.Tool.supported.last)
            let root = home.appending(path: tool.versions, directoryHint: .isDirectory)
            let names = ["2025.09.17-aaaaaaa", "2025.09.18-aaaaaaa", "2025.09.18-bbbbbbb", "2025.09.19-aaaaaaa"]
            for name in names {
                _ = try fixture("\(name)/cursor-agent", home: root, bytes: 4096, executable: true)
            }
            let launcher = home.appending(path: tool.launcher)
            try FileManager.default.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: launcher, withDestinationURL: root.appending(path: "\(names[3])/cursor-agent"))
            #expect(ToolVersions(home: home).candidates(for: tool).map(\.lastPathComponent) == [names[0]])
        }
    }

    @Test func icloudRequiresAnUploadedCurrentCopyWithNoSyncActivity() {
        func eligible(uploaded: Bool? = true, status: URLUbiquitousItemDownloadingStatus = .current,
                      uploading: Bool? = false, downloading: Bool? = false, conflicts: Bool? = false, syncError: Bool = false) -> Bool {
            CloudDownloads.canEvict(regular: true, ubiquitous: true, status: status, uploaded: uploaded,
                                    uploading: uploading, downloading: downloading, conflicts: conflicts, syncError: syncError)
        }
        #expect(eligible())
        #expect(!eligible(uploaded: nil))
        #expect(!eligible(status: .notDownloaded))
        #expect(!eligible(uploading: true))
        #expect(!eligible(downloading: true))
        #expect(!eligible(conflicts: true))
        #expect(!eligible(syncError: true))
    }

    @Test func timeMachineOnlyCountsLocalBackupsAndChecksResultsAfterThinning() throws {
        let local = "com.apple.TimeMachine.2026-11-22-012345.local"
        let output = "Snapshots for disk /:\ncom.apple.os.update-SYSTEM\n\(local)\n"
        #expect(TimeMachineSnapshots.parse(output) == [local])
        let script = CommandScript([
            (["listlocalsnapshots", "/"], output),
            (["thinlocalsnapshots", "/", "10000000000", "1"], "Thinned local snapshots"),
            (["listlocalsnapshots", "/"], "com.apple.os.update-SYSTEM\n")
        ])
        let service = TimeMachineSnapshots(run: script.run)
        let result = try service.thin(confirmed: [local])
        #expect(result.removed == 1)
        #expect(result.remaining.isEmpty)
        #expect(script.calls == 3)

        let changed = CommandScript([(["listlocalsnapshots", "/"], output)])
        #expect(throws: TrashError.changed) { try TimeMachineSnapshots(run: changed.run).thin(confirmed: []) }
        #expect(changed.calls == 1)
    }

    private func withHome(_ test: (URL) throws -> Void) throws {
        let root = CanonicalPath.url(FileManager.default.temporaryDirectory).appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try test(root)
    }

    private func fixture(_ path: String, home: URL, bytes: Int64 = DuplicateFiles.minimumBytes, marker: UInt8 = 0,
                         executable: Bool = false) throws -> URL {
        let url = home.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([marker]).write(to: url)
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: UInt64(bytes))
        try file.close()
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
        return url
    }

    @Test func cliRunnerHandlesLargeOutputWithoutPipeDeadlock() throws {
        let out = try CLICleanerAdapters.defaultRun("/usr/bin/python3", ["-c", "print('a' * 160000)"], 5)
        #expect(out.status == 0)
        #expect(out.stdout.count >= 160_000)
    }

    @MainActor @Test func spaceLensCollectorTracksSafeItemsAndRejectsProtected() throws {
        try withHome { home in
            let safeDir = home.appending(path: "Downloads/OldStuff")
            let libDir = home.appending(path: "Library")
            try FileManager.default.createDirectory(at: safeDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: libDir, withIntermediateDirectories: true)

            let lens = SpaceLensStore(home: home, policy: SafetyPolicy(home: home))
            let safeEntry = FastSizeCalculator.ChildEntry(url: safeDir, name: "OldStuff", isDirectory: true, bytes: 1024, isMeasuring: false)
            let libEntry = FastSizeCalculator.ChildEntry(url: libDir, name: "Library", isDirectory: true, bytes: 4096, isMeasuring: false)

            lens.toggleCollector(libEntry)
            #expect(lens.collector.isEmpty)

            lens.toggleCollector(safeEntry)
            #expect(lens.collector.count == 1)
            #expect(lens.collectorBytes == 1024)

            lens.toggleCollector(safeEntry)
            #expect(lens.collector.isEmpty)
        }
    }

    @Test func launchAgentScannerDetectsMissingExecutableAsOrphaned() throws {
        try withHome { home in
            let agentsDir = home.appending(path: "Library/LaunchAgents")
            try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)

            let validExe = home.appending(path: "helper-bin")
            try Data("#!/bin/sh\n".utf8).write(to: validExe)

            let activePlist = agentsDir.appending(path: "com.test.active.plist")
            let orphanPlist = agentsDir.appending(path: "com.test.orphan.plist")

            let activeDict: [String: Any] = ["Label": "com.test.active", "Program": validExe.path]
            let orphanDict: [String: Any] = ["Label": "com.test.orphan", "ProgramArguments": ["/nonexistent/missing/app"]]
            try PropertyListSerialization.data(fromPropertyList: activeDict, format: .xml, options: 0).write(to: activePlist)
            try PropertyListSerialization.data(fromPropertyList: orphanDict, format: .xml, options: 0).write(to: orphanPlist)

            let scanned = UninstallStore.scanUserLaunchAgents(home: home)
            #expect(scanned.count == 2)
            let orphan = try #require(scanned.first { $0.label == "com.test.orphan" })
            let active = try #require(scanned.first { $0.label == "com.test.active" })
            #expect(orphan.orphaned)
            #expect(!active.orphaned)
        }
    }
}

private final class CommandScript: @unchecked Sendable {
    private var responses: [([String], String)]
    private let lock = NSLock()
    private var index = 0

    var calls: Int { lock.withLock { index } }

    init(_ responses: [([String], String)]) { self.responses = responses }

    func run(_ arguments: [String]) throws -> String {
        try lock.withLock {
            guard index < responses.count, responses[index].0 == arguments else { throw TrashError.notEligible }
            defer { index += 1 }
            return responses[index].1
        }
    }
}
