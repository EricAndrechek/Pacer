import Foundation
import Testing
@testable import PacerCore

@Suite("LiveSessionActivity.from")
struct LiveSessionActivityTests {

    @Test func activeWhenWithinFiveMinutes() {
        let now = Date()
        #expect(LiveSessionActivity.from(lastSeen: now, now: now) == .active)
        #expect(LiveSessionActivity.from(lastSeen: now.addingTimeInterval(-299), now: now) == .active)
        // Exactly at 300s — still .active by the spec (≤ 300).
        #expect(LiveSessionActivity.from(lastSeen: now.addingTimeInterval(-300), now: now) == .active)
    }

    @Test func recentBetweenFiveMinutesAndOneHour() {
        let now = Date()
        #expect(LiveSessionActivity.from(lastSeen: now.addingTimeInterval(-301), now: now) == .recent)
        #expect(LiveSessionActivity.from(lastSeen: now.addingTimeInterval(-1800), now: now) == .recent)
        #expect(LiveSessionActivity.from(lastSeen: now.addingTimeInterval(-3600), now: now) == .recent)
    }

    @Test func idleBeyondOneHour() {
        let now = Date()
        #expect(LiveSessionActivity.from(lastSeen: now.addingTimeInterval(-3601), now: now) == .idle)
        #expect(LiveSessionActivity.from(lastSeen: now.addingTimeInterval(-86400), now: now) == .idle)
    }

    @Test func futureTimestampStaysActive() {
        // Clock skew between machines can leave a lastSeenAt slightly
        // in the future. The classifier returns negative age which is
        // ≤ 300 → .active. Good — better to treat clock skew as
        // active than to flag it as idle.
        let now = Date()
        #expect(LiveSessionActivity.from(lastSeen: now.addingTimeInterval(10), now: now) == .active)
    }
}
