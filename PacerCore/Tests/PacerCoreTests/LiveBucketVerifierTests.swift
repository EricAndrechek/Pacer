import Foundation
import Testing
@testable import PacerCore

/// When a rollup bucket gets rebuilt from its samples (#151): soon after a
/// write, once after it closes, and on a slow sweep, a few per cycle.
@Suite("Live bucket verifier")
struct LiveBucketVerifierTests {

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
    private func verifier(limit: Int = 3) -> LiveBucketVerifier<String> {
        LiveBucketVerifier(limit: limit, writeDelay: 5 * 60, sweepAge: 30 * 60) { $0 }
    }

    @Test func aWrittenBucketIsRebuiltWithinTheDelayOfItsWrite() {
        var v = verifier()
        v.note(written: ["a"], rebuilt: [], now: at(0))
        #expect(v.pick(open: nil, now: at(4)).isEmpty)
        #expect(v.pick(open: nil, now: at(5)) == ["a"])
        // Checked; the next write starts the clock again.
        #expect(v.pick(open: nil, now: at(6)).isEmpty)
        v.note(written: ["a"], rebuilt: [], now: at(7))
        v.note(written: ["a"], rebuilt: [], now: at(9))   // measured from the first
        #expect(v.pick(open: nil, now: at(12)) == ["a"])
    }

    /// A bucket the recompute rebuilds from samples anyway (polluted) has been
    /// checked by that rebuild.
    @Test func aBucketRebuiltThisCycleCountsAsChecked() {
        var v = verifier()
        v.note(written: ["a"], rebuilt: [], now: at(0))
        v.note(written: ["a"], rebuilt: ["a"], now: at(2))
        #expect(v.pick(open: nil, now: at(6)).isEmpty)
    }

    @Test func closedBucketsGoFirstAndAPassTakesAtMostTheLimit() {
        var v = verifier()
        v.note(written: ["w"], rebuilt: [], now: at(0))
        v.enqueueClosed(["c1", "c2", "c3", "c4"])
        #expect(v.pick(open: nil, now: at(10)) == ["c1", "c2", "c3"])
        #expect(v.pick(open: nil, now: at(10)) == ["c4", "w"])
        #expect(v.closed.isEmpty)
    }

    /// The backstop for drift that does not come through a write: every open
    /// bucket, written to or not. First `writeDelay` after launch, so drift
    /// from before a relaunch is not left a whole sweep.
    @Test func theSweepReachesBucketsNobodyWroteTo() {
        var v = verifier()
        let open: Set = ["a", "b"]
        #expect(v.pick(open: open, now: at(0)).isEmpty)
        #expect(v.pick(open: open, now: at(5)) == ["a", "b"])
        #expect(v.pick(open: open, now: at(34)).isEmpty)
        #expect(v.pick(open: open, now: at(35)) == ["a", "b"])
        // No open set this cycle: no sweep, however overdue.
        #expect(v.pick(open: nil, now: at(90)).isEmpty)
    }

    @Test func itForgetsBucketsThatCanNoLongerComeDue() {
        var v = verifier()
        _ = v.pick(open: ["a", "b"], now: at(0))
        _ = v.pick(open: ["a", "b"], now: at(5))
        _ = v.pick(open: ["c"], now: at(6))
        #expect(v.verifiedAt["a"] == nil)
        #expect(v.verifiedAt["b"] == nil)
    }
}
