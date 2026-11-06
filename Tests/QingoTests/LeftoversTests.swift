import Foundation
import Testing
@testable import Qingo

/// Browser signing clones and the Clang cache live outside the home folder (`Leftovers`).
struct LeftoversTests {
    @Test func onlyRecognizedClonePathsAreCleanable() throws {
        let root = try #require(Leftovers.darwinUserRoot)
        // Wrong name pattern, unknown browser folder, or outside the X folder: never cleanable.
        #expect(Leftovers.note(for: root.appending(path: "X/com.google.Chrome.code_sign_clone/other")) == nil)
        #expect(Leftovers.note(for: root.appending(path: "X/com.example.app.code_sign_clone/code_sign_clone.abcdef")) == nil)
        #expect(Leftovers.note(for: root.appending(path: "T/com.google.Chrome.code_sign_clone/code_sign_clone.abcdef")) == nil)
        #expect(Leftovers.note(for: FileManager.default.homeDirectoryForCurrentUser.appending(path: "X")) == nil)
    }

    @Test func foundItemsPassTheTrashPolicy() {
        let policy = SafetyPolicy()
        for found in Leftovers.find() {
            #expect(policy.cacheDescription(for: found.url, isDirectory: true) != nil)
        }
    }

    /// Moves one real stale clone to the Trash and puts it back. Off by default: set QINGO_LIVE_LEFTOVERS=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QINGO_LIVE_LEFTOVERS"] == "1"))
    func staleCloneMovesToTrashAndBack() throws {
        let found = try #require(Leftovers.find().first { Leftovers.browser(of: $0.url) != nil })
        var info = stat()
        #expect(lstat(found.url.path, &info) == 0)
        let item = ScanItem(id: found.url, url: found.url, kind: .cache, risk: .b, bytes: found.bytes, note: found.note, canTrash: true,
                            identity: FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino)))
        let trashed = try TrashService(policy: SafetyPolicy()).moveToTrash(item)
        #expect(!FileManager.default.fileExists(atPath: found.url.path))
        #expect(TrashService.putBack([(original: found.url, trashed: trashed)]) == [true])
        #expect(FileManager.default.fileExists(atPath: found.url.path))
    }
}
