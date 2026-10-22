import SwiftUI
import PacerCore

/// The first card of History and of both detail modals (a day, a project):
/// what the period cost, its tokens in and out, a few counts, the period as
/// a strip of days (or hours), then the shared breakdown. One component, so
/// the three read as one design.
///
/// Round 6. Round 5's cards were eight numbers: a big cost and tokens beside
/// six facts (History: four tiles over four). The owner wanted something
/// more visual. Three takes were rendered on the same data (four tiles each
/// with a small visual; a ring for the active days with sparklines beside the
/// counts; this one). This one won: the strip is the only visual that shows
/// *when* as well as how many — the gaps, the busy weeks, the last few idle
/// days — it reads from a day's 24 hours up to a year, and it replaces three
/// facts (active days, first active, last active) instead of adding one. The
/// tiles squeezed it into a barcode, and a ring can say "22 of 31" but not
/// which 22.
///
/// Layout: the cost and its tokens in and out on the left, the counts on the right,
/// the strip across the card under them (what that cost was per day, or per
/// hour of a day), then a rule and the breakdown.
/// Every number here is printed once on the page: the cards below carry no
/// counts in their headers.
public struct PacerSummaryCard<Trailing: View>: View {
    public typealias Model = PacerSummaryModel

    private let title: String
    private let model: Model
    private let trailing: () -> Trailing

    /// - Parameter trailing: the title row's trailing slot (a project's git
    ///   chip, a day's "no data").
    public init(_ title: String = "Summary", model: Model, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.model = model
        self.trailing = trailing
    }

    public var body: some View {
        let m = model
        PacerCard(title, trailing: trailing) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 24) {
                    headline(m.breakdown)
                    Spacer(minLength: 0)
                    if !m.stats.isEmpty {
                        stats(m.stats)
                    }
                }
                if m.activity.slots > 0 {
                    PacerActivityStrip(m.activity, span: m.span, axis: m.axis, cellHelp: m.cellHelp)
                }
                if PacerCostBreakdownView.hasContent(m.breakdown) {
                    // A rule between the strip and the breakdown's bar: two
                    // rows of colour, and without it they read as one chart.
                    Divider()
                    PacerCostBreakdownView(m.breakdown)
                }
            }
        }
    }

    /// The big figure, and under it the tokens as they split: in (the
    /// prompt — cache reads, cache writes and uncached input) and out.
    /// Never truncated or squeezed: the counts beside it give way first.
    ///
    /// One line, not a total over an in/out line: input is ~99.8% of a real
    /// store's tokens, so "21.9B tokens" over "21.9B in" printed the same
    /// number twice. The total is in the tooltip.
    private func headline(_ b: CostBreakdown) -> some View {
        let cost: Double = b.total
        return VStack(alignment: .leading, spacing: 4) {
            Text(pacerCost(cost))
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .help(pacerCostExact(cost))
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(pacerTokens(b.tokens.promptTokens))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(" tokens in")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("  ·  ")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                Text(pacerTokens(b.tokens.outputTokens))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(" out")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()
            .lineLimit(1)
            .help(pacerTokenSplitHelp(b.tokens))
            .accessibilityElement(children: .combine)
        }
        .fixedSize()
    }

    /// The counts side by side, each a compact figure over its label.
    private func stats(_ stats: [PacerSummaryFact]) -> some View {
        HStack(alignment: .top, spacing: 22) {
            ForEach(stats) { fact in
                MetricTile(value: fact.value, label: fact.label, size: .compact, tooltip: fact.help)
                    .fixedSize()
            }
        }
    }
}

public extension PacerSummaryCard where Trailing == EmptyView {
    /// With nothing in the title row's trailing slot.
    init(_ title: String = "Summary", model: Model) {
        self.init(title, model: model) { EmptyView() }
    }
}

/// What a `PacerSummaryCard` shows, as plain values. Outside the card's
/// generic type so a screen can build it before it knows what goes in the
/// title row.
public struct PacerSummaryModel: Equatable {
    /// The period's cost by part: its total is the big figure, its
    /// tokens the line under it, and the breakdown below draws it.
    public var breakdown: CostBreakdown
    /// The counts at the right, in reading order.
    public var stats: [PacerSummaryFact]
    /// The period's slots and what each cost: the strip, which captions
    /// itself (`pacerActivityCaption`), so every card says the same thing
    /// about the same picture.
    public var activity: PeriodActivity
    /// After the active count: when use began and ended
    /// (`pacerActivitySpan`).
    public var span: String?
    public var axis: [PacerActivityStrip.AxisLabel]
    /// Each column's tooltip (`pacerActivityCellHelp`).
    public var cellHelp: [String]

    public init(
        breakdown: CostBreakdown, stats: [PacerSummaryFact], activity: PeriodActivity,
        span: String? = nil,
        axis: [PacerActivityStrip.AxisLabel] = [], cellHelp: [String] = []
    ) {
        self.breakdown = breakdown
        self.stats = stats
        self.activity = activity
        self.span = span
        self.axis = axis
        self.cellHelp = cellHelp
    }
}

/// One labelled count beside a summary card's big figure: "37" over
/// "SESSIONS". Outside the card's generic type so a screen can build its
/// counts before it knows what goes in the title row.
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
