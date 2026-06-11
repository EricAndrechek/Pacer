import Foundation
import Testing
@testable import PacerCore

@Suite("Usage norms")
struct UsageNormsTests {

    private func gauss(_ rng: inout SplitMix64) -> Double {
        let u1 = max(1e-12, Double.random(in: 0..<1, using: &rng))
        let u2 = Double.random(in: 0..<1, using: &rng)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }

    @Test func bandsAreCalibrated() {
        // Per-key lognormal samples; the 80% band should contain ~80% of fresh draws.
        var rng = SplitMix64(seed: 11)
        let mus = ["a": 3.0, "b": 4.5, "c": 5.5]
        var samples: [(key: String, value: Double)] = []
        for (k, mu) in mus {
            for _ in 0..<200 { samples.append((k, exp(mu + 0.4 * gauss(&rng)))) }
        }
        let bands = UsageNorms.bands(samples)
        var hit = 0, total = 0
        for (k, mu) in mus {
            let b = bands[k]!
            for _ in 0..<1500 {
                let v = exp(mu + 0.4 * gauss(&rng))
                if b.range80.contains(v) { hit += 1 }
                total += 1
            }
        }
        let coverage = Double(hit) / Double(total)
        #expect(coverage > 0.74 && coverage < 0.86)
    }

    @Test func thinBucketGetsAShrunkenNotDegenerateBand() {
        // One rich, varied bucket establishes a pooled spread; a 2-sample bucket
        // whose values happen identical must NOT show a zero-width band.
        var samples: [(key: String, value: Double)] = []
        for i in 0..<50 { samples.append(("rich", 100 + Double(i) * 5)) }
        samples.append(("thin", 100)); samples.append(("thin", 100))
        let bands = UsageNorms.bands(samples)
        let thin = bands["thin"]!
        #expect(thin.count == 2)
        #expect(thin.range80.lowerBound < thin.range80.upperBound)   // not degenerate
        // EB pulls the thin bucket's central estimate toward the pooled mean (it
        // can't trust 2 samples) — above its raw 100, but not all the way to the
        // rich bucket's typical.
        #expect(thin.typical > 100)
        #expect(thin.typical < bands["rich"]!.typical)
    }

    @Test func anomalyFlagsLullsAndSpikesWithWarmup() {
        let baseline = (0..<30).map { 100.0 + Double($0 % 7) * 20 }   // ~100–220, stable
        let lullZ = UsageNorms.anomalyZ(value: 3, baseline: baseline)
        let spikeZ = UsageNorms.anomalyZ(value: 5000, baseline: baseline)
        #expect(lullZ < -3)
        #expect(spikeZ > 3)
        #expect(UsageNorms.classify(z: lullZ) == .lull)
        #expect(UsageNorms.classify(z: spikeZ) == .spike)
        #expect(UsageNorms.classify(z: 0.5) == .normal)
        // Warm-up: too few baseline points → no judgement (z = 0).
        #expect(UsageNorms.anomalyZ(value: 3, baseline: [100, 120, 90]) == 0)
    }

    @Test func anomaliesAreLullsNotSpikesOnSkewedData() {
        // Heavy-right-tailed cost: in log space a quiet day is more anomalous than
        // even the biggest day — the real finding for this user.
        var base = (0..<28).map { 50.0 + Double($0 % 10) * 25 }   // $50–$275
        base.append(1400)                                         // one huge day
        let quietZ = UsageNorms.anomalyZ(value: 4, baseline: base)
        let hugeZ = UsageNorms.anomalyZ(value: 1400, baseline: base)
        #expect(abs(quietZ) > abs(hugeZ))                         // the lull stands out more
        #expect(UsageNorms.classify(z: quietZ) == .lull)
    }

    @Test func paceRankIsMonotone() {
        let base = (1...100).map { Double($0) }
        let low = UsageNorms.paceRank(value: 10, baseline: base)!
        let mid = UsageNorms.paceRank(value: 50, baseline: base)!
        let high = UsageNorms.paceRank(value: 95, baseline: base)!
        #expect(low < mid && mid < high)
        #expect(abs(mid - 0.5) < 0.05)
        #expect(UsageNorms.paceRank(value: 1, baseline: []) == nil)
    }
}
