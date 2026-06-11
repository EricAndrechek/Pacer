import Foundation
import Testing
@testable import PacerCore

/// Deterministic seeded RNG so the calibration-coverage tests are reproducible.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func gauss(_ rng: inout SplitMix64) -> Double {
    // Box–Muller.
    let u1 = max(1e-12, Double.random(in: 0..<1, using: &rng))
    let u2 = Double.random(in: 0..<1, using: &rng)
    return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
}

@Suite("Forecast engine primitives")
struct ForecastEnginePrimitivesTests {

    // MARK: - Estimate

    @Test func insufficientEstimateIsDistinctFromZero() {
        let e = Estimate.insufficient(method: "x", note: "too early")
        #expect(e.isInsufficient)
        #expect(e.confidence == .insufficient)
        #expect(e.value.isNaN)
        #expect(e.note == "too early")

        let real = Estimate(value: 0, method: "y", confidence: .high, support: 30)
        #expect(!real.isInsufficient)   // a confident zero is NOT "insufficient"
    }

    @Test func confidenceIsOrdered() {
        #expect(Estimate.Confidence.insufficient < .low)
        #expect(Estimate.Confidence.low < .medium)
        #expect(Estimate.Confidence.medium < .high)
        #expect(Estimate.Confidence.high > .insufficient)
    }

    // MARK: - ConformalCalibrator

    @Test func quantileIsMonotonicAndRankAdjusted() {
        let c = ConformalCalibrator(mode: .additive, residuals: Array(stride(from: 0.0, through: 100, by: 1)))
        #expect(c.quantile(0.0) <= c.quantile(0.5))
        #expect(c.quantile(0.5) <= c.quantile(1.0))
        #expect(c.count == 101)
        // Extremes saturate to the observed min/max, never beyond.
        #expect(c.quantile(0.0) == 0)
        #expect(c.quantile(1.0) == 100)
    }

    @Test func fromPairsMultiplicativeSkipsNonPositivePredictions() {
        let c = ConformalCalibrator.fromPairs(
            mode: .multiplicative,
            predictions: [10, 0, -5, 20],
            truths: [12, 5, 5, 22])
        #expect(c.count == 2)   // the 0 and -5 predictions are dropped (ratio undefined)
    }

    @Test func tooFewResidualsYieldsNoBand() {
        let c = ConformalCalibrator(mode: .additive, residuals: [1, 2, 3])
        #expect(c.interval(around: 10, level: 0.8) == nil)
    }

    @Test func multiplicativeIntervalsAreCalibrated() {
        // Calibration: truth/pred ratios ~ lognormal(0, 0.3). A fresh test set
        // drawn from the same law should fall inside the 80% band ~80% of the time.
        var rng = SplitMix64(seed: 42)
        let cal = (0..<800).map { _ in exp(0.3 * gauss(&rng)) }
        let c = ConformalCalibrator(mode: .multiplicative, residuals: cal)
        let band = try! #require(c.interval(around: 100, level: 0.8))

        var hit = 0, total = 0
        for _ in 0..<4000 {
            let truth = 100 * exp(0.3 * gauss(&rng))
            if band.contains(truth) { hit += 1 }
            total += 1
        }
        let coverage = Double(hit) / Double(total)
        #expect(coverage > 0.75 && coverage < 0.87)   // ~0.80, conformal is mildly conservative
    }

    @Test func additiveIntervalsAreCalibrated() {
        var rng = SplitMix64(seed: 7)
        let cal = (0..<800).map { _ in 5.0 * gauss(&rng) }     // residuals ~ N(0, 5)
        let c = ConformalCalibrator(mode: .additive, residuals: cal)
        let band = try! #require(c.interval(around: 50, level: 0.8))

        var hit = 0
        for _ in 0..<4000 {
            let truth = 50 + 5.0 * gauss(&rng)
            if band.contains(truth) { hit += 1 }
        }
        #expect(Double(hit) / 4000 > 0.75 && Double(hit) / 4000 < 0.87)
    }

    // MARK: - EmpiricalBayes

    @Test func noBetweenGroupSignalShrinksToFlat() {
        // Group means differ by LESS than their sampling noise would produce →
        // the estimator credits no real signal and pulls every cell to the grand
        // mean. This is the "weekday carries no signal → ship flat" case.
        let groups = [9.0, 11, 10, 8, 12].map {
            EmpiricalBayes.Group(mean: $0, count: 4, within: 16)   // samplingVar 4 > spread 2
        }
        let r = EmpiricalBayes.shrink(groups)
        #expect(r.betweenVar == 0)
        #expect(r.signalShare < 0.01)
        for m in r.shrunkMeans { #expect(abs(m - r.grandMean) < 1e-9) }
        #expect(abs(r.grandMean - 10) < 1e-9)
    }

    @Test func strongSignalWithLargeNKeepsOwnMeans() {
        let raw = [5.0, 50, 100]
        let groups = raw.map { EmpiricalBayes.Group(mean: $0, count: 1000, within: 1) }
        let r = EmpiricalBayes.shrink(groups)
        #expect(r.signalShare > 0.9)
        for (s, m) in zip(r.shrunkMeans, raw) { #expect(abs(s - m) < 1.0) }   // barely shrunk
        for w in r.weights { #expect(w > 0.95) }
    }

    @Test func shrunkMeanLiesBetweenRawAndGrand() {
        let groups = [EmpiricalBayes.Group(mean: 0, count: 4, within: 16),
                      EmpiricalBayes.Group(mean: 20, count: 4, within: 16)]
        let r = EmpiricalBayes.shrink(groups)
        #expect(abs(r.grandMean - 10) < 1e-9)
        // shrunk[0] in (0, 10), shrunk[1] in (10, 20), symmetric.
        #expect(r.shrunkMeans[0] > 0 && r.shrunkMeans[0] < 10)
        #expect(r.shrunkMeans[1] > 10 && r.shrunkMeans[1] < 20)
        #expect(abs((r.shrunkMeans[0] - 10) + (r.shrunkMeans[1] - 10)) < 1e-9)
        for w in r.weights { #expect(w >= 0 && w <= 1) }
    }

    @Test func untrustedThinCellsArePooledFully() {
        // A high-count, distinct group establishes signal; a count-1 outlier cell
        // below minCount is returned fully shrunk to the grand mean.
        let groups = [EmpiricalBayes.Group(mean: 10, count: 200, within: 1),
                      EmpiricalBayes.Group(mean: 12, count: 200, within: 1),
                      EmpiricalBayes.Group(mean: 999, count: 1, within: 1)]
        let r = EmpiricalBayes.shrink(groups, minCount: 2)
        #expect(r.weights[2] == 0)                       // the n=1 cell gets no trust
        #expect(abs(r.shrunkMeans[2] - r.grandMean) < 1e-9)
    }
}
