import Foundation
import Testing
@testable import Qingo

/// When the low-space notification goes out: once per drop, again after a day or another 5 GB.
struct SpaceAlertTests {
    private let gb: Int64 = 1_073_741_824
    private let now = Date()

    @Test func warnsOnlyBelowThreshold() {
        #expect(!SpaceAlert.shouldWarn(free: 12 * gb, threshold: 10 * gb, lastFree: nil, lastDate: nil, now: now))
        #expect(SpaceAlert.shouldWarn(free: 8 * gb, threshold: 10 * gb, lastFree: nil, lastDate: nil, now: now))
    }

    @Test func doesNotRepeatWithinADay() {
        let hourAgo = now.addingTimeInterval(-3600)
        #expect(!SpaceAlert.shouldWarn(free: 7 * gb, threshold: 10 * gb, lastFree: 8 * gb, lastDate: hourAgo, now: now))
    }

    @Test func repeatsAfterADayOrAnotherFiveGigabytes() {
        let dayAgo = now.addingTimeInterval(-86_400)
        let hourAgo = now.addingTimeInterval(-3600)
        #expect(SpaceAlert.shouldWarn(free: 8 * gb, threshold: 10 * gb, lastFree: 8 * gb, lastDate: dayAgo, now: now))
        #expect(SpaceAlert.shouldWarn(free: 3 * gb, threshold: 10 * gb, lastFree: 8 * gb, lastDate: hourAgo, now: now))
    }
}
