import Foundation
import Testing
@testable import PacerCore

@Suite("TrendEstimator.fit")
struct TrendEstimatorTests {

    /// Build a series at the given signed hour offsets (negative = past),
    /// with `value` a closure of the signed offset `t`.
    private func series(
        now: Date,
        offsetsHours: [Double],
        value: (Double) -> Double
    ) -> [TrendEstimator.Sample] {
        offsetsHours.map { t in
            TrendEstimator.Sample(at: now.addingTimeInterval(t * 3600), value: value(t))
        }
    }

    private let denseOffsets: [Double] = [-1.5, -1.25, -1.0, -0.75, -0.5, -0.25, 0]

    private func params(
        now: Date,
        halfLifeHours: Double = 1,
        tauHours: Double = 2,
        maxAccelSlopeFraction: Double = 1.0,
        lookbackSeconds: TimeInterval? = nil,
        minSpanSeconds: TimeInterval = 60
    ) -> TrendEstimator.Parameters {
        TrendEstimator.Parameters(
            now: now,
            minSamples: 3,
            minSpanSeconds: minSpanSeconds,
            lookbackSeconds: lookbackSeconds,
            recencyHalfLifeSeconds: halfLifeHours * 3600,
            dampingTauSeconds: tauHours * 3600,
            maxAccelSlopeFraction: maxAccelSlopeFraction
        )
    }

    // MARK: - Recovery of the underlying trend

    @Test func recoversLinearSlopeWithZeroAcceleration() throws {
        let now = Date()
        // v(t) = 10 + 5t → level 10, slope 5/hr, no curvature.
        let samples = series(now: now, offsetsHours: denseOffsets) { 10 + 5 * $0 }
        let fit = try #require(TrendEstimator.fit(samples: samples, parameters: params(now: now)))

        #expect(abs(fit.level - 10) < 1e-3)
        #expect(abs(fit.slopePerHour - 5) < 1e-3)
        #expect(abs(fit.accelPerHourSq) < 1e-3)
        // No curvature → the projection is the bare line.
        #expect(abs(fit.projectedValue(afterHours: 2) - 20) < 1e-3)
    }

    @Test func recoversPositiveCurvatureOnARamp() throws {
        let now = Date()
        // v(t) = 10 + 5t + 3t² → curvature d²/dt² = 6/hr². (The linear
        // `slope` is a recency-weighted average, not the instantaneous 5 —
        // by design; we assert the curvature the quadratic recovers.)
        let samples = series(now: now, offsetsHours: denseOffsets) { 10 + 5 * $0 + 3 * $0 * $0 }
        let fit = try #require(TrendEstimator.fit(samples: samples, parameters: params(now: now)))

        #expect(abs(fit.accelPerHourSq - 6) < 1e-3)
        #expect(fit.slopePerHour > 0)
    }

    @Test func recoversNegativeCurvatureOnATaper() throws {
        let now = Date()
        // v(t) = 10 + 5t − 3t² → decelerating, curvature −6/hr².
        let samples = series(now: now, offsetsHours: denseOffsets) { 10 + 5 * $0 - 3 * $0 * $0 }
        let fit = try #require(TrendEstimator.fit(samples: samples, parameters: params(now: now)))

        #expect(abs(fit.accelPerHourSq + 6) < 1e-3)
    }

    // MARK: - Damping & clamping: a quadratic must not explode or reverse

