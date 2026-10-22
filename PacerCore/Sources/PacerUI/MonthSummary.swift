import SwiftUI
import PacerCore

/// The month so far, under the dashboard's 30-day chart: cost, tokens, active
/// days and the month-end projection as point tiles, the spent → projected
/// bar under the projection, then the shared breakdown — what "This week" is
/// for its seven days.
///
/// A section of a card, not a card. It opens with a quiet eyebrow ("THIS
/// MONTH  October · 9 days left") rather than a second bold title, so the
/// card it sits in reads as one card with one title.
///
/// Every tile is always drawn, from the 1st on. On the 1st the month's
/// numbers are today's, and in its first week they are this week's; the
/// owner chose a section that looks the same every day over hiding them.
///
/// The bar sits in the projection's column, where the active-days tile has
/// its hint, and fills by spent over projected. It has no labels of its own:
/// both numbers are tiles in the same row. Card-wide, it sat right above the
/// breakdown's bar and read as a second bar of the same thing.
public struct PacerMonthSummary: View {
    /// What the section shows, as plain values.
    public struct Model: Equatable, Sendable {
        /// "October"
        public var name: String
        public var daysLeft: Int
        /// The month so far, by priced part; its total is the cost tile.
        public var breakdown: CostBreakdown
        public var activeDays: Int
        public var projection: Projection

        public init(
            name: String, daysLeft: Int, breakdown: CostBreakdown,
            activeDays: Int, projection: Projection
        ) {
            self.name = name
            self.daysLeft = daysLeft
            self.breakdown = breakdown
            self.activeDays = activeDays
            self.projection = projection
        }

        public var cost: Double { breakdown.total }
        public var tokens: Int64 { breakdown.tokens.all }
        public var averageActiveDayCost: Double {
            activeDays > 0 ? cost / Double(activeDays) : 0
        }
    }

    /// The month-end projection, already formatted by the caller (it owns the
    /// engine and its wording).
    public enum Projection: Equatable, Sendable {
        /// No answer yet: "—", and the bar's room is held so the section
        /// does not grow when the answer lands.
        case pending
        /// Not enough of the month to project: "—", with why in the tooltip.
        case unavailable(help: String)
        /// "≈$6.1k" for `usd`, never below what the month has spent.
        case estimate(usd: Double, label: String, help: String)
    }

    private let model: Model

    public init(_ model: Model) {
        self.model = model
    }

    public var body: some View {
        let m = model
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Eyebrow(text: "This month")
                Text("\(m.name) · \(m.daysLeft) day\(m.daysLeft == 1 ? "" : "s") left")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            tiles(m)
            if PacerCostBreakdownView.hasContent(m.breakdown) {
                PacerCostBreakdownView(m.breakdown)
                    .padding(.top, 6)
            }
        }
    }

    private func tiles(_ m: Model) -> some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 16, alignment: .topLeading),
                count: 4
            ),
            alignment: .leading,
            spacing: 12
        ) {
            MetricTile(value: pacerCost(m.cost), label: "cost", tooltip: pacerCostExact(m.cost))
            MetricTile(value: pacerTokens(m.tokens), label: "tokens", tooltip: pacerTokensExact(m.tokens))
            MetricTile(
                value: "\(m.activeDays)",
                label: "active days",
                hint: m.activeDays > 0 ? "avg \(pacerCost(m.averageActiveDayCost)) each" : nil,
                tooltip: m.activeDays > 0
                    ? "\(pacerCostExact(m.averageActiveDayCost)) per active day" : nil
            )
            // Always drawn, "—" until there is an answer: a tile that
            // appeared seconds after the card would grow it.
            VStack(alignment: .leading, spacing: 7) {
                switch m.projection {
                case .pending:
                    MetricTile(value: "—", label: "by month end")
                case .unavailable(let help):
                    MetricTile(value: "—", label: "by month end", tooltip: help)
                case .estimate(_, let label, let help):
                    MetricTile(value: label, label: "by month end", tooltip: help)
                }
                bar(m)
            }
        }
    }

    /// The spent → projected bar. Its room is always there, the bar drawn only
    /// once there is a projection to fill towards, so the section is the same
    /// height before and after the engine answers.
    private func bar(_ m: Model) -> some View {
        let projected: Double? = {
            if case .estimate(let usd, _, _) = m.projection { return max(usd, m.cost) }
            return nil
        }()
        let help: String? = projected.map {
            "\(pacerCostExact(m.cost)) spent of \(pacerCostExact($0)) by month end"
        }
        return SpendProgressTrack(spent: m.cost, projected: projected ?? 1)
            .opacity(projected == nil ? 0 : 1)
            .allowsHitTesting(projected != nil)
            .accessibilityHidden(projected == nil)
            .modifier(OptionalHelp(text: help))
    }
}
