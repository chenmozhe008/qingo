import Foundation
import Testing
@testable import Qingo

struct UpdateFallbackTests {
    @Test func spaceAlertAgentRunsThisAppAndCleansUpWhenItIsGone() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("小清 agent's test-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let plistFile = folder.appendingPathComponent("agent.plist")
        let plist = SpaceAlert.agentPlist(executable: "/Applications/小清.app/Contents/MacOS/Qingo", file: plistFile.path)
        #expect(plist["BundleProgram"] == nil)
        #expect(plist["StartInterval"] as? Int == 1800)

        func run(_ executable: URL) throws -> String {
            let output = folder.appendingPathComponent("ran.txt")
            try? FileManager.default.removeItem(at: output)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", SpaceAlert.agentScript, "test", executable.path, plistFile.path, "io.github.chenmozhe008.qingo.not-a-real-test-job"]
            process.environment = ["PATH": "/usr/bin:/bin", "OUT": output.path]
            try process.run(); process.waitUntilExit()
            return (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        }
        try Data("x".utf8).write(to: plistFile)
        let app = folder.appendingPathComponent("fake app")
        try Data("#!/bin/sh\necho \"$1\" > \"$OUT\"\n".utf8).write(to: app)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.path)
        #expect(try run(app).contains("--check-space"))
        #expect(FileManager.default.fileExists(atPath: plistFile.path))
        try FileManager.default.removeItem(at: app)
        #expect(try run(app).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: plistFile.path))
    }

    @Test func pageFallbackStillGivesOneClickAsset() {
        let page = URL(string: "https://github.com/chenmozhe008/qingo/releases/tag/v1.16.3")!
        #expect(UpdateChecker.releaseFromPage(page)?.asset?.absoluteString == "https://github.com/chenmozhe008/qingo/releases/download/v1.16.3/Qingo-1.16.3.zip")
        #expect(UpdateChecker.releaseFromPage(URL(string: "https://example.com/chenmozhe008/qingo/releases/tag/v1.16.3")!) == nil)
    }


    @Test func translocatedAppInstallsIntoApplications() {
        let moved = URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/小清.app")
        #expect(UpdateChecker.installTarget(for: moved).path == "/Applications/小清.app")
        let normal = URL(fileURLWithPath: "/Applications/小清.app")
        #expect(UpdateChecker.installTarget(for: normal) == normal)
    }

    @Test func permissionErrorsTriggerAdministratorInstall() {
        #expect(UpdateChecker.isPermissionDenied(CocoaError(.fileWriteNoPermission)))
        #expect(UpdateChecker.isPermissionDenied(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))))
        #expect(UpdateChecker.isPermissionDenied(UpdateChecker.UpdateError("x", permissionDenied: true)))
        #expect(!UpdateChecker.isPermissionDenied(UpdateChecker.UpdateError("x")))
        #expect(!UpdateChecker.isPermissionDenied(CocoaError(.fileNoSuchFile)))
    }

    private func runReplace(_ command: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        try process.run(); process.waitUntilExit()
        return process.terminationStatus
    }

    @Test func administratorCommandHandlesSpecialPathsAndRestoresOnFailure() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("闪电 update's test-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent("闪电 全能.app")
        let new = folder.appendingPathComponent("new's.app")
        let backup = folder.appendingPathComponent("旧版 backup.app")
        try Data("old".utf8).write(to: target)
        try Data("new".utf8).write(to: new)
        #expect(try runReplace(UpdateChecker.replaceCommand(target: target, app: new, backup: backup)) == 0)
        #expect(try Data(contentsOf: target) == Data("new".utf8))
        #expect(try Data(contentsOf: backup) == Data("old".utf8))

        try FileManager.default.removeItem(at: backup)
        let missing = folder.appendingPathComponent("missing.app")
        #expect(try runReplace(UpdateChecker.replaceCommand(target: target, app: missing, backup: backup)) != 0)
        #expect(try Data(contentsOf: target) == Data("new".utf8))
        #expect(!FileManager.default.fileExists(atPath: backup.path))
    }

    @Test func failedReplacementRestoresOldApp() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shandian-update-test-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = folder.appendingPathComponent("old.app")
        let backup = folder.appendingPathComponent("backup.app")
        let missing = folder.appendingPathComponent("missing.app")
        try Data("old".utf8).write(to: old)
        #expect(throws: (any Error).self) {
            try UpdateChecker.replaceApp(at: old, with: missing, backup: {
                try FileManager.default.moveItem(at: old, to: backup); return backup
            }, scheduleRelaunch: {})
        }
        #expect(try Data(contentsOf: old) == Data("old".utf8))
        #expect(!FileManager.default.fileExists(atPath: backup.path))
    }

    @Test func successfulReplacementKeepsBackupAndSchedulesRelaunch() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shandian-update-test-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent("old.app")
        let new = folder.appendingPathComponent("new.app")
        let backup = folder.appendingPathComponent("backup.app")
        try Data("old".utf8).write(to: target)
        try Data("new".utf8).write(to: new)
        var scheduled = false
        try UpdateChecker.replaceApp(at: target, with: new, backup: {
            try FileManager.default.moveItem(at: target, to: backup); return backup
        }, scheduleRelaunch: { scheduled = true })
        #expect(scheduled)
        #expect(try Data(contentsOf: target) == Data("new".utf8))
        #expect(try Data(contentsOf: backup) == Data("old".utf8))
    }

    @Test func failedRelaunchRestoresOldAndKeepsNewForRetry() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shandian-update-test-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = folder.appendingPathComponent("old.app")
        let new = folder.appendingPathComponent("new.app")
        let backup = folder.appendingPathComponent("backup.app")
        try Data("old".utf8).write(to: old)
        try Data("new".utf8).write(to: new)
        #expect(throws: (any Error).self) {
            try UpdateChecker.replaceApp(at: old, with: new, backup: {
                try FileManager.default.moveItem(at: old, to: backup); return backup
            }, scheduleRelaunch: { throw UpdateChecker.UpdateError("test") })
        }
        #expect(try Data(contentsOf: old) == Data("old".utf8))
        #expect(try Data(contentsOf: new) == Data("new".utf8))
    }
}
