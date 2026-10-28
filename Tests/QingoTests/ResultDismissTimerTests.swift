import Foundation
import Testing
@testable import Qingo

struct ResultDismissTimerTests {
    @Test @MainActor func replacingOrCancellingTimerDoesNotDismissNewResult() async throws {
        let timer = ResultDismissTimer()
        var dismissed = 0
        timer.schedule(after: .milliseconds(80)) { dismissed += 1 }
        try await Task.sleep(for: .milliseconds(20))
        timer.schedule(after: .milliseconds(200)) { dismissed += 10 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(dismissed == 0)
        timer.cancel()
        try await Task.sleep(for: .milliseconds(140))
        #expect(dismissed == 0)
        timer.schedule(after: .milliseconds(20)) { dismissed += 1 }
        try await Task.sleep(for: .milliseconds(80))
        #expect(dismissed == 1)
    }
}
