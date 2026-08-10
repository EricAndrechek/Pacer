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
public struct CircularGauge: View {
    public let percentage: Double
    public var lineWidth: CGFloat
    public var labelFont: Font

    public init(
        percentage: Double,
        lineWidth: CGFloat = 10,
        labelFont: Font = .system(size: 22, weight: .semibold, design: .rounded)
    ) {
        self.percentage = percentage
        self.lineWidth = lineWidth
        self.labelFont = labelFont
    }

    private var fraction: CGFloat {
        max(0, min(1, CGFloat(percentage) / 100))
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
            Text("\(Int(percentage.rounded()))%")
                .font(labelFont)
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
