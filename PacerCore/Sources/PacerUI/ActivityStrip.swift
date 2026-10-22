import SwiftUI
import PacerCore

/// A period drawn as a row of columns, one per day (per hour of a day; per
/// week of a long period), under a line that says how many were active and,
/// at its right, what a column's height is: the summary card's picture of
/// "22 of 30 days" and where the money went across them.
///
/// One encoding, the same on every card: a column's height is what the
/// period cost there per slot, against the period's most expensive slot —
/// cost per day on History and a project, cost per hour on a day
/// (`PeriodActivity`). The caption says which (`pacerActivityCaption`), and
/// each column's tooltip has its day or hour and the exact cost. Every slot
/// has a faint track behind it, so the period's length reads at a glance and
/// an idle day is a gap in the row, not a missing column.
///
/// The columns always share the strip's whole width. Round 6 capped a column
/// at 24 pt, so a week drew eight narrow columns across the left third of
/// the card and left the rest empty; the owner wanted the strip to use the
/// width for every period.
///
/// Green, the heatmap's activity colour, so History's two pictures of when
/// you worked read as one.
public struct PacerActivityStrip: View {
    /// A label under the strip, at a cell's leading edge (the last cell's
    /// trailing edge for a label on the last cell).
    public struct AxisLabel: Equatable, Sendable {
        public let cell: Int
        public let text: String

        public init(cell: Int, text: String) {
            self.cell = cell
            self.text = text
        }
    }

    private let activity: PeriodActivity
    private let span: String?
    private let axis: [AxisLabel]
    private let cellHelp: [String]
    private let height: CGFloat

    private static let headerHeight: CGFloat = 15
    private static let axisHeight: CGFloat = 12

    /// - Parameters:
    ///   - span: after the count, quieter: when the period's use began and
    ///     ended, where that is not already an end of the axis.
    ///   - axis: labels under the strip (`pacerDayAxis`, `pacerHourAxis`).
    ///   - cellHelp: each cell's tooltip, in cell order
    ///     (`pacerActivityCellHelp`).
    public init(
        _ activity: PeriodActivity, span: String? = nil,
        axis: [AxisLabel] = [], cellHelp: [String] = [], height: CGFloat = 34
    ) {
        self.activity = activity
        self.span = span
        self.axis = axis
        self.cellHelp = cellHelp
        self.height = height
    }

    private var totalHeight: CGFloat {
        let axisRoom: CGFloat = axis.isEmpty ? 0 : 4 + Self.axisHeight
        return Self.headerHeight + 6 + height + axisRoom
    }

    public var body: some View {
        let cells: [PeriodActivity.Cell] = activity.cells
        let fills: [CGFloat] = PacerActivityStripLayout.fills(activity)
        let caption: String = pacerActivityCaption(activity)
        GeometryReader { geo in
            let width: CGFloat = geo.size.width
            let layout = PacerActivityStripLayout(count: cells.count, width: width)
            VStack(alignment: .leading, spacing: 0) {
                header(caption: caption)
                    .frame(width: width, height: Self.headerHeight, alignment: .leading)
                HStack(alignment: .bottom, spacing: layout.gap) {
                    ForEach(Array(cells.enumerated()), id: \.element.id) { i, _ in
                        column(fill: fills[i], width: layout.cell)
                            .modifier(OptionalHelp(text: i < cellHelp.count ? cellHelp[i] : nil))
                    }
                }
                .frame(height: height)
                .padding(.top, 6)
                if !axis.isEmpty {
                    axisRow(layout)
                        .padding(.top, 4)
                }
            }
        }
        .frame(height: totalHeight)
    }

