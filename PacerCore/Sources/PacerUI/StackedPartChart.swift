import SwiftUI
import Charts
import Observation
import PacerCore

// The one cost bar chart (#225, #215 follow-up). Every chart that plots cost
// over time — the dashboard's 30 days and today by hour, History's months,
// a project's days — draws it with this, stacked by priced part in
// `CostComponent` order and coloured by `PacerCostPalette`, with one hover
// card. Before this each card drew its own `Chart`, and only the 30-day one
// was stacked: four charts of the same quantity in three looks.

// MARK: - Buckets

/// What one bar of a `PacerStackedPartChart` covers. Decides the axis
/// labels and the hover card's heading; the bars are drawn the same way.
public enum PacerChartBucketKind: Sendable, Equatable {
    /// `YYYY-MM-DD` ids.
    case day
    /// `00`–`23` ids: hour of day.
    case hour
    /// `YYYY-MM` ids.
    case month
}

/// One model inside a bucket, for the hover card's top models: its cost, its
/// share of the bucket's cost, and its tokens.
public struct PacerChartModelCost: Sendable, Equatable, Identifiable {
    /// The raw model id; the card shows `pacerModelDisplayName` of it.
    public let model: String
    public let usd: Double
    /// `usd` over the bucket's whole cost, in 0...1 — the bucket's, not the
    /// top three's, so three models that are 60% of a day read 60%, not 100%.
    public let share: Double
    /// Every token the model used in the bucket (`TokenBreakdown.all`).
    /// `nil` when the source does not carry all five parts per model — the
    /// project rollup stores only input + output per model, and a figure
    /// that is ~2% of the model's real tokens, in the column the parts above
    /// print all of theirs in, would read as the total.
    public let tokens: Int64?
    public var id: String { model }

    public init(model: String, usd: Double, share: Double = 0, tokens: Int64? = nil) {
        self.model = model
        self.usd = usd
        self.share = share
        self.tokens = tokens
    }

    /// "81%", "<1%" for a model too small to round to 1 but not nothing —
    /// the same rule as a part's `CostBreakdown.Part.percentLabel`.
    public var percentLabel: String {
        let percent = Int((share * 100).rounded())
        if percent == 0 && usd > 0 { return "<1%" }
        return "\(percent)%"
    }
}

/// One bar: its x-value, what its cost was made of, and its top models.
///
/// A plain value, built in the caller's cached derive step (usually through
/// `PacerChartBucketBuilder`), so the hover card reads precomputed numbers
/// and a pointer move never re-sums anything.
/// One drawn segment of a stacked bar: its part and where it sits on y.
public struct PacerStackSpan: Sendable, Equatable, Identifiable {
    public let part: CostBreakdown.Part
    public let start: Double
    public let end: Double
    public var id: CostBreakdown.Part.ID { part.id }
}

public struct PacerChartBucket: Sendable, Equatable, Identifiable {
    /// The x-value, in the kind's id format. Also what a click reports.
    public let id: String
    public let breakdown: CostBreakdown
    /// Largest first, at most three. Empty leaves the models off the card.
    public let topModels: [PacerChartModelCost]
    /// The parts the bar draws, in stacking (`CostComponent`) order, with
    /// $0 parts left out. Computed once here rather than on every body pass:
    /// `CostBreakdown.parts` does the largest-remainder rounding each call.
    public let segments: [CostBreakdown.Part]

    public init(id: String, breakdown: CostBreakdown, topModels: [PacerChartModelCost] = []) {
        self.id = id
        self.breakdown = breakdown
        self.topModels = topModels
        self.segments = breakdown.parts.filter { $0.usd > 0 }
    }

    /// The bar's height: the parts' sum, so the stack and its label agree.
    public var total: Double { breakdown.total }

    /// The topmost drawn part — the top of the stack, where the total goes.
    /// `nil` for a $0 bucket.
    public var stackTop: CostComponent? { segments.last?.component }

