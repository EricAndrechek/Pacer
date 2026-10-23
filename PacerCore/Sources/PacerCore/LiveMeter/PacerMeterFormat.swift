import Foundation

/// How every surface writes a window's current % (#318): Anthropic's
/// reading as a whole number, the live meter's estimate with one decimal.
///
///     42%     a reading
///     42.6%   an estimate, built on that reading and the spend since
///
/// **Why the decimal is the mark.** Anthropic's readings are whole numbers,
/// so a decimal can only have come from Pacer. That makes the number itself
/// say which it is, on every surface and at any size, without a hover or a
/// legend, and in plain text too (the window title, a tooltip, `pacer
/// report`). An estimate keeps its decimal even when it lands on a whole
/// number ("43.0%"), so the rule has no exception to learn.
///
/// Not "≈": that already means a forecast ("≈52% at reset"). Not "~" either,
/// which reads as the same thing. Drawn surfaces also set the decimal in a
/// lighter tint (`PacerMeterValue` in PacerUI), the way the chart draws the
/// estimated stretch dotted; the CLI, being text, adds the word "est".
///
/// The whole points the gate and the alerts judge are `LiveMeterValue
/// .percent`, never this: the shown decimal is cut, not rounded, so its whole
/// part is always that number.
public enum PacerMeterFormat {

    /// `value` cut to one decimal: never rounded up, so 42.96 is 42.9 and
    /// the shown number is never a point ahead of the whole one. The
    /// tolerance keeps a float sum a hair under a tenth (42.59999999) from
    /// losing it.
    public static func tenths(_ value: Double) -> Double {
        (value * 10 + 1e-6).rounded(.down) / 10
    }

    /// "42" for a reading, "42.6" for an estimate.
    public static func number(_ percent: Double, isEstimate: Bool) -> String {
        guard isEstimate else { return String(Int(percent.rounded())) }
        return String(format: "%.1f", tenths(percent))
    }

    /// "42%" for a reading, "42.6%" for an estimate.
    public static func percent(_ percent: Double, isEstimate: Bool) -> String {
        number(percent, isEstimate: isEstimate) + "%"
    }

    /// The two halves a drawn surface sets apart: "42" and ".6", or "42"
    /// and nil for a reading.
    public static func parts(_ percent: Double, isEstimate: Bool) -> (whole: String, fraction: String?) {
        let text = number(percent, isEstimate: isEstimate)
        guard isEstimate, let dot = text.firstIndex(of: ".") else { return (text, nil) }
        return (String(text[..<dot]), String(text[dot...]))
    }
}