    /// "22 of 30 days active · Sep 23 – Oct 21", and at the right what a
    /// column's height is.
    private func header(caption: String) -> some View {
        let main = HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(activity.active)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            Text("of \(activity.slots) \(pacerSlotNoun(activity)) active")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if let span {
                Text("·")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                Text(span)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            main
            Spacer(minLength: 8)
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    /// A slot's track, and its fill from the bottom: `fill` of the strip's
    /// height. A fill too short to see is drawn at a few points, so an active
    /// day is never mistaken for an idle one.
    private func column(fill: CGFloat, width: CGFloat) -> some View {
        let radius: CGFloat = min(2, width / 2)
        let full: CGFloat = height
        let minimum: CGFloat = min(full, 3)
        let filled: CGFloat = fill > 0 ? max(minimum, full * fill) : 0
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.primary.opacity(0.06))
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.green.opacity(0.85))
                .frame(height: filled)
        }
        .frame(width: width, height: full)
    }

    /// The labels at their cells: one on the last cell ends at the strip's
    /// end, every other one starts at its own cell.
    private func axisRow(_ layout: PacerActivityStripLayout) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(axis, id: \.cell) { label in
                let x: CGFloat = layout.x(of: label.cell)
                if label.cell >= layout.count - 1 && layout.count > 1 {
                    axisText(label.text)
                        .frame(width: x + layout.cell, alignment: .trailing)
                } else {
                    axisText(label.text)
                        .offset(x: x)
                }
            }
        }
        .frame(height: Self.axisHeight, alignment: .topLeading)
    }

    private func axisText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
    }
}

/// Where a strip's cells go: each cell's width and the gap between them,
/// for `count` cells across `width`. The cells always fill the width. Pure,
/// so the sizing is tested without drawing.
struct PacerActivityStripLayout: Equatable {
    let cell: CGFloat
    let gap: CGFloat
    let count: Int

    init(count: Int, width: CGFloat) {
        self.count = count
        let n: CGFloat = CGFloat(max(1, count))
        let room: CGFloat = max(0, width)
        let gap: CGFloat = Self.gap(pitch: room / n)
        self.gap = gap
        self.cell = max(1, (room - gap * (n - 1)) / n)
    }

    /// The gap for cells `pitch` apart: in step with the cells, so a week's
    /// wide columns read as seven days rather than one slab, and a 90-day
    /// strip at modal width keeps most of each slot for its column.
    static func gap(pitch: CGFloat) -> CGFloat {
        if pitch >= 40 { return 4 }
        if pitch >= 14 { return 3 }
        if pitch >= 7 { return 2 }
        return 1
    }

    /// The x of cell `i`'s leading edge.
    func x(of i: Int) -> CGFloat {
        CGFloat(max(0, i)) * (cell + gap)
    }

    /// The width the cells take: the strip's, but for rounding.
    var used: CGFloat {
        let n: CGFloat = CGFloat(max(0, count))
        return max(0, n * cell + max(0, n - 1) * gap)
    }

    /// Each cell's fill, 0...1: its cost per slot against the period's
    /// highest. An active cell that cost nothing (every model unpriced) is a
    /// stub, so it still reads as used; an idle one is empty.
    static func fills(_ activity: PeriodActivity) -> [CGFloat] {
        let cells: [PeriodActivity.Cell] = activity.cells
        let peak: Double = cells.map(\.costPerSlot).max() ?? 0
        return cells.map { c -> CGFloat in
            guard c.active > 0 else { return 0 }
            guard peak > 0, c.costPerSlot > 0 else { return 0.001 }
            return CGFloat(c.costPerSlot / peak)
        }
    }
}

// MARK: - Labels

/// "days", "hours"; singular for a period of one.
public func pacerSlotNoun(_ activity: PeriodActivity) -> String {
    let one: Bool = activity.slots == 1
    switch activity.unit {
    case .day: return one ? "day" : "days"
    case .hour: return one ? "hour" : "hours"
    }
}

/// A day strip's axis: the period's first day under the first cell and
/// "Today" under the last. A strip too short for two labels (under a week)
/// gets one, "Oct 21 – Today", under its start; a one-day period, "Today".
///
/// - Parameters:
///   - today: today's key; a period ending on another day ends on its date.
///   - currentYear: the year a date is printed without.
public func pacerDayAxis(
    _ activity: PeriodActivity, today: String, currentYear: Int
) -> [PacerActivityStrip.AxisLabel] {
    guard activity.unit == .day, let start = activity.start, let end = activity.end else { return [] }
    let last: Int = activity.cells.count - 1
    let endText: String = end == today ? "Today" : pacerFactDay(end, currentYear: currentYear)
    guard last > 0 else { return [.init(cell: 0, text: endText)] }
    let startText: String = pacerFactDay(start, currentYear: currentYear)
    if activity.cells.count < 7 {
        return [.init(cell: 0, text: "\(startText) – \(endText)")]
    }
    return [.init(cell: 0, text: startText), .init(cell: last, text: endText)]
}