    /// The drawn segments as y spans, stacked in order. Between two
    /// neighbouring parts the lower one gives up `gap` (cost units) off its
    /// top, so the card shows between them and two hues a colour-blind reader
    /// sees as close still get an edge.
    ///
    /// A sliver — shorter than twice the gap — gets no gap above or below it
    /// and sits flush against its neighbours, the rule `PacerCostBar` follows.
    /// Gapped, it was a hairline of colour floating under a gap at the foot
    /// of the bar. The top segment is never trimmed, so the bar's height is
    /// still the total its label prints.
    public func spans(gap: Double) -> [PacerStackSpan] {
        let sliver: Double = gap * 2
        var spans: [PacerStackSpan] = []
        var start = 0.0
        for (i, part) in segments.enumerated() {
            let end: Double = start + part.usd
            let next: CostBreakdown.Part? = i + 1 < segments.count ? segments[i + 1] : nil
            let gapped: Bool = next.map { part.usd >= sliver && $0.usd >= sliver } ?? false
            spans.append(PacerStackSpan(part: part, start: start, end: gapped ? end - gap : end))
            start = end
        }
        return spans
    }

    /// Whether the bucket has anything to say on hover. An hour with tokens
    /// but no price still does; an empty hour does not.
    public var hasActivity: Bool { total > 0 || breakdown.tokens.all > 0 }

    /// The `limit` most expensive models, largest first, ties by name so the
    /// order does not change between refreshes.
    ///
    /// - Parameters:
    ///   - tokens: each model's tokens; `nil` leaves every model's unknown.
    ///   - total: the bucket's cost, the shares' denominator. Defaults to the
    ///     models' sum, which is the same number for the daily and hourly
    ///     rollups (one row per model).
    public static func topModels(
        _ costs: [String: Double],
        tokens: [String: Int64]? = nil,
        of total: Double? = nil,
        limit: Int = 3
    ) -> [PacerChartModelCost] {
        let whole: Double = total ?? costs.values.reduce(0, +)
        let sorted = costs.sorted { a, b in
            a.value != b.value ? a.value > b.value : a.key < b.key
        }
        return sorted.prefix(limit).map { entry in
            PacerChartModelCost(
                model: entry.key,
                usd: entry.value,
                share: whole > 0 ? entry.value / whole : 0,
                tokens: tokens?[entry.key])
        }
    }

    /// `14` → `"14"`, `3` → `"03"`: two digits, so the ids sort as hours.
    public static func hourKey(_ hour: Int) -> String {
        String(format: "%02d", hour)
    }

    /// Every hour of a day, in order — the hour chart's fixed domain, so a
    /// quiet hour is an empty band rather than a missing one.
    public static let allHourKeys: [String] = (0..<24).map(hourKey)

    /// `2026-04-30` → `2026-04`; `nil` for anything shorter.
    public static func monthKey(_ ymd: String) -> String? {
        ymd.count >= 7 ? String(ymd.prefix(7)) : nil
    }
}

/// Sums rollup rows into chart buckets: one per key, with the parts, the
/// tokens, and the per-model cost and tokens that become the top three.
public struct PacerChartBucketBuilder: Sendable {
    private var breakdowns: [String: CostBreakdown] = [:]
    private var modelCosts: [String: [String: Double]] = [:]
    /// Filled only by the one-model-per-row `add`: a key that came only from
    /// precomputed per-model costs has no entry, so its models' tokens stay
    /// unknown rather than reading as zero.
    private var modelTokens: [String: [String: Int64]] = [:]

    public init() {}

    /// A row that is one model's share of `key` — the daily and hourly
    /// rollups, keyed (date|hour, model). The row's breakdown carries all five
    /// parts' tokens, so the model's tokens are summed from it: a month adds up
    /// its days' rows, and its models' tokens with them.
    public mutating func add(_ key: String, _ breakdown: CostBreakdown, model: String) {
        breakdowns[key, default: .zero] += breakdown
        modelCosts[key, default: [:]][model, default: 0] += breakdown.total
        modelTokens[key, default: [:]][model, default: 0] += breakdown.tokens.all
    }

    /// A row that already carries its per-model costs — the project rollup's
    /// `modelCostJSON`. Its models' tokens are left unknown: that rollup
    /// keeps only input + output per model (see `PacerChartModelCost.tokens`).
    public mutating func add(_ key: String, _ breakdown: CostBreakdown, modelCosts costs: [String: Double]) {
        breakdowns[key, default: .zero] += breakdown
        for (model, usd) in costs {
            modelCosts[key, default: [:]][model, default: 0] += usd
        }
    }

