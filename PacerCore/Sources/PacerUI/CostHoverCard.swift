import SwiftUI
import PacerCore

/// The card a cost chart shows over the hovered bar: the bucket's cost and
/// tokens, what the cost was made of, and its top models.
///
/// A tooltip, so it is exempt from "never print the same number twice": the
/// bar's own label may say the same total. It floats over the chart in an
/// overlay (`PacerStackedPartChart`) and never takes part in layout.
public struct PacerCostHoverCard: View {
    private let title: String
    private let breakdown: CostBreakdown
    private let topModels: [PacerChartModelCost]

    /// The compact breakdown is one row per part, about 217pt wide; this
    /// leaves room for the header line and padding. A narrower chart gets the
    /// chart's width.
    nonisolated public static let idealWidth: CGFloat = 300

    public init(title: String, breakdown: CostBreakdown, topModels: [PacerChartModelCost] = []) {
        self.title = title
        self.breakdown = breakdown
        self.topModels = topModels
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // One line: the charts it floats over are only a little taller
            // than the card, so every row it spends is plot it covers.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(pacerCost(breakdown.total))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("\(pacerTokens(breakdown.tokens.all)) tokens")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 12)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            PacerCostBreakdownView(breakdown, style: .compact)
            if !topModels.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(topModels) { m in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(pacerModelDisplayName(m.model))
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(pacerCost(m.usd))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(PacerDesign.cardBackground)
                // Elevation, because it sits on a card of the same fill: on
                // macOS 26 the window and card backgrounds are one colour, so
                // only the shadow and hairline say it is above the chart.
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}
