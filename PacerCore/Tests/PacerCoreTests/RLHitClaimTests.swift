import Foundation
import Testing
@testable import PacerCore

/// The red "limit in …" claim (#304): only on the latest-plausible crossing,
/// at or above the level floor, confirmed over two refits. A point crossing
/// alone was claimed, and 87% of claimed 5-hour cycles never reached the cap.
@Suite("Rate-limit hit claim")
struct RLHitClaimTests {

    static let utc = Calendar(identifier: .gregorian).with(timeZone: TimeZone(identifier: "UTC")!)
    static let now = Date(timeIntervalSince1970: 1_752_000_000)
    static let window: TimeInterval = 5 * 3600

    /// Twelve completed cycles that burst early and then flatten at 50%, the
    /// shape that makes an early extrapolation overshoot (strongly negative
    /// residuals), then a live cycle 40% in, at `liveUsed`, still climbing.
    static func features(liveUsed: Double) -> EngineFeatures {
        var rate: [EngineFeatures.RateRow] = []
        let liveStart = now.addingTimeInterval(-0.4 * window)
        for c in 0..<12 {
            let start = liveStart.addingTimeInterval(-Double(12 - c) * window)
            let reset = start.addingTimeInterval(window)
            for k in 0...30 {
                let frac = Double(k) / 30
                let pct = min(50, 125 * frac)                   // 50% by 40% elapsed, then flat
                rate.append(.init(window: "five_hour", at: start.addingTimeInterval(frac * window),
                                  usedPercentage: pct, resetsAt: reset))
            }
        }
        let liveReset = liveStart.addingTimeInterval(window)
        for k in 0...12 {
            let frac = Double(k) / 12
            rate.append(.init(window: "five_hour", at: liveStart.addingTimeInterval(frac * 0.4 * window),
                              usedPercentage: liveUsed * frac, resetsAt: liveReset))
        }
        return EngineFeatures.build(now: now, calendar: utc, daily: [], hourly: [], rate: rate, lastArrivalAt: nil)
    }

    /// The fixture's overshoot numbers describe `linear-recent`, so the fit is
    /// pinned to it: these tests are about the claim gate, not selection.
    static func fit(_ f: EngineFeatures) -> UsageIntelligenceEngine.Fit {
        UsageIntelligenceEngine.makeFit(f, rlSelection: ["five_hour": "linear-recent"])
    }

    static func confirmedFit(_ f: EngineFeatures) -> UsageIntelligenceEngine.Fit {
        let once = UsageIntelligenceEngine.carryClaimStreaks(f, into: fit(f), from: .init())
        return UsageIntelligenceEngine.carryClaimStreaks(f, into: fit(f), from: once)
    }

    @Test func aBurstAModelUsuallyOvershootsDoesNotGoRed() throws {
        // 52% at 40% elapsed: linear-recent runs to ~130% at reset, but this
        // history overshot by ~33 pp at early cuts, so the corrected line ends
        // near 97%. (At 55% the corrected line still clears 100, and claims.)
        let f = Self.features(liveUsed: 52)
        let o = try #require(UsageIntelligenceEngine.burnOutlook(f, Self.confirmedFit(f), windowKey: "five_hour"))
        #expect(o.usedPct >= BurnRate.warningUsedFloor)
        #expect(o.projectedFullAt != nil)          // the point line still crosses: the chart marks it
        #expect(o.projectedFullAtLatest == nil)    // but its overshoot-corrected curve doesn't
        #expect(!o.hitClaimable)
        #expect(!o.willHitLimitBeforeReset)        // so nothing goes red
    }

    @Test func aBurstSteepEnoughToBeatItsOwnOvershootIsClaimed() throws {
        let f = Self.features(liveUsed: 55)
        let o = try #require(UsageIntelligenceEngine.burnOutlook(f, Self.confirmedFit(f), windowKey: "five_hour"))
        #expect(o.projectedFullAtLatest != nil)
        #expect(o.willHitLimitBeforeReset)
    }

    @Test func belowTheLevelFloorNothingIsClaimed() throws {
        let f = Self.features(liveUsed: 40)
        let o = try #require(UsageIntelligenceEngine.burnOutlook(f, Self.confirmedFit(f), windowKey: "five_hour"))
        #expect(o.usedPct < BurnRate.warningUsedFloor)
        #expect(!o.hitClaimable)
    }

    /// A crossing the line shows but the claim withholds is said hedged, and
    /// the reason is the gate that withheld it. Without one the chip printed
    /// the at-reset value the crossing clamps to: "≈100% at reset" at 46%.
    @Test func aWithheldCrossingCarriesTheGateThatWithheldIt() throws {
        let early = Self.features(liveUsed: 45)
        let e = try #require(UsageIntelligenceEngine.burnOutlook(early, Self.confirmedFit(early), windowKey: "five_hour"))
        #expect(e.projectedFullAt != nil)
        #expect(e.hitWithheld == .earlyInWindow)

        let overshoot = Self.features(liveUsed: 52)
        let o = try #require(UsageIntelligenceEngine.burnOutlook(overshoot, Self.confirmedFit(overshoot), windowKey: "five_hour"))
        #expect(o.hitWithheld == .slowEndResetsFirst)

        let steep = Self.features(liveUsed: 55)
        let once = UsageIntelligenceEngine.carryClaimStreaks(steep, into: Self.fit(steep), from: .init())
        let first = try #require(UsageIntelligenceEngine.burnOutlook(steep, once, windowKey: "five_hour"))
        #expect(first.hitWithheld == .unconfirmed)
        let confirmed = try #require(UsageIntelligenceEngine.burnOutlook(steep, Self.confirmedFit(steep), windowKey: "five_hour"))
        #expect(confirmed.willHitLimitBeforeReset)
        #expect(confirmed.hitWithheld == nil)        // claimed outright: the red chip says it
    }

    @Test func aClaimRestartsOnANewCycleAndLapsesWhenTheEvidenceGoes() {
        var fit = UsageIntelligenceEngine.Fit()
        fit.rl["five_hour"] = .init(roster: [], selectedId: nil, duration: Self.window, historyCount: 0)
        fit.rl["five_hour"]?.claimStreak = ("2026-01-01T00:00:00Z", 5)
        // No live outlook for this window in these features: the streak clears.
        let f = EngineFeatures.build(now: Self.now, calendar: Self.utc, daily: [], hourly: [], rate: [], lastArrivalAt: nil)
        let next = UsageIntelligenceEngine.carryClaimStreaks(f, into: fit, from: fit)
        #expect(next.rl["five_hour"]?.claimStreak == nil)
    }
}

private extension Calendar {
    func with(timeZone: TimeZone) -> Calendar { var c = self; c.timeZone = timeZone; return c }
}
