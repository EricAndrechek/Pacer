import SwiftUI
import PacerCore
import PacerUI

/// Widget-target-only design constants + small layout primitives. Most
/// formatting/typography lives in `PacerUI` now (so the dashboard, the
/// menu-bar popover, and the widgets can't drift); this file keeps
/// only what's specific to the widget's tighter canvas budgets.

enum WidgetStyle {
    static let smallPad: CGFloat = 12
    static let mediumPad: CGFloat = 14
    static let largePad: CGFloat = 16
    /// Cap for project / model name truncation in fixed-width row labels.
    static let labelColumnWidth: CGFloat = 92
    /// Min cost-column width so $-aligned columns don't dance as values
    /// shrink/grow.
    static let costColumnWidth: CGFloat = 50
}

/// Card-style background that mirrors the app's `PacerCard`. Forwards
/// to `PacerDesign.cardBackground` (PacerUI) so a one-line edit there
/// retunes both the dashboard cards and the widget container fills.
var widgetCardBackground: Color { PacerDesign.cardBackground }

/// `0.6h` → `36m`, `6500s` → `1h 48m`. Used by elapsed/remaining
/// captions in widgets where space rules out a long format. Stays
/// widget-local because the dashboard doesn't have a parallel
/// "session elapsed" line at this density.
func formatDurationShort(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded()))
    let h = total / 3600
    let m = (total % 3600) / 60
    if h > 0 { return "\(h)h \(m)m" }
    if m > 0 { return "\(m)m" }
    return "\(total)s"
}

/// Standardized widget header: a small uppercase title, an optional
/// tinted leading dot, and an optional trailing value. Every widget
/// uses this so the typographic top edge is identical across the
/// gallery.
struct WidgetTitleBar<Trailing: View>: View {
    let title: String
    let dotColor: Color?
    @ViewBuilder var trailing: () -> Trailing

    init(title: String, dotColor: Color? = nil, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.dotColor = dotColor
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            if let dotColor {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
            }
            Text(title)
                .font(.caption2.weight(.semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            trailing()
        }
    }
}

/// 0..1 horizontal progress bar with the same look every widget uses
/// for inline utilization indicators. Uses `.tint` so a callsite can
/// theme it via `.tint(.green)`.
struct WidgetProgressBar: View {
    let fraction: Double  // 0...1, clamped on draw
    var height: CGFloat = 6
    var cornerRadius: CGFloat = 3

    var body: some View {
        let f = max(0.04, min(1, fraction))
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.secondary.opacity(0.15))
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.tint)
                    .frame(width: geo.size.width * CGFloat(f))
            }
        }
        .frame(height: height)
    }
}

/// A small consistent empty-state body. Used wherever a widget has
/// no data yet — keeps the typography uniform across widgets so they
/// don't feel like they came from five different apps.
struct WidgetEmptyState: View {
    let message: String
    var body: some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
