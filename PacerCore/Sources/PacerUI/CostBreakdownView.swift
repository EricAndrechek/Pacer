import SwiftUI
import PacerCore

// The shared cost-breakdown pieces (#225). Every screen that shows which of
// the five priced parts made up a cost — Day detail, Project detail, the
// Models tab — draws them with these, from a plain `CostBreakdown`, so the
// parts, their order, their colours and the cache-hit definition cannot
// drift between screens.

/// A stacked horizontal bar: one segment per priced part, sized by its share
/// of the cost, in `CostComponent` order. The exact dollars are in its
/// tooltip.
public struct PacerCostBar: View {
    private let breakdown: CostBreakdown
    private let height: CGFloat

    public init(_ breakdown: CostBreakdown, height: CGFloat = 8) {
        self.breakdown = breakdown
        self.height = height
    }

    public var body: some View {
        let parts = breakdown.parts
        GeometryReader { geo in
            HStack(spacing: 0) {
                // Every part gets a segment, zero-width when it is $0, so the
                // row's identity does not change as a part comes and goes.
                ForEach(parts) { part in
                    Rectangle()
                        .fill(part.component.color)
                        .frame(width: max(0, geo.size.width * part.share))
                }
            }
        }
        .frame(height: height)
        .background(Color.primary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: height / 2))
        .help(pacerCostBreakdownHelp(breakdown))
        .accessibilityElement()
        .accessibilityLabel("Cost by part")
        .accessibilityValue(pacerCostBreakdownSpoken(breakdown))
    }
}

/// The breakdown for one total: the stacked bar, the five parts with their
/// dollars and share, and the cache hit rate.
///
/// It does not print the total itself — every screen that shows it already
/// has the total in its summary, and the parts are what this adds. With no
/// cost to split (every model unpriced) it is only the hit rate: five $0
/// parts would say nothing.
public struct PacerCostBreakdownView: View {
    private let breakdown: CostBreakdown

    public init(_ breakdown: CostBreakdown) {
        self.breakdown = breakdown
    }

    /// Whether there is anything to show — callers hide the card otherwise.
    public static func hasContent(_ breakdown: CostBreakdown) -> Bool {
        breakdown.total > 0 || breakdown.cacheHitRatio != nil
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if breakdown.total > 0 {
                PacerCostBar(breakdown, height: 10)
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: 12, alignment: .topLeading),
                        count: CostComponent.allCases.count),
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(breakdown.parts) { part in
                        PartCell(part: part)
                    }
                }
            }
            if let ratio = breakdown.cacheHitRatio {
                PacerCacheHitRow(ratio: ratio)
            }
        }
    }

    private struct PartCell: View {
        let part: CostBreakdown.Part

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(part.component.color)
                        .frame(width: 8, height: 8)
                    Text(part.component.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(pacerCost(part.usd))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(part.percentLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                .padding(.leading, 13)
            }
            // A $0 part stays in its column, quieter, rather than leaving a
            // gap that would shift the others between days.
            .opacity(part.usd > 0 ? 1 : 0.45)
            .help("\(part.component.label): \(pacerCostExact(part.usd))")
        }
    }
}

/// One labelled stacked bar — a model's or a project's parts — with a
/// caller-supplied trailing slot.
public struct PacerCostBreakdownRow<Trailing: View>: View {
    private let label: String
    private let labelWidth: CGFloat
    private let breakdown: CostBreakdown
    private let trailing: Trailing

    public init(
        label: String,
        breakdown: CostBreakdown,
        labelWidth: CGFloat = 130,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.label = label
        self.labelWidth = labelWidth
        self.breakdown = breakdown
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: labelWidth, alignment: .leading)
            PacerCostBar(breakdown)
            trailing
        }
    }
}

public extension PacerCostBreakdownRow where Trailing == EmptyView {
    init(label: String, breakdown: CostBreakdown, labelWidth: CGFloat = 130) {
        self.init(label: label, breakdown: breakdown, labelWidth: labelWidth) { EmptyView() }
    }
}

/// The cache hit rate as a filled track and a percentage.
/// `ratio` is `TokenBreakdown.cacheHitRatio`, the one definition.
public struct PacerCacheHitRow: View {
    private let ratio: Double

    public init(ratio: Double) {
        self.ratio = ratio
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .foregroundStyle(.tint)
                .font(.system(size: 13))
            Text("Cache hit rate")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 6)
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * min(max(ratio, 0), 1), height: 6)
                }
                .frame(height: 6)
            }
            .frame(maxWidth: 220)
            Text(pacerCacheHitText(ratio))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 56, alignment: .trailing)
        }
        .help("Prompt tokens served from cache")
    }
}

/// "96.8%" — the cache hit rate at the precision every surface shows it.
public func pacerCacheHitText(_ ratio: Double) -> String {
    String(format: "%.1f%%", ratio * 100)
}

/// The tooltip for a cost bar: each part with its exact dollars and share.
public func pacerCostBreakdownHelp(_ breakdown: CostBreakdown) -> String {
    breakdown.parts
        .map { "\($0.component.label): \(pacerCostExact($0.usd)) (\($0.percentLabel))" }
        .joined(separator: "\n")
}

/// The VoiceOver reading of a cost bar: the parts that contributed, largest
/// first.
func pacerCostBreakdownSpoken(_ breakdown: CostBreakdown) -> String {
    let parts = breakdown.parts.filter { $0.usd > 0 }.sorted { $0.usd > $1.usd }
    guard !parts.isEmpty else { return "no cost" }
    return parts.map { "\($0.component.label) \($0.percentLabel)" }.joined(separator: ", ")
}
