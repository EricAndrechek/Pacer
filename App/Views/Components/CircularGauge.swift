import SwiftUI
import PacerCore

/// Donut-style gauge with a centered percentage label. Color is driven
/// by `UsageBand` (absolute usage) rather than `PaceBand` (vs pace) so
/// the same primitive can render in MenuBarExtra and widgets where
/// no `resetsAt` is necessarily available.
///
/// `lineWidth` and `font` are exposed so the same primitive can render
/// at dashboard-card size (90pt) and widget size (44pt) without forking
/// the geometry.
struct CircularGauge: View {
    let percentage: Double
    var lineWidth: CGFloat = 10
    var labelFont: Font = .system(size: 22, weight: .semibold, design: .rounded)

    private var fraction: CGFloat {
        max(0, min(1, CGFloat(percentage) / 100))
    }

    private var color: Color {
        switch UsageBand(percentage: percentage) {
        case .green:  return .green
        case .yellow: return .yellow
        case .orange: return .orange
        case .red:    return .red
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.4), value: fraction)
            Text("\(Int(percentage.rounded()))%")
                .font(labelFont)
                .monospacedDigit()
        }
    }
}