    /// The buckets in key order. `keys` fixes the set and its order (the hour
    /// chart's 24 hours, quiet ones as empty bars); `last` keeps the newest.
    public func buckets(keys: [String]? = nil, last: Int? = nil) -> [PacerChartBucket] {
        var ordered = keys ?? breakdowns.keys.sorted()
        if let last { ordered = Array(ordered.suffix(last)) }
        return ordered.map { key in
            let breakdown = breakdowns[key] ?? .zero
            return PacerChartBucket(
                id: key,
                breakdown: breakdown,
                topModels: PacerChartBucket.topModels(
                    modelCosts[key] ?? [:], tokens: modelTokens[key], of: breakdown.total))
        }
    }
}

// MARK: - Chart

/// Cost over time as bars stacked by priced part, with a hover card that
/// floats over the chart.
///
/// - Stacked by cost part only, in `CostComponent` order, coloured by
///   `PacerCostPalette`: one encoding. The split by model lives on the
///   Models tab; the hover card names the top three.
/// - The y-axis ends at the tallest bar — no axis room above the data —
///   with a sliver of padding above so the tallest bar's label still fits.
/// - The `annotating` most expensive bars carry their total on top.
/// - Hovering draws a dashed rule on the bar and the card beside it. Both
///   live in an overlay that ignores hit-testing, so nothing on the page
///   moves and the pointer still reaches the chart underneath.
/// - Hover is cheap by construction: the selection lives in an `@Observable`
///   that only the overlay reads, so a pointer move redraws the card and
///   never re-lays-out the marks (see `PacerChartHover`).
public struct PacerStackedPartChart: View {
    private let buckets: [PacerChartBucket]
    private let kind: PacerChartBucketKind
    private let height: CGFloat
    private let annotating: Int
    private let onTap: ((String) -> Void)?

    @State private var hover = PacerChartHover()

    /// - Parameters:
    ///   - buckets: the bars, in display order.
    ///   - kind: what a bar covers; sets the axis and the card's heading.
    ///   - height: the chart's height, legend included. The hover card is
    ///     clamped inside it, so it needs to be tall enough to hold one.
    ///   - annotating: how many of the most expensive bars carry their total.
    ///   - onTap: called with the clicked bucket's id; `nil` for no click.
    public init(
        _ buckets: [PacerChartBucket],
        kind: PacerChartBucketKind,
        height: CGFloat = 220,
        annotating: Int = 3,
        onTap: ((String) -> Void)? = nil
    ) {
        self.buckets = buckets
        self.kind = kind
        self.height = height
        self.annotating = annotating
        self.onTap = onTap
    }

    /// Drawn as though `selection` were hovered — for the off-screen render
    /// tests, which cannot move a pointer.
    init(
        _ buckets: [PacerChartBucket],
        kind: PacerChartBucketKind,
        height: CGFloat = 220,
        annotating: Int = 3,
        hovering selection: String?
    ) {
        self.init(buckets, kind: kind, height: height, annotating: annotating)
        _hover = State(initialValue: PacerChartHover(selected: selection))
    }

    /// Above the plot, for the tallest bar's label: padding outside the
    /// chart rather than a taller y-domain, so the axis itself still ends at
    /// the data's max. (Not `chartPlotStyle` padding: that moves the marks
    /// and leaves the gridlines and axis labels where they were.)
    nonisolated static let labelRoom: CGFloat = 14
    /// Points of card between two stacked parts (see `PacerChartBucket.spans`,
    /// which leaves it out beside a part under twice this tall).
    nonisolated static let segmentGap: Double = 1.5

