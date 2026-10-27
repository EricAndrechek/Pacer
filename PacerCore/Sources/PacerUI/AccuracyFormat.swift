import Foundation
import PacerCore

/// How the compare sheet writes a model's track record: its typical miss
/// ("within ±3%"), the cycles behind it when they are fewer than the
/// column's, and the column's heading. One place, so the drawn rows, the
/// "More models" rows and the info popover can't print the same number two
/// ways.
///
/// The numbers are percentage points of the window (`EngineSelfEval
/// .Accuracy.MethodStat.typicalAbsError`), written with "%" as the meter is.
public enum PacerAccuracyFormat {

    /// "within ±3%"; "within ±0.4%" under a point; "—" without a number.
    ///
    /// Whole points from 1 up. Under a point, one decimal: rounded to a
    /// whole point a 0.4-point miss printed "within ±0%", which read as a
    /// bug and claimed a perfect record where there was only a close one.
    /// The switch is judged on the number as printed, so 0.96 is "±1%" and
    /// never "±1.0%". A miss of exactly 0 is "within ±0.0%": the record's
    /// typical call was spot on (a weekly window's capped cycles are scored
    /// exactly right), and the decimal keeps it from reading as a blank.
    public static func within(_ miss: Double?) -> String {
        guard let miss, miss.isFinite else { return "—" }
        // Not `max(0, miss)`: that keeps a negative zero, printed "-0.0".
        let m = miss > 0 ? miss : 0
        if (m * 10).rounded() < 10 { return String(format: "within ±%.1f%%", m) }
        return String(format: "within ±%.0f%%", m)
    }

    /// A row's record: "within ±2%", or "within ±2% · 12 cycles" when the
    /// number rests on fewer cycles than the column's
    /// (`EngineSelfEval.Accuracy.partialCycles`).
    public static func record(_ miss: Double?, partialCycles: Int?) -> String {
        let number = within(miss)
        guard let n = partialCycles, miss?.isFinite == true else { return number }
        return "\(number) · \(cycles(n))"
    }

    /// "1 cycle", "12 cycles".
    public static func cycles(_ n: Int) -> String { n == 1 ? "1 cycle" : "\(n) cycles" }

    /// The accuracy column's heading. Over a span narrower than the record
    /// it says how many of the newest cycles every number covers: "TYPICAL
    /// ACCURACY, LAST 24 CYCLES". Over the whole record, as it always read.
    public static func columnTitle(_ span: EngineSelfEval.Accuracy.Span?) -> String {
        guard let span, !span.isWholeRecord else { return "TYPICAL ACCURACY, PAST CYCLES" }
        return "TYPICAL ACCURACY, LAST \(cycles(span.cycles).uppercased())"
    }

    /// The heading's tooltip.
    public static func columnHelp(_ span: EngineSelfEval.Accuracy.Span?) -> String {
        let what = "Typical |shown final − actual final| at this half of the window (first or second)"
        let how = "(median; mean on weekly windows), in percentage points — lower is better"
        guard let span, !span.isWholeRecord else { return "\(what) across your completed cycles \(how)" }
        let last = span.cycles == 1 ? "completed cycle" : "\(span.cycles) completed cycles"
        return "\(what) over your last \(last), the ones the models are compared on \(how). "
            + "A model scored on fewer says how many."
    }
}
