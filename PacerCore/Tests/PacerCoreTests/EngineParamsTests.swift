import Foundation
import Testing
@testable import PacerCore

/// The versioned parameter set: the tag must be a pure, stable function of
/// the values, and the defaults must stay pinned to the validated constants
/// (a drive-by change here silently re-tunes the whole engine).
@Suite("Engine params")
struct EngineParamsTests {

    @Test func versionTagIsStableAcrossInstances() {
        #expect(EngineParams().versionTag == EngineParams().versionTag)
        #expect(EngineParams.version == EngineParams.current.versionTag)
    }

    @Test func versionTagChangesWhenAnyKnobChanges() {
        let base = EngineParams()
        var tweaked = EngineParams()
        tweaked.conformalMinResiduals = 12
        #expect(base.versionTag != tweaked.versionTag)

        var tweaked2 = EngineParams()
        tweaked2.recencyHalfLifeFraction = 0.2
        #expect(base.versionTag != tweaked2.versionTag)
        #expect(tweaked.versionTag != tweaked2.versionTag)
    }

    @Test func defaultsMatchTheValidatedConstants() {
        let p = EngineParams.current
        #expect(p.conformalMinResiduals == 8)
        #expect(p.rlStratumMinScores == 10)
        #expect(p.poolTolerance == 1.25)
        #expect(p.poolMinPeriods == 10)
        #expect(p.poolRecencyWindow == 30)
        #expect(p.linearRecentLookbackFraction == 0.3)
        #expect(p.recencyHalfLifeFraction == 0.15)
        #expect(p.shadowPromotionMinPeriods == 15)
        #expect(p.conformalBlockMinCycles == 40)
    }

    @Test func versionTagMatchesPythonHarness() {
        // research/harness/pacer_replay.py `Params().version_tag()` computes
        // the same FNV-1a over the same canonical string; this pin catches
        // either side drifting. Update BOTH when a knob is added/changed.
        #expect(EngineParams.current.versionTag == "v1-4c0cc586")
    }

    @Test func paramsRoundTripThroughJSON() throws {
        let data = try JSONEncoder().encode(EngineParams.current)
        let back = try JSONDecoder().decode(EngineParams.self, from: data)
        #expect(back == EngineParams.current)
        #expect(back.versionTag == EngineParams.current.versionTag)
    }
}
