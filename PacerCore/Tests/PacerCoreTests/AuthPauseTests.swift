import Foundation
import Testing
@testable import PacerCore

// #198: "auth paused" only when the token has expired and the account is idle.

@Suite("Auth paused")
struct AuthPauseTests {
    private let reading = Date(timeIntervalSince1970: 1_790_000_000)
    private var later: Date { reading.addingTimeInterval(33 * 60) }

    @Test("no live token and nothing since the last reading: paused")
    func expiredAndIdle() {
        #expect(AuthPause.isPaused(liveTokenCount: 0, lastReadingAt: reading,
                                   lastActivityAt: reading.addingTimeInterval(-600), now: later))
        #expect(AuthPause.isPaused(liveTokenCount: 0, lastReadingAt: reading,
                                   lastActivityAt: nil, now: later))
    }

    @Test("a live token is never a pause, however old the reading")
    func liveToken() {
        #expect(!AuthPause.isPaused(liveTokenCount: 1, lastReadingAt: reading,
                                    lastActivityAt: nil, now: later))
    }

    @Test("a turn since the reading means Claude Code is about to refresh it")
    func notIdle() {
        #expect(!AuthPause.isPaused(liveTokenCount: 0, lastReadingAt: reading,
                                    lastActivityAt: reading.addingTimeInterval(60), now: later))
    }

    @Test("an expiry between two polls is not worth saying, and no reading is not a pause")
    func quietAndNeverRead() {
        #expect(!AuthPause.isPaused(liveTokenCount: 0, lastReadingAt: reading,
                                    lastActivityAt: nil, now: reading.addingTimeInterval(5 * 60)))
        #expect(!AuthPause.isPaused(liveTokenCount: 0, lastReadingAt: nil,
                                    lastActivityAt: nil, now: later))
    }
}
