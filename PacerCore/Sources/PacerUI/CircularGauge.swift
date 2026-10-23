import SwiftUI
import PacerCore

/// Donut-style gauge with a centered percentage label. Color is driven
/// by `UsageBand` (absolute usage) rather than `PaceBand` (vs pace) so
/// the same primitive renders correctly in places without a `resetsAt`
/// (MenuBarExtra glyph, widget gauges).
///
/// `lineWidth` and `labelFont` are exposed so dashboard size (90pt
/// frame, 22pt label) and widget size (78pt frame, 22pt label, or 96pt
/// frame, 26pt label) share the same geometry without forking. Defaults
/// match the dashboard's previous values so existing call sites don't
/// need to pass arguments.
///
/// **No reading is not 0%.** `init(reading:)` takes an optional: nil draws the
/// empty track with a "—" label, the same dash every other surface uses for a
/// window it has no reading for. An account Pacer has only just seen has no
/// reading yet (#241), and a ring reading "0%" would say it has used nothing,
/// which nobody knows. Callers with a value are unaffected.
public struct CircularGauge: View {
    /// nil: no reading.
    public let reading: Double?
    public var lineWidth: CGFloat
    public var labelFont: Font
    /// The live meter's estimate on that reading (#318), when the number is
    /// one. The ring draws the reading solid and the estimated stretch past
    /// it as a lighter tail in the same colour, the way the chart draws its
    /// dotted stretch; the label is the estimate, with its decimal.
    public var estimate: Double?
    /// The number inside the ring. Off where it is printed beside the ring
    /// anyway: the dropdown's rows, whose 22 pt ring had no room for "50.7".
    public var showsLabel: Bool

    /// The number shown: the estimate, else the reading, else 0.
    public var percentage: Double { estimate ?? reading ?? 0 }

    /// The tail's strength against the solid reading.
    public static let estimateOpacity = 0.45

    public init(
        percentage: Double,
        lineWidth: CGFloat = 10,
        labelFont: Font = .system(size: 22, weight: .semibold, design: .rounded)
    ) {
        self.init(reading: percentage, lineWidth: lineWidth, labelFont: labelFont)
    }

    public init(
        reading: Double?,
        estimate: Double? = nil,
        lineWidth: CGFloat = 10,
        labelFont: Font = .system(size: 22, weight: .semibold, design: .rounded),
        showsLabel: Bool = true
    ) {
        self.reading = reading
        self.estimate = reading == nil ? nil : estimate
        self.lineWidth = lineWidth
        self.labelFont = labelFont
        self.showsLabel = showsLabel
    }

    private static func fraction(_ percent: Double?) -> CGFloat {
        guard let percent else { return 0 }
        return max(0, min(1, CGFloat(percent) / 100))
    }

    /// The band of the number shown, for both stretches: one window, one colour.
    private var color: Color {
        UsageBand(percentage: percentage).color
    }

    public var body: some View {
        // An estimate below its reading has restarted past that reading's
        // reset: the reading is the window before's, and only the estimate
        // belongs to this one.
        let restarted = estimate.map { $0 < (reading ?? 0) } ?? false
        let solid = restarted ? 0 : Self.fraction(reading)
        let tail = max(solid, Self.fraction(estimate))
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.18), lineWidth: lineWidth)
            // Under the solid arc, from 0, so its round cap never shows a
            // gap where the two meet.
            Circle()
                .trim(from: 0, to: tail)
                .stroke(
                    color.opacity(Self.estimateOpacity),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.4), value: tail)
            Circle()
                .trim(from: 0, to: solid)
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.4), value: solid)
            if showsLabel {
                label
                    .font(labelFont)
                    .monospacedDigit()
                    // "100%" is one glyph wider than every other reading, and
                    // the callers size this ring for two digits. Without these
                    // it wraps to two lines and spills outside the ring —
                    // reported as issue #125 against the 22pt menu-bar gauge.
                    //
                    // Shrink-to-fit rather than a smaller font for everyone:
                    // anything that already fits is untouched.
                    .lineLimit(1)
                    .minimumScaleFactor(estimate != nil ? 0.55 : 0.65)
            }
        }
    }

    @ViewBuilder
    private var label: some View {
        if let estimate {
            // No "%": a two-digit ring has no room for it beside a decimal.
            PacerMeterValue(estimate, isEstimate: true, percentSign: false)
        } else if let reading {
            PacerMeterValue(reading, isEstimate: false)
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }
}
