import SwiftUI
import PacerCore

/// The dashboard's "This month" card: the month so far as one big figure
/// with the month-end projection beside it, its tokens and active days, the
/// labelled spent → projected bar across the card, then the shared
/// breakdown.
///
/// Its own card again, under "Last 30 days" rather than inside it: the month
/// and the last 30 days are different periods, and the owner chose the
/// original's roomy layout — the card-wide labelled bar especially — over
/// round 3's tiles with the bar squeezed into a column.
///
/// Every number is always drawn, from the 1st on: on the 1st before any use
/// the card reads $0, 0 tokens and 0 active days rather than going blank,
/// and the projection reads "—" until the engine has an answer. The bar's
/// room is held until there is a projection to fill towards, so the card is
/// the same height before and after the engine answers.
///
/// The bar's two labels repeat the big figure and the projection. That one
/// repeat is the owner's call: he asked for the labelled bar back.
public struct PacerMonthSummary: View {
    /// What the card shows, as plain values.
    public struct Model: Equatable, Sendable {
        /// "October"
        public var name: String
        public var daysLeft: Int
        /// The month so far, by priced part; its total is the big figure.
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
        /// No answer yet: "—", and the bar's room is held so the card does
        /// not grow when the answer lands.
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
        PacerCard("This month", trailing: {
            Text("\(m.name) · \(m.daysLeft) day\(m.daysLeft == 1 ? "" : "s") left")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(pacerCost(m.cost))
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .help(pacerCostExact(m.cost))
                    projectionChip(m.projection)
                    Spacer(minLength: 8)
                    detail(m)
                }
                bar(m)
                if PacerCostBreakdownView.hasContent(m.breakdown) {
                    // A rule between the two bars: the spend bar is the month
                    // against its projection, the breakdown's is the month's
                    // mix, and without it they read as one bar of two parts.
                    Divider()
                        .padding(.vertical, 6)
                    PacerCostBreakdownView(m.breakdown)
                }
            }
        }
    }

    /// "≈$774 by month end"; "— by month end" until there is an answer, so
    /// the chip is there from the first frame and nothing beside it moves.
    private func projectionChip(_ p: Projection) -> some View {
        let text: String
        let help: String?
        switch p {
        case .pending:
            text = "— by month end"
            help = nil
        case .unavailable(let why):
            text = "— by month end"
            help = why
        case .estimate(_, let label, let why):
            text = "\(label) by month end"
            help = why
        }
        return Chip(
            text: text,
            systemImage: "chart.line.uptrend.xyaxis",
            tint: .secondary,
            size: .compact
        )
        .fixedSize()
        .modifier(OptionalHelp(text: help))
    }

    /// "1.1B tokens · avg $25.0 per active day (22)": the month's other
    /// numbers, quiet, on the big figure's line.
    private func detail(_ m: Model) -> some View {
        HStack(spacing: 0) {
            Text("\(pacerTokens(m.tokens)) tokens")
                .help("\(pacerTokensExact(m.tokens)) tokens")
            Text(" · ")
            if m.activeDays > 0 {
                Text("avg \(pacerCost(m.averageActiveDayCost)) per active day (\(m.activeDays))")
                    .help("\(pacerCostExact(m.averageActiveDayCost)) per active day, \(m.activeDays) active day\(m.activeDays == 1 ? "" : "s")")
            } else {
                Text("0 active days")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
    }

    /// The labelled spent → projected bar across the card. Its room is always
    /// there, the bar drawn only once there is a projection to fill towards:
    /// held open, not left out, because the engine's first answer lands
    /// seconds after the card draws, and a bar arriving then grew the card
    /// and moved everything under it.
    private func bar(_ m: Model) -> some View {
        var estimate: (usd: Double, label: String, help: String)?
        if case .estimate(let usd, let label, let help) = m.projection {
            estimate = (max(usd, m.cost), label, help)
        }
        let shown: Bool = estimate != nil
        return SpendProgressBar(
            spent: m.cost,
            projected: estimate?.usd ?? 1,
            projectedLabel: estimate?.label ?? " ",
            help: estimate?.help ?? "")
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
    }
}
