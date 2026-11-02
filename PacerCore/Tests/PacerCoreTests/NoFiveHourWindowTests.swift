import Foundation
import Testing
@testable import PacerCore

/// On 2026-10-30 Anthropic dropped the 5-hour limit for verified Ultra
/// (formerly Max 20×) accounts: their polls carry `seven_day` and no
/// `five_hour`. Every "newest row per window" reader then kept serving the
/// last pre-change 5-hour row as current. `latestBatch` is the rule that
/// stops that: a window the latest poll did not report is not current.
@Suite("No 5-hour window")
struct NoFiveHourWindowTests {

    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)

    private func point(_ window: String, at offset: TimeInterval, _ pct: Double) -> LimitSamplePoint {
        LimitSamplePoint(sampledAt: t0.addingTimeInterval(offset), window: window,
                         usedPercentage: pct, resetsAt: nil)
    }

    @Test func aWindowTheLatestPollDroppedIsNotCurrent() {
        // Newest first, as the fetches return them.
        let rows = [
            point(RateLimitWindowName.sevenDay, at: 7200, 73),
            point(RateLimitWindowName.sevenDay, at: 3600, 72),
            point(RateLimitWindowName.fiveHour, at: 0, 87),
            point(RateLimitWindowName.sevenDay, at: 0, 70),
        ]
        #expect(rows.latestBatch().map(\.window) == [RateLimitWindowName.sevenDay])
        #expect(rows.current(RateLimitWindowName.fiveHour) == nil)
        #expect(rows.current(RateLimitWindowName.sevenDay)?.usedPercentage == 73)
        #expect(rows.hasNoFiveHourWindow)
    }

    @Test func bothWindowsOfOnePollAreCurrentDespiteJitter() {
        // Two lanes of one account a second apart; each wrote both windows.
        let rows = [
            point(RateLimitWindowName.fiveHour, at: 1.1, 41),
            point(RateLimitWindowName.sevenDay, at: 1.1, 12),
            point(RateLimitWindowName.fiveHour, at: 0, 40),
            point(RateLimitWindowName.sevenDay, at: 0, 12),
        ]
        let batch = rows.latestBatch()
        #expect(Set(batch.map(\.window)) == [RateLimitWindowName.fiveHour, RateLimitWindowName.sevenDay])
        #expect(rows.current(RateLimitWindowName.fiveHour)?.usedPercentage == 41)
        #expect(!rows.hasNoFiveHourWindow)
    }

    /// No reading at all is a cold start, not an account without the window.
    @Test func noRowsIsNotAMissingWindow() {
        let rows: [LimitSamplePoint] = []
        #expect(rows.latestBatch().isEmpty)
        #expect(!rows.hasNoFiveHourWindow)
    }

    /// An unverified Ultra account keeps a temporary 5-hour cap, and one can
    /// come back: the rule follows the latest poll, not the plan.
    @Test func aFiveHourWindowThatReturnsIsCurrentAgain() {
        let rows = [
            point(RateLimitWindowName.fiveHour, at: 7200, 5),
            point(RateLimitWindowName.sevenDay, at: 7200, 74),
            point(RateLimitWindowName.sevenDay, at: 3600, 73),
        ]
        #expect(rows.current(RateLimitWindowName.fiveHour)?.usedPercentage == 5)
        #expect(!rows.hasNoFiveHourWindow)
    }

    /// The menu bar's icon follows the 5-hour window by default. With that
    /// window gone from the set it must fall back to the 7-day one rather
    /// than stay on an empty item (a grey icon that never colours).
    @Test func theIconDriverFallsBackToSevenDay() {
        let week = MenuBarWindowItem(
            key: RateLimitWindowName.sevenDay, displayName: "7-day",
            usedPercentage: 73, resetsAt: nil, duration: MenuBarWindows.sevenDayDuration,
            group: "", isScoped: false, isActive: false)
        let driver = MenuBarWindows.resolveDriver(key: MenuBarWindows.defaultDriverKey, windows: [week])
        #expect(driver?.key == RateLimitWindowName.sevenDay)
        #expect(MenuBarWindows.resolveRingWindows(keys: MenuBarWindows.defaultRingWindowKeys,
                                                  windows: [week]).map(\.key)
                == [RateLimitWindowName.sevenDay])
    }

    @Test func renamedPlansReadByTheirCurrentNames() {
        #expect(PlanLabel.describe(subscriptionType: "max", rateLimitTier: "default_claude_max_20x") == "Ultra")
        #expect(PlanLabel.describe(subscriptionType: "max", rateLimitTier: "default_claude_max_5x") == "Max")
        #expect(PlanLabel.describe(subscriptionType: "pro", rateLimitTier: "default_claude_pro") == "Pro")
    }
}
