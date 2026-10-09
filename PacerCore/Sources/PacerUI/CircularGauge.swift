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

    /// The reading, or 0 when there is none — kept for callers that read it.
    public var percentage: Double { reading ?? 0 }

    public init(
        percentage: Double,
        lineWidth: CGFloat = 10,
        labelFont: Font = .system(size: 22, weight: .semibold, design: .rounded)
    ) {
        self.init(reading: percentage, lineWidth: lineWidth, labelFont: labelFont)
    }

    public init(
        reading: Double?,
        lineWidth: CGFloat = 10,
        labelFont: Font = .system(size: 22, weight: .semibold, design: .rounded)
    ) {
        self.reading = reading
        self.lineWidth = lineWidth
        self.labelFont = labelFont
    }

    private var fraction: CGFloat {
        guard let reading else { return 0 }
        return max(0, min(1, CGFloat(reading) / 100))
    }

    private var color: Color {
        UsageBand(percentage: percentage).color
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.4), value: fraction)
            Text(reading.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(labelFont)
                .foregroundStyle(reading == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .monospacedDigit()
                // "100%" is one glyph wider than every other reading, and the
                // callers size this ring for two digits. Without these it
                // wraps to two lines and spills outside the ring — reported as
                // issue #125 against the 22pt menu-bar gauge.
                //
                // Shrink-to-fit rather than a smaller font for everyone:
                // anything that already fits is untouched, so the dashboard
                // and widget gauges render identically to before.
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
    }
}