    public var body: some View {
        let axis = PacerChartXAxis(kind: kind, ids: buckets.map(\.id))
        let labelled = Self.annotatedIDs(buckets, top: annotating)
        let cap = Self.barCap(kind)
        let width = PacerSparseBars.width(count: buckets.count, cap: cap)
        let hover = self.hover
        let yMax = Self.yMax(buckets)
        // The segment gap in cost units: about `segmentGap` points on a plot
        // whose height is the frame less the label room, the x axis and the
        // legend. An estimate, close enough for a hairline.
        // Typed in steps: Xcode 16 finds `-` ambiguous across CGFloat/Double.
        let plotPoints: CGFloat = max(40, height - Self.labelRoom - 44)
        let gap: Double = yMax * Self.segmentGap / Double(plotPoints)
        Chart {
            ForEach(buckets) { bucket in
                // Once per bar, not per segment: it runs a date formatter.
                let title = axis.title(bucket.id)
                // One segment per priced part, stacked in `CostComponent`
                // order (the style scale's domain below), so a part sits in
                // the same band on every bar.
                ForEach(bucket.spans(gap: gap)) { span in
                    let part = span.part
                    BarMark(
                        x: .value("Bucket", bucket.id),
                        yStart: .value("Cost", span.start),
                        yEnd: .value("Cost", span.end),
                        width: width
                    )
                    .foregroundStyle(by: .value("Part", part.component.label))
                    // The total goes on the topmost segment: the top of the
                    // stack. `.disabled` on y so Charts neither pushes it
                    // down into the bar nor pads the scale for it.
                    .annotation(
                        position: .top, alignment: .center, spacing: 2,
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                    ) {
                        if part.component == bucket.stackTop, labelled.contains(bucket.id) {
                            Text(pacerCost(bucket.total))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel(title)
                    .accessibilityValue("\(part.component.label), \(pacerCostExact(part.usd))")
                }
            }
        }
        .frame(height: height - Self.labelRoom)
        .padding(.top, Self.labelRoom)
        // An explicit band domain keeps every bucket — a quiet hour with no
        // marks would otherwise drop out of the axis — and keeps their order.
        .chartXScale(domain: buckets.map(\.id))
        .chartYScale(domain: 0...yMax)
        .chartForegroundStyleScale(
            domain: PacerCostPalette.chartDomain,
            range: PacerCostPalette.chartRange
        )
        .chartLegend(position: .bottom, alignment: .leading, spacing: 8)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.18))
                AxisValueLabel {
                    if let dollars = value.as(Double.self) {
                        Text(pacerCost(dollars))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: axis.values) { value in
                AxisValueLabel {
                    // Decided in the label, not by `values:` alone: that is
                    // not honoured on a band axis from macOS 26 on (see
                    // `PacerDateAxis.labelIfMarked`).
                    if let id = value.as(String.self), let text = axis.labelIfMarked(id) {
                        Text(text)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        // Written through the model, never read here: this body does not
        // depend on the selection, so hovering does not re-run it.
        .chartXSelection(value: Binding(get: { hover.raw }, set: { hover.update($0) }))
        .chartOverlay { proxy in
            PacerChartHoverLayer(proxy: proxy, hover: hover, buckets: buckets, axis: axis, barCap: cap)
        }
        // The whole chart is the click target. The overlay above ignores
        // hit-testing, so this and `chartXSelection` both see the pointer.
        // Arrow cursor (default): clickable charts don't warrant the link
        // cursor per the macOS HIG.
        .contentShape(Rectangle())
        .onTapGesture {
            // The immediate selection: the debounced one may not have
            // caught up with a quick click.
            if let id = hover.raw, let onTap { onTap(id) }
        }
    }

    /// The widest a bar is drawn while the series is sparse. Months get more:
    /// there are at most a dozen of them.
    nonisolated static func barCap(_ kind: PacerChartBucketKind) -> CGFloat {
        kind == .month ? 56 : 44
    }

    /// The y-domain's top: the tallest bar, so the axis has no room above
    /// the data. A chart of nothing gets a unit domain rather than 0...0.
    nonisolated static func yMax(_ buckets: [PacerChartBucket]) -> Double {
        let top = buckets.map(\.total).max() ?? 0
        return top > 0 ? top : 1
    }

    /// The `top` most expensive non-empty buckets, which carry their total.
    /// Ties go to the newer bucket (the larger id).
    nonisolated static func annotatedIDs(_ buckets: [PacerChartBucket], top: Int) -> Set<String> {
        guard top > 0 else { return [] }
        let ranked = buckets.filter { $0.total > 0 }.sorted { a, b in
            a.total != b.total ? a.total > b.total : a.id > b.id
        }
        return Set(ranked.prefix(top).map(\.id))
    }
}

// MARK: - Hover

/// The chart's hover selection, held outside the chart's own state.
///
/// `chartXSelection` writes `raw` on every pointer move. Nothing observes
/// `raw`; `selected` follows it once the pointer settles for 40ms, and only
/// the hover overlay reads `selected`. So a sweep across the bars — a scroll
/// passing over the chart is the usual one — re-lays-out nothing, and a
/// deliberate hover redraws the overlay alone. When the selection was
/// `@State` on each card, every pointer event re-ran the card's body and
/// re-laid-out every mark (docs/perf-tuning.md).
@MainActor
@Observable
final class PacerChartHover {
    /// What the overlay draws.
    private(set) var selected: String?
    /// The immediate pointer selection: the click handler's answer.
    @ObservationIgnored private(set) var raw: String?
    @ObservationIgnored private var settle: Task<Void, Never>?

    init(selected: String? = nil) {
        self.selected = selected
        self.raw = selected
    }

    func update(_ value: String?) {
        raw = value
        settle?.cancel()
        settle = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled, let self, self.selected != value else { return }
            self.selected = value
        }
    }
}

/// The dashed rule on the hovered bar and the card beside it.
private struct PacerChartHoverLayer: View {
    let proxy: ChartProxy
    let hover: PacerChartHover
    let buckets: [PacerChartBucket]
    let axis: PacerChartXAxis
    let barCap: CGFloat

    var body: some View {
        GeometryReader { geo in
            if let id = hover.selected,
               let bucket = buckets.first(where: { $0.id == id }),
               bucket.hasActivity,
               let plotAnchor = proxy.plotFrame,
               let x = proxy.position(forX: id) {
                let plot = geo[plotAnchor]
                let anchorX = plot.minX + x
                // Clear of the bar's edge, not its centre: half a band, or
                // half the capped width while the series is sparse.
                let band = plot.width / CGFloat(max(buckets.count, 1))
                let sparse = buckets.count <= PacerSparseBars.sparseThreshold
                let halfBar = sparse ? min(band, barCap) / 2 : band / 2
                ZStack(alignment: .topLeading) {
                    Path { p in
                        p.move(to: CGPoint(x: anchorX, y: plot.minY))
                        p.addLine(to: CGPoint(x: anchorX, y: plot.maxY))
                    }
                    .stroke(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    PacerHoverPlacement(anchorX: anchorX, gap: halfBar + 6) {
                        PacerCostHoverCard(
                            title: axis.title(bucket.id),
                            breakdown: bucket.breakdown,
                            topModels: bucket.topModels)
                    }
                }
            }
        }
        // Never a hit target: the pointer has to keep reaching the chart for
        // the selection and the click to work.
        .allowsHitTesting(false)
    }
}

/// Places the hover card beside the hovered bar and keeps it inside the
/// chart: right of the bar when it fits, else left, then clamped to the
/// bounds. A layout rather than measured `@State`, so the card is in the
/// right place on its first frame instead of jumping there on its second.
struct PacerHoverPlacement: Layout {
    var anchorX: CGFloat
    var gap: CGFloat = 12
    /// The card's width when the chart is wide enough; narrower charts get
    /// their own width.
    var idealWidth: CGFloat = PacerCostHoverCard.idealWidth

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let card = subviews.first else { return }
        let width = min(idealWidth, bounds.width)
        let size = card.sizeThatFits(ProposedViewSize(width: width, height: nil))
        // `bounds` is in the parent's coordinate space and `anchorX` in this
        // layout's own: offset it, or the card lands `bounds.minX` to the left.
        let anchor = bounds.minX + anchorX
        let origin = Self.origin(card: size, anchorX: anchor, gap: gap, in: bounds)
        card.place(at: origin, anchor: .topLeading, proposal: ProposedViewSize(size))
    }

    /// Where the card's top-leading corner goes: beside the bar on whichever
    /// side it fits, right first. When neither does (a narrow chart), on the
    /// side with more room, clamped — it covers the fewest bars that way.
    static func origin(card: CGSize, anchorX: CGFloat, gap: CGFloat, in bounds: CGRect) -> CGPoint {
        let right = anchorX + gap
        let left = anchorX - gap - card.width
        let x: CGFloat
        if right + card.width <= bounds.maxX {
            x = right
        } else if left >= bounds.minX {
            x = left
        } else {
            let roomRight = bounds.maxX - anchorX
            let roomLeft = anchorX - bounds.minX
            let maxX = max(bounds.minX, bounds.maxX - card.width)
            x = roomRight >= roomLeft ? maxX : bounds.minX
        }
        // Top-aligned: the chart is sized to hold the card, and the top is
        // the side the card never has to move away from.
        return CGPoint(x: x, y: bounds.minY)
    }
}

// MARK: - Axis

/// The x-axis marks and the hover heading for one chart's buckets.
struct PacerChartXAxis {
    let kind: PacerChartBucketKind
    /// The ids to mark.
    let values: [String]
    private let marked: Set<String>
    private let dateAxis: PacerDateAxis?
    /// Whether the buckets cross a year boundary, so day headings and month
    /// labels carry the year.
    private let straddlesYear: Bool

    init(kind: PacerChartBucketKind, ids: [String]) {
        self.kind = kind
        let first = ids.first.map { $0.prefix(4) }
        let straddles = ids.contains { $0.prefix(4) != first }
        switch kind {
        case .day:
            let axis = pacerDateAxis(ids)
            dateAxis = axis
            values = axis.values
            straddlesYear = straddles
        case .hour:
            dateAxis = nil
            values = ["00", "06", "12", "18", "23"].filter(ids.contains)
            straddlesYear = false
        case .month:
            dateAxis = nil
            values = Self.monthMarks(ids)
            straddlesYear = straddles
        }
        marked = Set(values)
    }

    /// A dozen months all fit; past that, every k-th, anchored on the newest.
    static func monthMarks(_ ids: [String], target: Int = 12) -> [String] {
        guard ids.count > target else { return ids }
        let step = Int((Double(ids.count) / Double(target)).rounded(.up))
        let last = ids.count - 1
        return stride(from: last, through: 0, by: -step).reversed().map { ids[$0] }
    }

    /// The axis label for `id` when it is marked, `nil` otherwise.
    func labelIfMarked(_ id: String) -> String? {
        guard marked.contains(id) else { return nil }
        switch kind {
        case .day: return dateAxis?.label(id) ?? id
        case .hour: return Int(id).map { pacerHour(Self.referenceDate(hour: $0), style: .compact) } ?? id
        case .month: return PacerDateAxis.monthLabel(id, withYear: straddlesYear)
        }
    }

    /// The hover card's heading: "Tue, Oct 21", "2 PM", "October 2026".
    func title(_ id: String) -> String {
        switch kind {
        case .day:
            guard let date = Formats.ymd.date(from: id) else { return id }
            return (straddlesYear ? Formats.dayWithYear : Formats.day).string(from: date)
        case .hour:
            return Int(id).map { pacerHour(Self.referenceDate(hour: $0), style: .regular) } ?? id
        case .month:
            guard let date = Formats.ymd.date(from: id + "-01") else { return id }
            return Formats.month.string(from: date)
        }
    }

    /// A fixed day at `hour`, only for formatting the hour. Not today: a day
    /// with a DST change has an hour missing or doubled.
    static func referenceDate(hour: Int) -> Date {
        var c = DateComponents()
        c.year = 2001; c.month = 1; c.day = 1; c.hour = hour
        return Calendar.current.date(from: c) ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    /// Built once, like `TimeFormatters`' cache, so the chart never builds
    /// one per bar.
    private enum Formats {
        static let ymd: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.calendar = Calendar(identifier: .gregorian)
            f.timeZone = .current
            f.dateFormat = "yyyy-MM-dd"
            return f
        }()
        static let day = localized("EEE MMM d")
        static let dayWithYear = localized("EEE MMM d yyyy")
        static let month = localized("MMMM yyyy")

        static func localized(_ template: String) -> DateFormatter {
            let f = DateFormatter()
            f.locale = .current
            f.timeZone = .current
            f.setLocalizedDateFormatFromTemplate(template)
            return f
        }
    }
}
