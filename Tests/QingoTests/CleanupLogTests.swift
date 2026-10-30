import Foundation
import Testing
@testable import Qingo

/// The cleanup log behind the diagnostics: newest first, capped, and free of the user name.
@Suite(.serialized) struct CleanupLogTests {
    @Test func keepsNewestTenWithHomeShortened() {
        let home = AppHome.url
        for index in 0..<12 {
            CleanupLog.record("清理", moved: [(home.appending(path: "Library/Caches/test\(index)"), Int64(index))], failedCount: 0)
        }
        let entries = CleanupLog.load()
        #expect(entries.count == CleanupLog.limit)
        #expect(entries.first?.moved.first?.path == "~/Library/Caches/test11")
        #expect(!Diagnostics.report().contains(home.path + "/"))
    }

    @Test func emptyCleanupIsNotRecorded() {
        CleanupLog.record("清理", moved: [], failedCount: 2)
        #expect(!CleanupLog.load().contains { $0.moved.isEmpty })
    }
}
