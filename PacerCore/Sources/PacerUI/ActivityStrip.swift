import SwiftUI
import PacerCore

/// A period drawn as a row of slim columns, one per day (per hour of a day;
/// per week of a long period), under a line that says how many were active:
/// the summary card's picture of "22 of 31 days".
///
/// One encoding. With a trend (sessions a day) a column's height is that
/// day's sessions against the period's busiest day; without one (a day's
/// hours) it is the share of the cell's slots that were active, which for a
/// cell of one slot is all or nothing. Every slot has a faint track behind
/// it, so the period's length reads at a glance and an idle day is a gap in
/// the row, not a missing column.
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
    private let caption: String?
    private let axis: [AxisLabel]
    private let cellHelp: [String]
    private let height: CGFloat

    /// The widest a cell grows: a day's 24 hours and a 31-day month fill a
    /// modal, and a week stays a row of columns rather than eight slabs.
    nonisolated static let maxCellWidth: CGFloat = 24
    private static let headerHeight: CGFloat = 15
    private static let axisHeight: CGFloat = 12

    /// - Parameters:
    ///   - span: after the count, quieter: when the period's use began and
    ///     ended, where that is not already an end of the axis.
    ///   - caption: what a column's height is ("sessions a day"), at the
    ///     strip's right end; left out when the strip is too short to hold it.
    ///   - axis: labels under the strip (`pacerDayAxis`, `pacerHourAxis`).
    ///   - cellHelp: each cell's tooltip, in cell order.
    public init(
        _ activity: PeriodActivity, span: String? = nil, caption: String? = nil,
        axis: [AxisLabel] = [], cellHelp: [String] = [], height: CGFloat = 34
    ) {
        self.activity = activity
        self.span = span
        self.caption = caption
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
        GeometryReader { geo in
            let width: CGFloat = geo.size.width
            let layout = PacerActivityStripLayout(count: cells.count, width: width, maxCell: Self.maxCellWidth)
            // The caption sits at the strip's end, not the card's: a week's
            // short strip leaves it out rather than floating it far away.
            let fitsCaption: Bool = caption != nil && layout.used >= width * 0.6
            VStack(alignment: .leading, spacing: 0) {
                header(showCaption: fitsCaption)
                    .frame(width: fitsCaption ? layout.used : width, height: Self.headerHeight, alignment: .leading)
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

    /// "22 of 31 days active · Sep 23 – Oct 21", and the caption.
    private func header(showCaption: Bool) -> some View {
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
            if showCaption, let caption {
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
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
/// for `count` cells across `width`. Pure, so the sizing is tested without
/// drawing.
struct PacerActivityStripLayout: Equatable {
    let cell: CGFloat
    let gap: CGFloat
    let count: Int

    init(count: Int, width: CGFloat, maxCell: CGFloat) {
        self.count = count
        let n: CGFloat = CGFloat(max(1, count))
        let room: CGFloat = max(0, width)
        // 2 pt between cells while they are wide enough to keep a gap that
        // size readable; 1 pt for a 90-day strip at modal width.
        let roomy: CGFloat = (room - 2 * (n - 1)) / n
        let gap: CGFloat = roomy >= 5 ? 2 : 1
        let fit: CGFloat = (room - gap * (n - 1)) / n
        self.gap = gap
        self.cell = max(1, min(maxCell, fit))
    }

    /// The x of cell `i`'s leading edge.
    func x(of i: Int) -> CGFloat {
        CGFloat(max(0, i)) * (cell + gap)
    }

    /// The width the cells take: less than the strip's once they hit their
    /// cap.
    var used: CGFloat {
        let n: CGFloat = CGFloat(max(0, count))
        return max(0, n * cell + max(0, n - 1) * gap)
    }

    /// Each cell's fill, 0...1: with a trend, its value against the period's
    /// highest (an active cell with no value yet is a stub); without, the
    /// share of its slots that were active.
    static func fills(_ activity: PeriodActivity) -> [CGFloat] {
        let cells: [PeriodActivity.Cell] = activity.cells
        guard activity.hasTrend else {
            return cells.map { CGFloat($0.activeShare) }
        }
        let peak: Double = cells.map(\.value).max() ?? 0
        return cells.map { c -> CGFloat in
            guard c.active > 0 else { return 0 }
            guard peak > 0, c.value > 0 else { return 0.001 }
            return CGFloat(c.value / peak)
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

/// Each cell's tooltip: its day, week or hour, and what its column's height
/// is (`detail`: "14 sessions", "$12.40") for a cell of one active slot.
/// Tooltips may repeat a number the page prints.
public func pacerActivityCellHelp(
    _ activity: PeriodActivity, currentYear: Int,
    detail: (PeriodActivity.Cell) -> String? = { _ in nil }
) -> [String] {
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
                return "\(from) – \(to) · \(cell.active) of \(cell.span) days active"
            }
            name = pacerFactDayExact(cell.first)
        }
        guard cell.active > 0 else { return "\(name) · no use" }
        guard let more = detail(cell) else { return name }
        return "\(name) · \(more)"
    }
}

// MARK: - Tokens in and out

/// The summary card's token line's tooltip: the total, and each side exact.
func pacerTokenSplitHelp(_ tokens: TokenBreakdown) -> String {
    "\(pacerTokensExact(tokens.all)) tokens\n"
        + "\(pacerTokensExact(tokens.promptTokens)) in: cache reads, cache writes and uncached input\n"
        + "\(pacerTokensExact(tokens.outputTokens)) out: the responses, thinking included"
}
