import SwiftUI
import PacerCore

/// A window's current %, drawn the one way every surface draws it (#318):
/// Anthropic's reading whole, "42%"; the live meter's estimate with its
/// decimal, "42.6%".
///
/// The decimal is the mark, so the number says which it is without a hover
/// (`PacerMeterFormat` has the reasoning). Every digit is set alike: an
/// estimate that crosses into a new whole number has estimated its whole
/// digits too, so a lighter decimal would have marked the wrong part as the
/// soft one. What Anthropic last read is said beside it instead
/// (`PacerMeterCaption`, or "read 42%" where there is room for only that).
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
        let number = PacerMeterFormat.number(percent, isEstimate: isEstimate)
        Text(verbatim: prefix + number + (percentSign ? "%" : ""))
            .foregroundStyle(color)
            .monospacedDigit()
    }
}

/// The line under a window's number on a card (#318): what Anthropic last
/// read, always. "estimate · Anthropic read 50% 3m ago" under an estimate,
/// "read 3m ago" under a reading. Drawn on `PacerReadAge.Schedule`, so it
/// changes with every other age on screen.
///
/// Font and colour are the caller's (secondary, orange when the account has
/// stopped being read).
public struct PacerMeterCaption: View {
    let readout: LiveMeterReadout
    let help: String?

    public init(_ readout: LiveMeterReadout, help: String? = nil) {
        self.readout = readout
        self.help = help
    }

    public var body: some View {
        let parts = readout.captionParts
        PacerAgeLabel(readout.reading.at, help: help.map { text in { _ in text } }) { age in
            Text("\(parts.lead) \(age)\(parts.trail)")
        }
    }
}

/// The hover on a window's number: "read 42% 3m ago", and for an estimate
/// "read 42% 3m ago · estimate 42.6%". Aged by `PacerReadAge`; build it with
/// the date of the `PacerReadAge.Schedule` it is drawn on, and it changes
/// with the caption beside it.
public func pacerMeterHelp(_ readout: LiveMeterReadout, now: Date = PacerClock.now) -> String {
    readout.help(age: PacerReadAge.string(readout.reading.at, now: now))
}

/// "read 42% 3m ago": the reading under a window's number, aged the same way
/// (`pacerMeterHelp`).
public func pacerMeterReadText(_ readout: LiveMeterReadout, now: Date = PacerClock.now) -> String {
    readout.readText(age: PacerReadAge.string(readout.reading.at, now: now))
}
