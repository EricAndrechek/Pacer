import Foundation
import Testing
@testable import PacerCore
@testable import PacerUI

/// The dashed line to the limit is red only for the engine's claim, orange for
/// a crossing the claim withholds, matching the chip ("limit in …" vs "may hit
/// limit in …"). The chart is told, never left to guess.
@Suite("Projection line colour follows the claim")
struct RLProjectionClaimTests {

    @Test func theChartDataCarriesTheClaim() {
        let start = Date(timeIntervalSince1970: 1_752_000_000)
        let base = PaceChartView.Data(cycleStart: start, resetsAt: start.addingTimeInterval(18_000),
                                      durationSeconds: 18_000, points: [.init(time: start, value: 0)], usedPct: 40)
        #expect(!base.projectionClaimed)
        let line = [PaceChartView.Data.Point(time: start, value: 40),
                    .init(time: start.addingTimeInterval(9_000), value: 100)]
        let claimed = base.withProjection(line, crossesFullAt: start.addingTimeInterval(9_000), claimed: true)
        let withheld = base.withProjection(line, crossesFullAt: start.addingTimeInterval(9_000), claimed: false)
        #expect(claimed.projectionClaimed)
        #expect(!withheld.projectionClaimed)
        #expect(claimed != withheld)          // a change of claim redraws the chart
    }

    /// The widget reads the claim from the exported snapshot. One written
    /// before the field existed decodes as unclaimed rather than failing.
    @Test func anOlderSnapshotWithoutTheFieldStillDecodes() throws {
        let old = #"{"usedPct":40,"crossingUnix":1752009000,"resetsUnix":1752018000,"trajectory":[]}"#
        let decoded = try JSONDecoder().decode(EngineSnapshot.WindowOutlook.self, from: Data(old.utf8))
        #expect(decoded.hitClaimed == nil)
        let round = try JSONDecoder().decode(EngineSnapshot.WindowOutlook.self, from: JSONEncoder().encode(
            EngineSnapshot.WindowOutlook(usedPct: 60, endPct: 100, endLoPct: nil, endHiPct: nil,
                                         crossingUnix: 1_752_009_000, resetsUnix: 1_752_018_000,
                                         trajectory: [], hitClaimed: true)))
        #expect(round.hitClaimed == true)
    }
}
