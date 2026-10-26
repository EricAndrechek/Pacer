import Foundation
import Testing
@testable import PacerCore

/// `LimitSim` pieces checked on their own.
@Suite struct SimulationLimitSimTests {
    @Test func truncatedMedianIsNumpys() {
        var rng = ArenaRNG(seed: 5)
        for n in 1...60 {
            for _ in 0..<20 {
                var xs = (0..<n).map { _ in Millis(rng.uniform() * 1_000) * (rng.uniform() < 0.3 ? 1 : 7) }
                let s = xs.sorted(), m = n / 2
                let want = n % 2 == 1 ? s[m] : Millis((Double(s[m - 1]) + Double(s[m])) / 2)
                #expect(LimitSim.truncatedMedian(&xs) == want)
            }
        }
    }

    /// `cycleGroups` finds clustered resets in one pass and sorts otherwise;
    /// both must give the Python's cycles (sorted resets, the anchor walk)
    /// for any reset sequence: jittering clusters, a reset that reads low, a
    /// reading back in an older cycle, cycles under a window apart (a
    /// re-based allowance), and random values.
    @Test func cycleGroupsFindTheSortedWalksCycles() {
        var rng = ArenaRNG(seed: 99)
        let dur = 5 * ArenaTime.hour
        var fastPaths = 0
        for trial in 0..<400 {
            var r: [Millis] = []
            var centre: Millis = 1_760_000_000_000
            let cycles = 1 + Int(rng.uniform() * 12)
            for _ in 0..<cycles {
                // Cycles a window or more apart, and sometimes much closer
                // (just over or under half a window: the walk's edge).
                let gap: Millis = switch trial % 4 {
                case 0: dur + Millis(rng.uniform() * Double(dur))
                case 1: dur / 2 + Millis(rng.uniform() * 2_000) - 1_000
                case 2: Millis(rng.uniform() * Double(dur))
                default: dur
                }
                centre += gap
                for _ in 0..<(1 + Int(rng.uniform() * 30)) {
                    r.append(centre + Millis(rng.uniform() * 900) - (rng.uniform() < 0.1 ? 600 : 0))
                }
            }
            if trial % 5 == 0, r.count > 3 { r.append(r[Int(rng.uniform() * Double(r.count / 2))]) }   // back in an old cycle
            if trial % 7 == 0 { r = r.map { _ in 1_760_000_000_000 + Millis(rng.uniform() * Double(8 * dur)) } }
            let fast = LimitSim.cycleGroups(r, duration: dur)
            let sorted = LimitSim.cycleGroups(r, duration: dur, sortAlways: true)
            #expect(fast.count == sorted.count, "trial \(trial)")
            #expect(zip(fast, sorted).allSatisfy { $0.members == $1.members && $0.reset == $1.reset }, "trial \(trial)")
            // Count the trials the one pass handled (it refuses some, by design).
            if LimitSim.clusters(r, half: Double(dur) / 2) != nil { fastPaths += 1 }
        }
        #expect(fastPaths > 100)
    }
}
