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

    @Test func theHeadingNamesTheSpanWhenItIsNarrower() {
        typealias Span = EngineSelfEval.Accuracy.Span
        let whole = Span(start: "a", cycles: 61, isWholeRecord: true)
        let last = Span(start: "b", cycles: 24, isWholeRecord: false)
        #expect(PacerAccuracyFormat.columnTitle(nil) == "TYPICAL ACCURACY, PAST CYCLES")
        #expect(PacerAccuracyFormat.columnTitle(whole) == "TYPICAL ACCURACY, PAST CYCLES")
        #expect(PacerAccuracyFormat.columnTitle(last) == "TYPICAL ACCURACY, LAST 24 CYCLES")

        let today = "Typical |shown final − actual final| at this half of the window (first or second) across your "
            + "completed cycles (median; mean on weekly windows), in percentage points — lower is better"
        #expect(PacerAccuracyFormat.columnHelp(nil) == today)
        #expect(PacerAccuracyFormat.columnHelp(whole) == today)
        #expect(PacerAccuracyFormat.columnHelp(last).contains("over your last 24 completed cycles"))
        #expect(PacerAccuracyFormat.columnHelp(last).hasSuffix("A model scored on fewer says how many."))
    }
}
