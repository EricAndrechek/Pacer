import Foundation
import Testing
@testable import PacerCore

@Suite("How a refit backs off under memory pressure (#389)")
struct EngineRefitPolicyTests {
    @Test func floorStaysBounded() {
        #expect(EngineRefitPolicy.floor(base: 300, pressure: .normal) == 300)
        #expect(EngineRefitPolicy.floor(base: 300, pressure: .warning) == 600)
        #expect(EngineRefitPolicy.floor(base: 300, pressure: .critical) == 1800)
    }

    /// Longer than this and a five-hour window's arena line would blank between
    /// refits for as long as a Mac sat at warning.
    @Test func warningFloorKeepsAFiveHourLineDrawn() {
        let line = ArenaLiveCache.maxAge(duration: 5 * 3600)
        #expect(EngineRefitPolicy.floor(base: 300, pressure: .warning) < line)
    }

    @Test func pressureNarrowsTheLiveRoundToThePick() {
        let drawn = ["pick", "second", "third"]
        #expect(EngineRefitPolicy.liveModels(drawn, pressure: .normal) == drawn)
        #expect(EngineRefitPolicy.liveModels(drawn, pressure: .warning) == ["pick"])
        #expect(EngineRefitPolicy.liveModels(drawn, pressure: .critical).isEmpty)
        #expect(EngineRefitPolicy.liveModels([], pressure: .warning).isEmpty)
    }

    @Test func recordBackfillWaitsOutOnlyCritical() {
        #expect(EngineRefitPolicy.recordBackfillAllowed(pressure: .normal))
        #expect(EngineRefitPolicy.recordBackfillAllowed(pressure: .warning))
        #expect(!EngineRefitPolicy.recordBackfillAllowed(pressure: .critical))
    }

    @Test func heavyPageInUnderPressureDefersTheNextRefit() {
        let heavy: UInt64 = 373_000_000
        #expect(EngineRefitPolicy.floor(base: 300, pressure: .warning, lastPageinBytes: heavy) == 1200)
        #expect(EngineRefitPolicy.floor(base: 300, pressure: .critical, lastPageinBytes: heavy) == 3600)
        // Capped at an hour whatever the base.
        #expect(EngineRefitPolicy.floor(base: 600, pressure: .critical, lastPageinBytes: heavy) == 3600)
    }

    @Test func nothingChangesWithoutBothPressureAndAHeavyPageIn() {
        let heavy: UInt64 = 489_000_000
        #expect(EngineRefitPolicy.floor(base: 300, pressure: .normal, lastPageinBytes: heavy) == 300)
        #expect(EngineRefitPolicy.floor(base: 300, pressure: .warning, lastPageinBytes: 99_000_000) == 600)
        #expect(EngineRefitPolicy.floor(base: 300, pressure: .warning, lastPageinBytes: 0) == 600)
    }
}