/// A day's hours: midnight, 6, noon and 6, under their cells.
public func pacerHourAxis() -> [PacerActivityStrip.AxisLabel] {
    [0, 6, 12, 18].map { h in .init(cell: h, text: pacerHourLabel(h)) }
}

/// "9 AM" (or "09:00") for an hour of the day, 0–23.
public func pacerHourLabel(_ hour: Int) -> String {
    // Any day without a clock change does; this one is fixed so the label
    // never depends on today's.
    let day = Date(timeIntervalSinceReferenceDate: 864_000)
    let date: Date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
    return pacerHour(date, style: .regular)
}

/// When the period's use began and ended, leaving out an end the axis
/// already prints: "Sep 23 – Oct 21"; "last active Oct 21" when use began on
/// the period's first day; "first active Sep 23" when it runs to its last;
/// nil when it spans the whole period, or there was none.
///
/// An hour strip's axis does not label its ends, so a day's span always
/// prints both hours ("9 AM – 11 PM").
public func pacerActivitySpan(_ activity: PeriodActivity, format: (String) -> String) -> String? {
    guard let first = activity.firstActive, let last = activity.lastActive else { return nil }
    if activity.unit == .hour {
        return first == last ? format(first) : "\(format(first)) – \(format(last))"
    }
    let fromStart: Bool = first == activity.start
    let toEnd: Bool = last == activity.end
    switch (fromStart, toEnd) {
    case (true, true): return nil
    case (true, false): return "last active \(format(last))"
    case (false, true): return "first active \(format(first))"
    case (false, false): return first == last ? format(first) : "\(format(first)) – \(format(last))"
    }
}

/// What a column's height is, for the strip's caption: "cost per hour",
/// "cost per day", and for a strip of weeks "cost per day, by week" (a
/// week's column is its days' mean, so it reads on a day's scale).
public func pacerActivityCaption(_ activity: PeriodActivity) -> String {
    switch activity.unit {
    case .hour:
        return "cost per hour"
    case .day:
        let weeks: Int = activity.slotsPerCell / 7
        guard activity.slotsPerCell > 1 else { return "cost per day" }
        return weeks <= 1 ? "cost per day, by week" : "cost per day, by \(weeks) weeks"
    }
}

/// Each cell's tooltip: its hour, day or week and the exact cost the column
/// draws. A week's says its cost a day (the height), its total, and how many
/// of its days were active. Tooltips may repeat a number the page prints.
public func pacerActivityCellHelp(_ activity: PeriodActivity, currentYear: Int) -> [String] {
    activity.cells.map { cell -> String in
        let name: String
        switch activity.unit {
        case .hour:
            let hour: Int = Int(cell.first) ?? 0
            name = "\(pacerHourLabel(hour)) – \(pacerHourLabel((hour + 1) % 24))"
        case .day:
            guard cell.span == 1 else {
                let from: String = pacerFactDay(cell.first, currentYear: currentYear)
                let to: String = pacerFactDay(cell.last, currentYear: currentYear)
                guard cell.active > 0 else { return "\(from) – \(to) · no use" }
                let perDay: String = pacerCostExact(cell.costPerSlot)
                let total: String = pacerCostExact(cell.cost)
                return "\(from) – \(to) · \(perDay) a day, \(total) in all · \(cell.active) of \(cell.span) days active"
            }
            name = pacerFactDayExact(cell.first)
        }
        guard cell.active > 0 else { return "\(name) · no use" }
        return "\(name) · \(pacerCostExact(cell.cost))"
    }
}

// MARK: - Tokens in and out

/// The summary card's token line's tooltip: the total, and each side exact.
func pacerTokenSplitHelp(_ tokens: TokenBreakdown) -> String {
    "\(pacerTokensExact(tokens.all)) tokens\n"
        + "\(pacerTokensExact(tokens.promptTokens)) in: cache reads, cache writes and uncached input\n"
        + "\(pacerTokensExact(tokens.outputTokens)) out: the responses, thinking included"
}
