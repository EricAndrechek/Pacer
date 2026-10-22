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

    /// The gap between two parts, in points. Neighbouring parts never meet
    /// colour to colour: the card shows through between them, so two hues a
    /// colour-blind reader sees as close still have an edge (the data-viz
    /// mark spec's 2px surface gap).
    nonisolated static let gap: CGFloat = 2

    public var body: some View {
        let parts = breakdown.parts
        let shown = parts.filter { $0.share > 0 }.count
        // The bar's corner radius is also the narrowest part worth a gap: a
        // part thinner than the rounding sits inside the curve of the end.
        let radius: CGFloat = height / 2
        GeometryReader { geo in
            let layout = PacerCostBarLayout(
                shares: parts.map(\.share), width: geo.size.width,
                gap: Self.gap, sliver: radius)
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

/// Where each part of a `PacerCostBar` goes: its width, and the gap after it.
/// Pure, so where the gaps fall is tested without drawing a bar.
///
/// A gap goes between two shown parts only when both are wide enough to
/// read. A sliver — narrower than `sliver` — gets no gap on either side and
/// sits flush against its neighbours. Gapping it drew a hairline of colour,
/// then a gap, then the next part: at the bar's end that hairline is all
/// that fills the rounded corner, and the end looked cut off rather than
/// round. Flush, the neighbour fills the curve and the sliver is a thin edge
/// on it.
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
        // The shown parts, in order; $0 parts are skipped when finding a
        // part's neighbour.
        let shown: [Int] = shares.indices.filter { shares[$0] > 0 }
        var trailing: [CGFloat] = Array(repeating: 0, count: shares.count)
        var gaps: Int = 0
        for (a, b) in zip(shown, shown.dropFirst()) {
            let left: CGFloat = full * CGFloat(shares[a])
            let right: CGFloat = full * CGFloat(shares[b])
            if left >= sliver && right >= sliver {
                trailing[a] = gap
                gaps += 1
            }
        }
        let taken: CGFloat = gap * CGFloat(gaps)
        let room: CGFloat = max(0, full - taken)
        segments = shares.indices.map { i -> Segment in
            let share: CGFloat = CGFloat(max(0, shares[i]))
            return Segment(width: room * share, trailingGap: trailing[i])
        }
    }
}

/// How much room a `PacerCostBreakdownView` has.
public enum PacerCostBreakdownStyle: Sendable, Equatable {
    /// A card's width: the stacked bar, then the five parts side by side in
    /// equal columns, each with its dollars, share and tokens.
    case regular
    /// A hover card (~280 pt): the five parts as rows, one line each — dot,
    /// name, dollars, share, tokens under a one-word "tokens" heading — and
    /// no bar. A compact breakdown sits beside a chart that already draws
    /// the mix, and the share column says what a 250 pt bar would.
    case compact
}

/// The breakdown for one total: the stacked bar, the five parts with their
/// dollars, share and tokens, and the cache hit rate as one line of text
/// under them.
///
/// One line, not two: tokens are ~98% cache reads, so a token bar would be a
/// single colour. Each part's token count rides in its legend entry instead,
/// read through `TokenBreakdown[_:]`.
///
/// It does not print the total itself — every screen that shows it already
/// has the total in its summary, and the parts are what this adds. With no
/// cost to split (every model unpriced) it is only the hit rate: five $0
/// parts would say nothing.
///
/// `cacheHitTrailing` goes after the hit rate on its line, for a screen that
/// has something of its own to say about the cache (Today's savings).
public struct PacerCostBreakdownView<CacheHitTrailing: View>: View {
    private let breakdown: CostBreakdown
    private let style: PacerCostBreakdownStyle
    private let cacheHitTrailing: CacheHitTrailing

    public init(
        _ breakdown: CostBreakdown,
        style: PacerCostBreakdownStyle = .regular,
        @ViewBuilder cacheHitTrailing: () -> CacheHitTrailing
    ) {
        self.breakdown = breakdown
        self.style = style
        self.cacheHitTrailing = cacheHitTrailing()
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
                case .compact:
                    Grid(alignment: .leading, horizontalSpacing: PacerCompactColumns.spacing, verticalSpacing: 4) {
                        // "tokens" once, over its column, rather than on every
                        // row: five "21.5B tokens" cost the 37 pt that kept
                        // "5m cache writes" from truncating at hover-card width.
                        GridRow {
                            Color.clear
                                .gridCellUnsizedAxes([.horizontal, .vertical])
                                .gridCellColumns(3)
                            Text("tokens")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .pacerCompactColumn(PacerCompactColumns.tokens)
                        }
                        ForEach(breakdown.parts) { part in
                            PartRow(part: part)
                        }
                    }
                }
            }
            if let ratio = breakdown.cacheHitRatio {
                PacerCacheHitLine(ratio: ratio) { cacheHitTrailing }
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
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(pacerCost(part.usd))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text(part.percentLabel)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                    Text(pacerPartTokens(part.tokens))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
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

public extension PacerCostBreakdownView where CacheHitTrailing == EmptyView {
    init(_ breakdown: CostBreakdown, style: PacerCostBreakdownStyle = .regular) {
        self.init(breakdown, style: style) { EmptyView() }
    }

    /// Whether there is anything to show — callers hide the card otherwise.
    static func hasContent(_ breakdown: CostBreakdown) -> Bool {
        breakdown.total > 0 || breakdown.cacheHitRatio != nil
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
    "\(part.component.label): \(pacerCostExact(part.usd)) · \(pacerTokensExact(part.tokens)) tokens"
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

/// The cache hit rate as one quiet line of text — "Cache hits 98.1%" — with
/// a caller-supplied trailing slot.
///
/// Text, not a bar: a filled track beside the five-part cost bar was a second
/// bar that read as part of the first, and it spent a row on one number. As a
/// line under the legend it starts where the legend does and costs one line.
/// `ratio` is `TokenBreakdown.cacheHitRatio`, the one definition.
public struct PacerCacheHitLine<Trailing: View>: View {
    private let ratio: Double
    private let trailing: Trailing

    public init(ratio: Double, @ViewBuilder trailing: () -> Trailing) {
        self.ratio = ratio
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Cache hits")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(pacerCacheHitText(ratio))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .help("\(pacerCacheHitText(ratio)) of prompt tokens served from cache")
            .accessibilityElement(children: .combine)
            trailing
        }
        .lineLimit(1)
    }
}

public extension PacerCacheHitLine where Trailing == EmptyView {
    init(ratio: Double) {
        self.init(ratio: ratio) { EmptyView() }
    }
}

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
