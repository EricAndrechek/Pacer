import SwiftUI
import PacerCore

/// A window's current %, drawn the one way every surface draws it (#318):
/// Anthropic's reading whole, "42%"; the live meter's estimate with its
/// decimal, "42.6%", the decimal in a lighter tint of the same colour.
///
/// The decimal is the mark, so the number says which it is without a hover
/// (`PacerMeterFormat` has the reasoning). The tint is the drawn surfaces'
/// echo of the chart, where the estimated stretch is the dotted one: the
/// digit only the estimate has is the soft part of the number.
///
/// Plain values in, so the menu bar, the dropdown, the pace card, the
/// comparison sheet and the widgets all take it whatever model type they
/// hold. Font, weight and size come from the caller's environment; `color`
/// is the caller's (a band colour, `.primary`, red at the red band).
public struct PacerMeterValue: View {
    let percent: Double
    let isEstimate: Bool
    let color: Color
    let prefix: String
    let percentSign: Bool

    /// The estimate's decimal against its whole number: light enough to read
    /// as secondary, dark enough to stay legible in the menu bar.
    public static let fractionOpacity = 0.55

    public init(_ percent: Double, isEstimate: Bool, color: Color = .primary,
                prefix: String = "", percentSign: Bool = true) {
        self.percent = percent
        self.isEstimate = isEstimate
        self.color = color
        self.prefix = prefix
        self.percentSign = percentSign
    }

    /// A readout's number: its estimate, else its reading.
    public init(_ readout: LiveMeterReadout, color: Color = .primary, prefix: String = "",
                percentSign: Bool = true) {
        self.init(readout.percent, isEstimate: readout.isEstimate, color: color,
                  prefix: prefix, percentSign: percentSign)
    }

    public var body: some View {
        let parts = PacerMeterFormat.parts(percent, isEstimate: isEstimate)
        // One `Text` in both cases (an empty fraction for a reading), so a
        // reading landing on an estimate changes a value, not the view.
        Text("\(Text(prefix + parts.whole).foregroundStyle(color))\(Text(parts.fraction ?? "").foregroundStyle(color.opacity(Self.fractionOpacity)))\(Text(percentSign ? "%" : "").foregroundStyle(color))")
            .monospacedDigit()
    }
}

/// The hover on a window's number: "read 42% 3 min. ago", and for an
/// estimate "read 42% 3 min. ago · estimate 42.6%". Aged by `pacerRelative`
/// against `PacerClock.now`, like the "read 3 min. ago" label, so a label and
/// a hover drawn on the same minute tick say the same thing.
public func pacerMeterHelp(_ readout: LiveMeterReadout) -> String {
    readout.help(age: pacerRelative(readout.reading.at))
}

/// "read 42% 3 min. ago": the reading under a window's number, aged the same
/// way (`pacerMeterHelp`).
public func pacerMeterReadText(_ readout: LiveMeterReadout) -> String {
    readout.readText(age: pacerRelative(readout.reading.at))
}
