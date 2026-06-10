import Foundation
import Testing
@testable import PacerCore

@Suite("BurnRate.projectRecencyWeighted")
struct BurnRateRecencyTests {

    private func sample(hoursAgo: Double, pct: Double, from now: Date) -> BurnRate.Sample {
        BurnRate.Sample(sampledAt: now.addingTimeInterval(-hoursAgo * 3600), usedPercentage: pct)
    }

    /// Hourly samples from `spanHours` ago to now, pct = f(hoursAgo).
    private func hourly(now: Date, spanHours: Int, pct: (Double) -> Double) -> [BurnRate.Sample] {
        (0...spanHours).map { sample(hoursAgo: Double($0), pct: pct(Double($0)), from: now) }
    }

    @Test func steadyWeeklyClimbProjectsHitBeforeReset() throws {
        let now = Date()
        // 2%/hr climb over 24h ending at 88% now → 6h to 100%. Reset in 12h.
        let samples = hourly(now: now, spanHours: 24) { 88 - 2 * $0 }
        let reset = now.addingTimeInterval(12 * 3600)
        let p = try #require(BurnRate.projectRecencyWeighted(samples: samples, resetsAt: reset, now: now))

        #expect(p.willHitLimitBeforeReset)
        #expect(abs(p.slopePercentPerHour - 2) < 0.3)
        let etaH = try #require(p.etaSeconds) / 3600
        #expect(abs(etaH - 6) < 1.0)               // ~6h to cap
    }

    @Test func hitAfterResetReportsNoProjection() throws {
        let now = Date()
        let samples = hourly(now: now, spanHours: 24) { 88 - 2 * $0 }
        // Same 6h-to-cap climb, but the window resets in 2h → resets first.
        let reset = now.addingTimeInterval(2 * 3600)
        let p = try #require(BurnRate.projectRecencyWeighted(samples: samples, resetsAt: reset, now: now))
        #expect(p.slopePercentPerHour > 0)
        #expect(p.projectedFullAt == nil)
        #expect(p.willHitLimitBeforeReset == false)
    }

    @Test func flatTrendDoesNotProject() throws {
        let now = Date()
        let samples = hourly(now: now, spanHours: 24) { _ in 70 }
        let p = try #require(BurnRate.projectRecencyWeighted(
            samples: samples, resetsAt: now.addingTimeInterval(24 * 3600), now: now))
        #expect(abs(p.slopePercentPerHour) < 0.2)
        #expect(p.projectedFullAt == nil)
    }

    @Test func decliningTrendDoesNotProject() throws {
        let now = Date()
        // Just past a reset, rolling old usage out: 90 → 70 over 24h.
        let samples = hourly(now: now, spanHours: 24) { 70 + ($0 / 24) * 20 }
        let p = try #require(BurnRate.projectRecencyWeighted(
            samples: samples, resetsAt: now.addingTimeInterval(48 * 3600), now: now))
        #expect(p.slopePercentPerHour < 0)
        #expect(p.projectedFullAt == nil)
    }

    @Test func recencyWeightingDiscountsAnOldBurst() throws {
        let now = Date()
        // Steep burst 0→60 in the OLDEST 6h of a 48h window, then dead flat
        // at 60 for the recent 42h. A first-to-last line reads 1.25%/hr; the
        // recency-weighted slope sees the recent flat and reads near zero —
        // so no false "you'll blow the weekly cap" warning off a stale day.
        let samples = hourly(now: now, spanHours: 48) { hoursAgo in
            hoursAgo >= 42 ? max(0, 60 - 10 * (hoursAgo - 42)) : 60
        }
        let naiveFirstToLast = (60.0 - 0.0) / 48.0   // 1.25%/hr
        let p = try #require(BurnRate.projectRecencyWeighted(
            samples: samples, resetsAt: now.addingTimeInterval(24 * 3600), now: now))
        #expect(p.slopePercentPerHour < naiveFirstToLast)
        #expect(p.slopePercentPerHour < 0.5)
        #expect(p.projectedFullAt == nil)            // flat now → no imminent hit
    }

    @Test func alreadyMaxedSuppressesEta() throws {
        let now = Date()
        let samples = hourly(now: now, spanHours: 24) { min(100, 100 - 1 * $0) }  // 100 now
        let p = try #require(BurnRate.projectRecencyWeighted(
            samples: samples, resetsAt: now.addingTimeInterval(12 * 3600), now: now))
        #expect(p.projectedFullAt == nil)
    }

    @Test func tooShortSpanReturnsNil() {
        let now = Date()
        // Three samples spanning 1 hour; sevenDay min span is 3h → reject.
        let samples = [
            sample(hoursAgo: 1.0, pct: 60, from: now),
            sample(hoursAgo: 0.5, pct: 62, from: now),
            sample(hoursAgo: 0.0, pct: 64, from: now),
        ]
        #expect(BurnRate.projectRecencyWeighted(
            samples: samples, resetsAt: now.addingTimeInterval(48 * 3600), now: now) == nil)
    }

    @Test func tooFewSamplesReturnsNil() {
        let now = Date()
        let samples = [
            sample(hoursAgo: 10, pct: 50, from: now),
            sample(hoursAgo: 0, pct: 70, from: now),
        ]
        #expect(BurnRate.projectRecencyWeighted(
            samples: samples, resetsAt: now.addingTimeInterval(48 * 3600), now: now) == nil)
    }
}
