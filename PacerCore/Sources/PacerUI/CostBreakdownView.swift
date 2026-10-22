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
///
/// Every gap between two parts is the same width. Round 4 put a wider break
/// between the prompt's four parts and output, with "Input" and "Output"
/// headings over the legend; the legend's columns are equal and the bar's
/// segments are proportional, so the headings and the break never landed in
/// the same place, and the owner had both taken out.
public struct PacerCostBar: View {
    private let breakdown: CostBreakdown
    private let height: CGFloat

    public init(_ breakdown: CostBreakdown, height: CGFloat = 8) {
        self.breakdown = breakdown
        self.height = height
    }

    /// The gap between two parts, for a bar `height` tall: 3 pt on the
    /// breakdown's 10 pt bar, in proportion on the thinner ones (the tables'
    /// 6 pt Mix bar would lose a sixth of its width to fixed 3 pt gaps).
    ///
    /// Neighbouring parts never meet colour to colour: the card shows through
    /// between them, so two hues a colour-blind reader sees as close still
    /// have an edge. Round 3's 2 pt was a hairline next to colours that
    /// close; 3 pt reads as a gap.
    nonisolated static func gap(height: CGFloat) -> CGFloat {
        height * 3 / 10
    }

    public var body: some View {
        let parts = breakdown.parts
        let shown = parts.filter { $0.share > 0 }.count
        // The bar's corner radius is also the narrowest part worth a gap: a
        // part thinner than the rounding sits inside the curve of the end.
        let radius: CGFloat = height / 2
        let gap: CGFloat = Self.gap(height: height)
        GeometryReader { geo in
            let layout = PacerCostBarLayout(
                shares: parts.map(\.share), width: geo.size.width, gap: gap, sliver: radius)
            HStack(spacing: 0) {
                // Every part gets a segment, zero-width when it is $0, so the
                // row's identity does not change as a part comes and goes.
                ForEach(Array(parts.enumerated()), id: \.element.id) { i, part in
                    let segment: PacerCostBarLayout.Segment = layout.segments[i]
                    Rectangle()
                        .fill(part.component.color)
                        .frame(width: segment.width)
                        .padding(.trailing, segment.trailingGap)
                }
            }
        }
        .frame(height: height)
        // The track only shows when there is nothing to draw; behind parts it
        // would fill the gaps and undo them.
        .background(shown == 0 ? Color.primary.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: height / 2))
        .help(pacerCostBreakdownHelp(breakdown))
        .accessibilityElement()
        .accessibilityLabel("Cost by part")
        .accessibilityValue(pacerCostBreakdownSpoken(breakdown))
    }
}

/// Which boundaries between the parts of one stacked bar get a gap — the one
/// rule `PacerCostBar` and the stacked chart both follow. Every gap is the
/// same width, and every two readable parts (at least `sliver`) have one
/// between them.
///
/// A sliver never gets a gap of its own (round 3's rule). Gapping it drew a
/// hairline of colour between two gaps, and at the bar's end that hairline
/// was all that filled the rounded corner, so the end looked cut off rather
/// than round. So a sliver rides flush on the part before it, and the gap
/// that part would have had moves past the sliver, to the next readable
/// part; at the front of a bar, where nothing comes before it, it rides on
/// the part after it. It is never between two gaps and never alone in a
/// rounded end.
///
/// Riding on a neighbour, rather than flush on both sides as round 3 had it,
/// matters because of where the usual sliver sits: uncached input is a
/// twentieth of a point on most bars, between the 5m writes and output.
/// Flush both ways, those two met colour to colour on nearly every bar, one
/// missing gap in an otherwise even row.
enum PacerPartGaps {
    /// - Parameters:
    ///   - values: each part's size in the bar's own unit (points across a
    ///     bar, dollars up a chart), in drawing order; 0 for a part that is
    ///     not drawn, which is skipped when finding a part's neighbour.
    /// - Returns: the gap after each part, 0 after the last drawn one.
    static func trailing(_ values: [Double], gap: Double, sliver: Double) -> [Double] {
        let shown: [Int] = values.indices.filter { values[$0] > 0 }
        var trailing: [Double] = Array(repeating: 0, count: values.count)
        // Whether a readable part has been drawn yet: slivers before the
        // first one ride on it, so no gap goes in until there is one.
        var readableSoFar: Bool = false
        for (a, b) in zip(shown, shown.dropFirst()) {
            if values[a] >= sliver { readableSoFar = true }
            // A gap only ever goes in front of a readable part, so a sliver
            // never has one before it.
            if readableSoFar && values[b] >= sliver { trailing[a] = gap }
        }
        return trailing
    }
}