    @Test func positiveCurvatureBendsProjectionUpButStaysBounded() throws {
        let now = Date()
        let samples = series(now: now, offsetsHours: denseOffsets) { 10 + 5 * $0 + 3 * $0 * $0 }
        let fit = try #require(TrendEstimator.fit(
            samples: samples, parameters: params(now: now, tauHours: 2)))

        // Positive curvature bends the projection above the bare line...
        let h = 2.0
        let bareLine = fit.level + fit.slopePerHour * h
        #expect(fit.projectedValue(afterHours: h) > bareLine)

        // ...but far out it grows only linearly (no ½·accel·h² blow-up): the
        // slope has saturated, so equal windows grow by equal amounts.
        let g1 = fit.projectedValue(afterHours: 200) - fit.projectedValue(afterHours: 100)
        let g2 = fit.projectedValue(afterHours: 300) - fit.projectedValue(afterHours: 200)
        #expect(abs(g1 - g2) < 1e-6)
        // And the saturated slope is bounded by the clamp: ≤ 2× the slope.
        let saturatedSlope = g1 / 100
        #expect(saturatedSlope <= 2 * fit.slopePerHour + 1e-6)
    }

    @Test func clampCapsHowMuchCurvatureCanBendTheLine() throws {
        let now = Date()
        let samples = series(now: now, offsetsHours: denseOffsets) { 10 + 5 * $0 + 3 * $0 * $0 }

        // With the clamp the effective acceleration is capped; turning the
        // clamp off lets the raw (larger) curvature through.
        let clamped = try #require(TrendEstimator.fit(
            samples: samples, parameters: params(now: now, maxAccelSlopeFraction: 1.0)))
        let unclamped = try #require(TrendEstimator.fit(
            samples: samples, parameters: params(now: now, maxAccelSlopeFraction: .infinity)))

        #expect(abs(clamped.effectiveAccelPerHourSq) < abs(unclamped.effectiveAccelPerHourSq))
        #expect(abs(unclamped.effectiveAccelPerHourSq - unclamped.accelPerHourSq) < 1e-9)

        // Disabling acceleration (fraction 0) reduces to the bare line.
        let linearOnly = try #require(TrendEstimator.fit(
            samples: samples, parameters: params(now: now, maxAccelSlopeFraction: 0)))
        let bare = linearOnly.level + linearOnly.slopePerHour * 3
        #expect(abs(linearOnly.projectedValue(afterHours: 3) - bare) < 1e-9)
    }

    // MARK: - The boundary case that sank the raw quadratic

    @Test func rampThenFlatDoesNotProjectADecline() throws {
        let now = Date()
        // An old burst (0 → 20 over the first half-hour) then dead flat at
        // 20 for the recent ~45 minutes. The raw quadratic reads this as
        // "decelerating into a decline" and projects the value *negative*;
        // the linear slope + clamped curvature must not.
        let value: (Double) -> Double = { t in
            t <= -1.0 ? max(0, 20 + 40 * (t + 1.0)) : 20
        }
        let samples = series(now: now, offsetsHours: denseOffsets, value: value)
        let fit = try #require(TrendEstimator.fit(
            samples: samples, parameters: params(now: now, halfLifeHours: 0.5, tauHours: 1)))

        // Slope stays a sane, positive, recency-discounted rate — not the
        // wild negative a parabola's endpoint derivative produces here.
        #expect(fit.slopePerHour > 0)
        #expect(fit.slopePerHour < 13)
        // The projection never dives below the current level...
        #expect(fit.projectedValue(afterHours: 2) > 0)
        #expect(fit.projectedValue(afterHours: 2) >= fit.level - 1e-6)
        // ...and the negative curvature only flattens it, staying at or
        // below the bare line.
        let bare = fit.level + fit.slopePerHour * 2
        #expect(fit.projectedValue(afterHours: 2) <= bare + 1e-6)
    }

    // MARK: - Recency weighting

    @Test func recencyWeightingDiscountsAnOldSteepRamp() throws {
        let now = Date()
        // Steep older growth flattening to a shallow recent rate. A shorter
        // half-life weights the recent shallow stretch more, so its slope is
        // strictly below a long (near-unweighted) half-life's slope.
        let value: (Double) -> Double = { t in
            t <= -1.0 ? max(0, 20 + 40 * (t + 1.0)) : 20
        }
        let samples = series(now: now, offsetsHours: denseOffsets, value: value)

        let shortFit = try #require(TrendEstimator.fit(
            samples: samples, parameters: params(now: now, halfLifeHours: 0.25)))
        let longFit = try #require(TrendEstimator.fit(
            samples: samples, parameters: params(now: now, halfLifeHours: 4.0)))

        #expect(shortFit.slopePerHour < longFit.slopePerHour)
        let naiveFirstToLast = (value(0) - value(-1.5)) / 1.5  // ≈ 13.3/hr
        #expect(shortFit.slopePerHour < naiveFirstToLast)
    }

    // MARK: - Crossing time

    @Test func crossingHoursMatchesLinearAnalytic() throws {
        let now = Date()
        // v(t) = 50 + 10t → level 50, slope 10/hr, no curvature. Reaches 100
        // at h = 5.
        let samples = series(now: now, offsetsHours: denseOffsets) { 50 + 10 * $0 }
        let fit = try #require(TrendEstimator.fit(samples: samples, parameters: params(now: now)))

        let h = try #require(fit.crossingHours(target: 100, maxHorizonHours: 24))
        #expect(abs(h - 5) < 1e-2)
    }

    @Test func crossingReturnsZeroWhenAlreadyAtTarget() throws {
        let now = Date()
        let samples = series(now: now, offsetsHours: denseOffsets) { 100 + 1 * $0 }
        let fit = try #require(TrendEstimator.fit(samples: samples, parameters: params(now: now)))
        let h = try #require(fit.crossingHours(target: 100, maxHorizonHours: 24))
        #expect(h < 1e-3)  // already essentially at the target
    }

    @Test func crossingReturnsNilWhenTrendNeverReachesTarget() throws {
        let now = Date()
        // Decreasing into the future: now-slope negative, never hits 100.
        let samples = series(now: now, offsetsHours: denseOffsets) { 50 - 5 * $0 }
        let fit = try #require(TrendEstimator.fit(samples: samples, parameters: params(now: now)))
        #expect(fit.slopePerHour < 0)
        #expect(fit.crossingHours(target: 100, maxHorizonHours: 24) == nil)
    }

    @Test func crossingDateComposesWithNow() throws {
        let now = Date()
        let samples = series(now: now, offsetsHours: denseOffsets) { 50 + 10 * $0 }
        let fit = try #require(TrendEstimator.fit(samples: samples, parameters: params(now: now)))
        let date = try #require(fit.crossingDate(target: 100, now: now, maxHorizon: 24 * 3600))
        #expect(abs(date.timeIntervalSince(now) - 5 * 3600) < 30)  // ~5h, ±30s
    }

    // MARK: - Guards

    @Test func returnsNilWithTooFewSamples() {
        let now = Date()
        let samples = series(now: now, offsetsHours: [-1, -0.5]) { 10 + 5 * $0 }
        #expect(TrendEstimator.fit(samples: samples, parameters: params(now: now)) == nil)
    }

    @Test func returnsNilWhenSpanTooShort() {
        let now = Date()
        // Five samples spanning ~2 minutes; minSpan = 5 minutes → reject.
        let offsets = (0..<5).map { -Double($0) * 0.5 / 60 }  // 0, −30s, −60s, ...
        let samples = series(now: now, offsetsHours: offsets) { 10 + 5 * $0 }
        let p = params(now: now, minSpanSeconds: 5 * 60)
        #expect(TrendEstimator.fit(samples: samples, parameters: p) == nil)
    }

    @Test func lookbackFilterCanStarveTheFit() {
        let now = Date()
        // All samples older than a 10-minute lookback → nothing survives.
        let samples = series(now: now, offsetsHours: denseOffsets) { 10 + 5 * $0 }
        let p = params(now: now, lookbackSeconds: 10 * 60)
        #expect(TrendEstimator.fit(samples: samples, parameters: p) == nil)
    }

    @Test func dropsFutureSamples() throws {
        let now = Date()
        // A clock-skewed future sample must not enter the fit. Series is
        // linear; adding a wild future point should not move the slope.
        var samples = series(now: now, offsetsHours: denseOffsets) { 10 + 5 * $0 }
        samples.append(TrendEstimator.Sample(at: now.addingTimeInterval(3600), value: 9_999))
        let fit = try #require(TrendEstimator.fit(samples: samples, parameters: params(now: now)))
        #expect(fit.sampleCount == denseOffsets.count)
        #expect(abs(fit.slopePerHour - 5) < 1e-3)
    }
}
