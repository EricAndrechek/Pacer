import SwiftUI
import PacerCore

/// The first card of a detail modal (a day, a project): what the period cost
/// as one big figure with its tokens under it, the screen's facts beside it,
/// then the shared breakdown, all in one card.
///
/// Round 4's modals opened on a Summary card of two or three tiles in a
/// four-column grid, a git chip floating on its own row above it, and the
/// breakdown in a second card under it. The owner found that first card very
/// bare, with a lot of dead space. Here the facts fill the width beside the
/// big figure, a chip goes in the title row's trailing slot, and the
/// breakdown sits under them in the same card, so the card is full.
///
/// A fact is printed here and nowhere else on the modal: the cards below
/// drop the counts they used to carry in their headers ("12 on this day")
/// rather than say them twice.
public struct PacerDetailSummaryCard<Trailing: View>: View {
    public typealias Fact = PacerSummaryFact

    private let title: String
    private let breakdown: CostBreakdown
    private let facts: [Fact]
    private let trailing: () -> Trailing

    /// Facts per row: a modal's six fill two rows beside the big figure,
    /// whose two lines are about as tall.
    static var factsPerRow: Int { 3 }

    /// - Parameters:
    ///   - breakdown: the period's cost by part. Its total is the big figure
    ///     and its tokens the line under it, so the figure and the parts
    ///     below it come from one value and always add up.
    ///   - facts: in reading order, three to a row.
    ///   - trailing: the title row's trailing slot (a project's git chip).
    public init(
        _ title: String = "Summary",
        breakdown: CostBreakdown,
        facts: [Fact],
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.breakdown = breakdown
        self.facts = facts
        self.trailing = trailing
    }

    public var body: some View {
        PacerCard(title, trailing: trailing) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 28) {
                    headline
                    if !facts.isEmpty {
                        factGrid
                    }
                }
                if PacerCostBreakdownView.hasContent(breakdown) {
                    PacerCostBreakdownView(breakdown)
                }
            }
        }
    }

    /// The big figure and its tokens. Never truncated or squeezed: the facts
    /// beside it give way first.
    private var headline: some View {
        let cost: Double = breakdown.total
        let tokens: Int64 = breakdown.tokens.all
        return VStack(alignment: .leading, spacing: 2) {
            Text(pacerCost(cost))
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .help(pacerCostExact(cost))
            Text("\(pacerTokens(tokens)) tokens")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .help("\(pacerTokensExact(tokens)) tokens")
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    /// The facts in rows of `factsPerRow`, each column an equal share of the
    /// width the big figure leaves. A short last row keeps its cells in the
    /// columns above it.
    private var factGrid: some View {
        let perRow: Int = Self.factsPerRow
        let rows: [[Fact]] = stride(from: 0, to: facts.count, by: perRow).map { start in
            Array(facts[start..<min(start + perRow, facts.count)])
        }
        return Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 12) {
            ForEach(rows.indices, id: \.self) { r in
                GridRow {
                    ForEach(rows[r]) { fact in
                        MetricTile(value: fact.value, label: fact.label, size: .compact, tooltip: fact.help)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(rows[r].count..<perRow, id: \.self) { _ in
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .gridCellUnsizedAxes(.vertical)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One labelled number beside a detail modal's big figure: "37" over
/// "SESSIONS". Outside the card's generic type so a screen can build its
/// facts before it knows what goes in the title row.
public struct PacerSummaryFact: Identifiable, Equatable, Sendable {
    public let label: String
    public let value: String
    /// The exact form, where `value` is compact or rounded.
    public let help: String?
    public var id: String { label }

    public init(_ label: String, _ value: String, help: String? = nil) {
        self.label = label
        self.value = value
        self.help = help
    }
}

public extension PacerDetailSummaryCard where Trailing == EmptyView {
    /// With nothing in the title row's trailing slot.
    init(_ title: String = "Summary", breakdown: CostBreakdown, facts: [Fact]) {
        self.init(title, breakdown: breakdown, facts: facts) { EmptyView() }
    }
}

/// `2026-10-02` → "Oct 2", or "Oct 2, 2025" outside `currentYear`: a day as
/// a fact prints it (a project's first and last active day). The raw key on
/// anything that is not a date.
public func pacerFactDay(_ ymd: String, currentYear: Int) -> String {
    guard let date = PacerFactDayFormats.ymd.date(from: ymd) else { return ymd }
    let year: Int = Calendar.current.component(.year, from: date)
    return (year == currentYear ? PacerFactDayFormats.day : PacerFactDayFormats.dayWithYear).string(from: date)
}

/// "Thursday, October 2, 2025": a fact day's tooltip.
public func pacerFactDayExact(_ ymd: String) -> String {
    guard let date = PacerFactDayFormats.ymd.date(from: ymd) else { return ymd }
    return PacerFactDayFormats.full.string(from: date)
}

/// Built once, like `TimeFormatters`' cache: a modal reads them on every
/// refresh.
private enum PacerFactDayFormats {
    static let ymd: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static let day = localized("MMM d")
    static let dayWithYear = localized("MMM d yyyy")
    static let full: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeZone = .current
        return f
    }()

    static func localized(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = .current
        f.timeZone = .current
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }
}
