import Foundation
import Testing
@testable import PacerCore

@Suite("EngineSnapshot export")
struct EngineSnapshotTests {

    /// The widget and the Shortcuts intents must keep reading snapshots that
    /// were written before `cost` existed. A missing `cost` key has to decode
    /// to `nil`, never throw.
    @Test func decodesLegacySnapshotWithoutCostField() throws {
        let legacy = #"{"generatedUnix": 1000000000, "fiveHour": null, "sevenDay": null}"#
        let snapshot = try #require(EngineSnapshot.decode(legacy))
        #expect(snapshot.cost == nil)
        #expect(snapshot.fiveHour == nil)
        #expect(snapshot.generatedUnix == 1_000_000_000)
    }

    /// Round-trip with a populated cost section survives encode → decode.
    @Test func roundTripsCostOutlook() throws {
        let cost = EngineSnapshot.CostOutlook(
            projectedTodayUSD: 5.5, projectedTodayLoUSD: 4.0, projectedTodayHiUSD: 7.2,
            projectedMonthUSD: 190, projectedMonthLoUSD: 160, projectedMonthHiUSD: 230,
            pacePercentile: 0.82, paceNote: "running hot")
        let original = EngineSnapshot(generatedUnix: 12345, fiveHour: nil, sevenDay: nil, cost: cost)
        let json = try #require(original.encodedJSON())
        let decoded = try #require(EngineSnapshot.decode(json))
        #expect(decoded == original)
        #expect(decoded.cost?.paceNote == "running hot")
        #expect(decoded.cost?.projectedMonthHiUSD == 230)
    }
}
