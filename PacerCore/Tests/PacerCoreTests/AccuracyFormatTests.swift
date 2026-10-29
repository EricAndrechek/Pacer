import Testing
@testable import PacerCore
import PacerUI

/// The compare sheet's record text (`PacerAccuracyFormat`): whole points
/// from 1 up, one decimal under a point, and the column's heading.
@Suite("Accuracy format")
struct AccuracyFormatTests {

    @Test func wholePointsFromOneUp() {
        #expect(PacerAccuracyFormat.within(3.2) == "within ±3%")
        #expect(PacerAccuracyFormat.within(1) == "within ±1%")
        #expect(PacerAccuracyFormat.within(12.6) == "within ±13%")
    }

    /// Under a point, a decimal: "±0%" read as a bug.
    @Test func oneDecimalUnderAPoint() {
        #expect(PacerAccuracyFormat.within(0.4) == "within ±0.4%")
        #expect(PacerAccuracyFormat.within(0.94) == "within ±0.9%")
        #expect(PacerAccuracyFormat.within(0.04) == "within ±0.0%")
        #expect(PacerAccuracyFormat.within(0) == "within ±0.0%")
        #expect(PacerAccuracyFormat.within(-0.0) == "within ±0.0%")
        // Judged as printed: never "±1.0%".
        #expect(PacerAccuracyFormat.within(0.96) == "within ±1%")
    }

    @Test func noNumberIsADash() {
        #expect(PacerAccuracyFormat.within(nil) == "—")
        #expect(PacerAccuracyFormat.within(.infinity) == "—")
        #expect(PacerAccuracyFormat.within(.nan) == "—")
        #expect(PacerAccuracyFormat.record(nil, partialCycles: 12) == "—")
    }

    @Test func aShorterRecordSaysHowManyCycles() {
        #expect(PacerAccuracyFormat.record(2, partialCycles: nil) == "within ±2%")
        #expect(PacerAccuracyFormat.record(2, partialCycles: 12) == "within ±2% · 12 cycles")
        #expect(PacerAccuracyFormat.record(0.5, partialCycles: 1) == "within ±0.5% · 1 cycle")
    }

    /// The heading names the span once, so no row has to.
    @Test func theHeadingNamesTheSpan() {
        #expect(PacerAccuracyFormat.columnTitle(spanCycles: 0) == "TYPICAL MISS")
        #expect(PacerAccuracyFormat.columnTitle(spanCycles: 1) == "TYPICAL MISS, LAST CYCLE")
        #expect(PacerAccuracyFormat.columnTitle(spanCycles: 24) == "TYPICAL MISS, LAST 24 CYCLES")

        let what = "How far each model's call of the final has typically been off at this point in the window, "
            + "in percentage points; lower is better."
        let counted = " Counted where the models' calls differed by 2 points or more."
        #expect(PacerAccuracyFormat.columnHelp(spanCycles: 0, disagreement: 2) == what + counted)
        #expect(PacerAccuracyFormat.columnHelp(spanCycles: 1, disagreement: 2)
            == what + counted + " Over your last completed cycle; a model scored on fewer says how many.")
        #expect(PacerAccuracyFormat.columnHelp(spanCycles: 24, disagreement: 2)
            == what + counted + " Over your last 24 completed cycles; a model scored on fewer says how many.")
        // Without the filter, no such sentence; the default is the engine's.
        #expect(PacerAccuracyFormat.columnHelp(spanCycles: 0, disagreement: 0) == what)
        #expect(PacerAccuracyFormat.columnHelp(spanCycles: 24)
            == PacerAccuracyFormat.columnHelp(spanCycles: 24, disagreement: EngineParams.current.rlDisagreementPoints))
    }
}