/// Where each part of a `PacerCostBar` goes: its width, and the gap after it.
/// Pure, so where the gaps fall is tested without drawing a bar. The gaps
/// follow `PacerPartGaps`; the parts share what is left, each in proportion
/// to its share, so the bar still reads the true mix.
struct PacerCostBarLayout: Equatable {
    struct Segment: Equatable {
        let width: CGFloat
        /// The gap after this part: the bar's gap between two readable
        /// parts, 0 beside a sliver, after the last part, or for a $0 part.
        let trailingGap: CGFloat
    }

    let segments: [Segment]

    /// - Parameters:
    ///   - shares: every part's share of the cost in bar order, 0 for a part
    ///     with nothing (it keeps a zero-width segment).
    ///   - width: the bar's width.
    ///   - gap: the gap between two readable parts.
    ///   - sliver: the narrowest a part can be and still get a gap. Judged at
    ///     the bar's full width, before the gaps are taken out, so whether a
    ///     part is a sliver does not depend on how many gaps there are.
    init(shares: [Double], width: CGFloat, gap: CGFloat, sliver: CGFloat) {
        let full: CGFloat = max(0, width)
        let points: [Double] = shares.map { Double(full) * max(0, $0) }
        let trailing: [Double] = PacerPartGaps.trailing(points, gap: Double(gap), sliver: Double(sliver))
        let taken: Double = trailing.reduce(0, +)
        let room: CGFloat = max(0, full - CGFloat(taken))
        segments = shares.indices.map { i -> Segment in
            let share: CGFloat = CGFloat(max(0, shares[i]))
            return Segment(width: room * share, trailingGap: CGFloat(trailing[i]))
        }
    }
}

/// How much room a `PacerCostBreakdownView` has.
public enum PacerCostBreakdownStyle: Sendable, Equatable {
    /// A card's width: the stacked bar, then the five parts side by side in
    /// equal columns, each with its dollars, share and tokens.
    case regular
    /// A hover card (~280 pt): the five parts as rows, one line each — dot,
    /// name, dollars, share, tokens under one-word headings — and no bar. A
    /// compact breakdown sits beside a chart that already draws the mix, and
    /// the share column says what a 250 pt bar would.
    case compact
}

/// The breakdown for one total: the stacked bar, the five parts with their
/// dollars, share and tokens, and the cache hit rate as one quiet line of
/// text under them.
///
/// One line, not two: tokens are ~98% cache reads, so a token bar would be a
/// single colour. Each part's token count rides in its legend entry instead,
/// read through `TokenBreakdown[_:]`.
///
/// It does not print the total itself — every screen that shows it already
/// has the total in its summary, and the parts are what this adds. With no
/// cost to split (every model unpriced) it is only the hit rate: five $0
/// parts would say nothing.
public struct PacerCostBreakdownView: View {
    private let breakdown: CostBreakdown
    private let style: PacerCostBreakdownStyle

    public init(_ breakdown: CostBreakdown, style: PacerCostBreakdownStyle = .regular) {
        self.breakdown = breakdown
        self.style = style
    }

    /// Whether there is anything to show — callers hide the card otherwise.
    public static func hasContent(_ breakdown: CostBreakdown) -> Bool {
        breakdown.total > 0 || breakdown.cacheHitRatio != nil
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: style == .compact ? 8 : 10) {
            if breakdown.total > 0 {
                switch style {
                case .regular:
                    PacerCostBar(breakdown, height: 10)
                        // The bar-to-legend gap the stack had before the hit
                        // rate became a line of text and the stack tightened.
                        .padding(.bottom, 2)
                    RegularLegend(parts: breakdown.parts)
                case .compact:
                    CompactLegend(parts: breakdown.parts)
                }
            }
            if let ratio = breakdown.cacheHitRatio {
                PacerCacheHitLine(ratio: ratio)
            }
        }
    }

    /// The five parts in equal columns, in bar order.
    ///
    /// No heading over them: the columns are equal and the bar's segments
    /// are proportional, so nothing written over a run of columns can sit
    /// over the part of the bar it names (round 4's "Input" and "Output"
    /// headings did not, and came out in round 5).
    ///
    /// Each share reads "56% of cost" where every column has room for it,
    /// and "56%" where one does not (a Day detail modal). The choice is the
    /// legend's, not each cell's, so the five never disagree.
    private struct RegularLegend: View {
        let parts: [CostBreakdown.Part]

        var body: some View {
            ViewThatFits(in: .horizontal) {
                columns(ofCost: true)
                columns(ofCost: false)
            }
        }

        private func columns(ofCost: Bool) -> some View {
            PacerEqualColumns(columns: parts.count, spacing: 12) {
                ForEach(parts) { part in
                    PartCell(part: part, ofCost: ofCost)
                }
            }
        }
    }

    private struct PartCell: View {
        let part: CostBreakdown.Part
        let ofCost: Bool

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
                VStack(alignment: .leading, spacing: 1) {
                    // "of cost": the share is of the dollars, and the tokens
                    // under it are a different story (reads are ~98% of the
                    // tokens and well under that of the cost).
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(pacerCost(part.usd))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text(ofCost ? "\(part.percentLabel) of cost" : part.percentLabel)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(pacerPartTokens(part.tokens))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        PriceMultipleTag(part: part.component)
                    }
                    .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .padding(.leading, 13)
            }
            // A $0 part stays in its column, quieter, rather than leaving a
            // gap that would shift the others between days.
            .opacity(part.isQuiet ? 0.45 : 1)
            .help(pacerPartHelp(part))
        }
    }

    /// The five parts as rows under "of cost" and "tokens" headings.
    private struct CompactLegend: View {
        let parts: [CostBreakdown.Part]

        var body: some View {
            Grid(alignment: .leading, horizontalSpacing: PacerCompactColumns.spacing, verticalSpacing: 4) {
                // Each heading once, over its column, rather than on every
                // row: five "21.5B tokens" cost the 37 pt that kept
                // "5m cache writes" from truncating at hover-card width.
                GridRow {
                    Color.clear
                        .gridCellUnsizedAxes([.horizontal, .vertical])
                        .gridCellColumns(2)
                    Heading(text: "of cost")
                        .pacerCompactColumn(PacerCompactColumns.share)
                    Heading(text: "tokens")
                        .pacerCompactColumn(PacerCompactColumns.tokens)
                }
                ForEach(parts) { part in
                    PartRow(part: part)
                }
            }
        }
    }

    private struct Heading: View {
        let text: String

        var body: some View {
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    /// One compact row. The quiet/tooltip treatment goes on each cell, not
    /// on the `GridRow`: a modified `GridRow` is no longer a row to `Grid`,
    /// and its cells would stop lining up in columns.
    private struct PartRow: View {
        let part: CostBreakdown.Part

        var body: some View {
            GridRow {
                HStack(spacing: 4) {
                    Circle()
                        .fill(part.component.color)
                        .frame(width: 7, height: 7)
                    Text(part.component.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(PartCellStyle(part: part))
                // The numbers never truncate; if anything gives, the name does.
                .layoutPriority(-1)
                Text(pacerCost(part.usd))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .pacerCompactColumn(PacerCompactColumns.cost)
                    .modifier(PartCellStyle(part: part))
                Text(part.percentLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .pacerCompactColumn(PacerCompactColumns.share)
                    .modifier(PartCellStyle(part: part))
                Text(pacerTokens(part.tokens))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .pacerCompactColumn(PacerCompactColumns.tokens)
                    .modifier(PartCellStyle(part: part))
            }
        }
    }

    private struct PartCellStyle: ViewModifier {
        let part: CostBreakdown.Part

        func body(content: Content) -> some View {
            content
                .monospacedDigit()
                .lineLimit(1)
                .opacity(part.isQuiet ? 0.45 : 1)
                .help(pacerPartHelp(part))
        }
    }
}

/// Children in equal-width columns, left to right on one row.
///
/// Not a `Grid`: a grid's ideal width is the sum of its columns' widest
/// cells, but laid out these columns are equal, so the widest cell of all
/// decides whether the content fits. This reports that as its ideal width
/// (the widest child times the columns), so a `ViewThatFits` around it
/// chooses exactly.
struct PacerEqualColumns: Layout {
    let columns: Int
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width: CGFloat = proposal.width ?? idealWidth(subviews)
        let column: CGFloat = columnWidth(width)
        let height: CGFloat = subviews.map { child -> CGFloat in
            child.sizeThatFits(ProposedViewSize(width: column, height: nil)).height
        }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let column: CGFloat = columnWidth(bounds.width)
        for (i, child) in subviews.enumerated() {
            let x: CGFloat = bounds.minX + CGFloat(i) * (column + spacing)
            child.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                        proposal: ProposedViewSize(width: column, height: nil))
        }
    }

    private func columnWidth(_ width: CGFloat) -> CGFloat {
        let n: CGFloat = CGFloat(max(1, columns))
        let gaps: CGFloat = spacing * (n - 1)
        return max(0, (width - gaps) / n)
    }

    /// The widest any child needs its column to be, times the columns.
    private func idealWidth(_ subviews: Subviews) -> CGFloat {
        let widest: CGFloat = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let n: CGFloat = CGFloat(max(1, columns))
        return widest * n + spacing * (n - 1)
    }
}

private extension CostBreakdown.Part {
    /// Nothing to say: no dollars and no tokens. A part an unpriced model
    /// filled has tokens but $0, and stays at full strength.
    var isQuiet: Bool { usd <= 0 && tokens == 0 }
}

/// "21.5B tokens" — a part's tokens in its legend entry.
func pacerPartTokens(_ tokens: Int64) -> String {
    "\(pacerTokens(tokens)) tokens"
}

/// "Cache reads: $12,603.12 · 21,512,345,678 tokens" — a legend entry's
/// tooltip, exact where the entry is compact.
func pacerPartHelp(_ part: CostBreakdown.Part) -> String {
    "\(part.component.label): \(pacerCostExact(part.usd)) · \(pacerTokensExact(part.tokens)) tokens\n"
        + part.component.billingNote
}

/// "0.1×" after a part's tokens: what each is billed at against the
/// uncached input price, so the four ways a prompt token can be billed read
/// as one scale. The compact rows (hover card) leave it to the tooltip:
/// at ~300pt the tag would cost the part names their last words.
struct PriceMultipleTag: View {
    let part: CostComponent

    var body: some View {
        Text(part.listPriceMultipleLabel)
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .fixedSize()
            .help(part.billingNote)
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

/// The parts' colour key on one line, for a chart stacked by part:
/// "● Cache reads  ● 1h cache writes  ● 5m cache writes  ● Uncached input
/// ● Output", evenly spaced, as the bars' gaps are.
public struct PacerCostKey: View {
    public init() {}

    public var body: some View {
        HStack(spacing: 12) {
            ForEach(CostComponent.allCases, id: \.self) { part in
                HStack(spacing: 4) {
                    Circle()
                        .fill(part.color)
                        .frame(width: 7, height: 7)
                    Text(part.label)
                        .font(.system(size: 11))
                        // `Color.secondary`, not the hierarchical
                        // `.secondary`: a chart's legend sets the tint as
                        // its foreground, and `.secondary` of that is blue.
                        .foregroundStyle(Color.secondary)
                }
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

/// The cache hit rate as one small, secondary line of text — "Cache hits
/// 98.1%" — under every breakdown.
///
/// Kept quiet rather than dropped: a rate that falls on a day of slow turns
/// is how a cache expiring between turns shows up. Text, not a bar: a filled
/// track beside the five-part cost bar was a second bar that read as part of
/// the first. `ratio` is `TokenBreakdown.cacheHitRatio`, the one definition
/// (Claude Code's own `hit_ratio`).
public struct PacerCacheHitLine: View {
    private let ratio: Double

    public init(ratio: Double) {
        self.ratio = ratio
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("Cache hits")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text(pacerCacheHitText(ratio))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .lineLimit(1)
        .help(pacerCacheHitHelp)
        .accessibilityElement(children: .combine)
    }
}

/// The hit rate's tooltip: what it measures, and what a low one means.
let pacerCacheHitHelp = "Cache reads ÷ every prompt token (reads + cache writes + uncached input) · low when the cache expired between turns"

/// The compact breakdown's number columns, shared with the hover card's
/// top-models rows (`PacerCostHoverCard`) so the two grids' dollars, shares
/// and tokens sit in the same columns. A minimum, not a fixed width: a value
/// wider than its column widens it rather than truncating.
enum PacerCompactColumns {
    static let cost: CGFloat = 44
    static let share: CGFloat = 32
    static let tokens: CGFloat = 40
    static let spacing: CGFloat = 6
}

extension View {
    /// A trailing-aligned number cell at least `width` wide.
    func pacerCompactColumn(_ width: CGFloat) -> some View {
        frame(minWidth: width, alignment: .trailing)
            .gridColumnAlignment(.trailing)
    }
}

/// "96.8%" — the cache hit rate at the precision every surface shows it.
///
/// Capped at 99.9% short of every prompt token: rounded to one place, a
/// 99.96% day printed "100.0%", which says the cache missed nothing when it
/// did.
/// "87 / 13": how the cost splits between the prompt (cache reads, cache
/// writes and uncached input) and the output, in whole percent. The one
/// formatter for the "In / Out" table column and the line beside every
/// cache hit rate; nil when nothing was spent.
public func pacerInOutText(_ cost: CostComponents) -> String? {
    guard let out = cost.outputShare else { return nil }
    let outPercent: Int = Int((out * 100).rounded())
    return "\(100 - outPercent) / \(outPercent)"
}

/// The tooltip for an "In / Out" figure.
public let pacerInOutHelp = "Share of the cost: input (cache reads, cache writes and uncached input) / output"

public func pacerCacheHitText(_ ratio: Double) -> String {
    let percent: Double = ratio * 100
    let shown: Double = ratio < 1 ? min(percent, 99.9) : percent
    return String(format: "%.1f%%", shown)
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
