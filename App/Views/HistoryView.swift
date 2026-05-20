import SwiftUI
import SwiftData
import Charts
import PacerCore
import PacerUI

/// "All time" view — lifetime totals, monthly trend, the activity
/// heatmap, and most expensive days. Reads from `DailyAggregate` (the
/// canonical roll-up; pre-summed, so no per-row cost calc here).
///
/// Order: lifetime hero → 26-week heatmap → monthly bar chart → top
/// expensive days table.
///
/// A single time-range picker in the page header scopes the
/// range-aware cards (LifetimeSummary, TopDays). HeatmapCard and
/// MonthlyChartCard ignore it — they're convention-driven windows
/// (52 weeks / 12 months) where the fixed scope IS the card's
/// purpose. The single picker replaces the two independent pickers
/// the cards each carried previously, which let the two card scopes
/// drift apart (top "Last 90 days", bottom "Lifetime") in ways that
/// felt like one picker was controlling the other.
struct HistoryView: View {
    @State private var modalRoot: PacerModalDestination?

    @AppStorage("pacer.history.range", store: PacerSettings.store)
    private var rangeRaw: String = TimeRange.all.rawValue

    private var range: TimeRange { TimeRange(rawValue: rangeRaw) ?? .all }
    private var rangeBinding: Binding<TimeRange> {
        Binding(get: { range }, set: { rangeRaw = $0.rawValue })
    }

    var body: some View {
        PageScaffold(
            "History",
            subtitle: "Totals, activity, and your most expensive days.",
            trailing: {
                Picker("Time range", selection: rangeBinding) {
                    ForEach(TimeRange.allCases) { r in
                        Text(r.shortLabel).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
                .controlSize(.small)
                .labelsHidden()
            }
        ) {
            LifetimeSummaryCard(range: range)
            HeatmapCard { dayKey in
                modalRoot = .day(date: dayKey)
            }
            MonthlyChartCard()
            TopDaysCard(range: range) { dayKey in
                modalRoot = .day(date: dayKey)
            }
        }
        .pacerModalNavigation(root: $modalRoot)
    }
}

// MARK: - Range-scoped summary

/// Headline tile-grid summary that re-scopes by the page-level range.
/// Replaces the pre-redesign "Lifetime"-only card. Range comes from
/// `HistoryView`'s single `@AppStorage` so changing it affects this
/// card and `TopDaysCard` together.
///
/// Card vs Content split is the `.id(range)` trick: the outer Card
/// just owns the range parameter; the inner Content takes `range` as
/// an init argument and scopes its @Query accordingly. `.id(range)`
/// on the content forces SwiftData to re-create the @Query each time
/// the range changes — which is the only way to push the range
/// predicate into the fetch layer instead of filtering 700+ rows in
/// memory on every scan tick.
private struct LifetimeSummaryCard: View {
    let range: TimeRange

    var body: some View {
        // The `.id()` value is prefixed per-card so it can't collide
        // with another `.id(range)` sibling in the same LazyVStack.
        // Without the prefix, SwiftUI's identity system treated this
        // card and TopDaysContent (which also re-init on range change)
        // as the same view and dropped one — the bottom of the page
        // was just empty space where TopDays should have rendered.
        LifetimeSummaryContent(range: range)
            .id("lifetime-summary-\(range.rawValue)")
    }
}

private struct LifetimeSummaryContent: View {
    let range: TimeRange

    @Query private var aggregates: [DailyAggregate]

    init(range: TimeRange) {
        self.range = range
        if let since = range.since {
            let cutoffString = TokenSample.formatDate(since)
            _aggregates = Query(
                filter: #Predicate<DailyAggregate> { $0.date >= cutoffString },
                sort: \DailyAggregate.date,
                order: .reverse
            )
        } else {
            // `.all` still needs every row — but we can't show
            // "lifetime since YYYY-MM-DD" without it. Acceptable
            // because (a) .all is opt-in, and (b) it's still cached
            // behind a scan-meta tick so the walk runs once per cycle.
            _aggregates = Query(
                sort: \DailyAggregate.date, order: .reverse
            )
        }
    }

    private struct Totals {
        var cost: Double = 0
        var input: Int64 = 0
        var output: Int64 = 0
        var cacheRead: Int64 = 0
        var distinctDays: Int = 0
        var distinctModels: Int = 0
        var firstDate: String?
    }

    /// Computed per body fire from the range-scoped `@Query`. No
    /// `@State` cache — the previous design populated the cache via
    /// `.onAppear`, which fires AFTER first body, so every `.id(range)`
    /// re-init briefly rendered empty tiles before the cache landed.
    /// The walk is O(aggregates) over a scoped slice (≤ ~5k rows even
    /// on .all for multi-year users), which is sub-millisecond, and the
    /// body only re-fires on range / scan-tick / @AppStorage changes
    /// — no hover state in this card.
    private var totals: Totals {
        var t = Totals()
        var dates = Set<String>()
        var models = Set<String>()
        var minDate: String?
        for row in aggregates {
            t.cost += row.totalCostUSD
            t.input += row.inputTokens
            t.output += row.outputTokens
            t.cacheRead += row.cacheReadTokens
            dates.insert(row.date)
            models.insert(row.model)
            if minDate == nil || row.date < minDate! { minDate = row.date }
        }
        t.distinctDays = dates.count
        t.distinctModels = models.count
        t.firstDate = minDate
        return t
    }

    private var cardTitle: String {
        switch range {
        case .sevenDays:  return "Last 7 days"
        case .thirtyDays: return "Last 30 days"
        case .ninetyDays: return "Last 90 days"
        case .oneYear:    return "Last 12 months"
        case .all:        return "Lifetime"
        }
    }

    var body: some View {
        let t = totals
        PacerCard(cardTitle, trailing: {
            if range == .all, let first = t.firstDate {
                Text("since \(first)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }) {
            if t.distinctDays == 0 {
                Text(range == .all
                     ? "No history yet — start using Claude Code and Pacer will catch up."
                     : "No activity in this range. Try widening the time window.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: 16, alignment: .topLeading),
                        count: 6
                    ),
                    alignment: .leading,
                    spacing: 12
                ) {
                    MetricTile(value: pacerCost(t.cost), label: "cost", size: .hero)
                    MetricTile(value: pacerTokens(t.input), label: "input")
                    MetricTile(value: pacerTokens(t.output), label: "output")
                    MetricTile(value: pacerTokens(t.cacheRead), label: "cache read")
                    MetricTile(value: "\(t.distinctDays)", label: "active days")
                    MetricTile(value: "\(t.distinctModels)", label: "models")
                }
            }
        }
    }
}

// MARK: - Monthly bar chart

private struct MonthlyChartCard: View {
    /// Scoped to the chart's 12-month display window — the unbounded
    /// query was loading every DailyAggregate row (730+ on a 2-year DB)
    /// just so `refreshMonthly()` could group, sort, and `.suffix(12)`.
    /// 13 months of leeway covers any partial first month inside the
    /// chart's leftmost bar.
    @Query private var aggregates: [DailyAggregate]
    @Query(ScanMetaFetchDescriptor.scanCompletedProbe)
    private var scanMeta: [ClaudeCodeMeta]

    init() {
        let cutoffString = TokenSample.formatDate(
            Calendar.current.date(byAdding: .month, value: -13, to: Date()) ?? .distantPast
        )
        _aggregates = Query(
            filter: #Predicate<DailyAggregate> { $0.date >= cutoffString },
            sort: \DailyAggregate.date,
            order: .reverse
        )
    }

    @State private var selectedMonth: String?
    @State private var cachedMonthly: [MonthBucket] = []
    @State private var cachedTotal: Double = 0

    private struct MonthBucket: Identifiable {
        let month: String  // YYYY-MM
        let cost: Double
        var id: String { month }
    }

    private var monthly: [MonthBucket] { cachedMonthly }

    /// Rebuild `cachedMonthly` from a Dictionary-grouping walk over
    /// every aggregate. Used to run on every body render — and the
    /// `chart` view referenced `monthly` independently from `body`,
    /// effectively doubling the cost. Now runs once per scan tick.
    private func refreshMonthly() {
        var totals: [String: Double] = [:]
        for row in aggregates {
            guard row.date.count >= 7 else { continue }
            let key = String(row.date.prefix(7))
            totals[key, default: 0] += row.totalCostUSD
        }
        let sorted = totals.keys.sorted()
        let last12 = sorted.suffix(12)
        cachedMonthly = last12.map { MonthBucket(month: $0, cost: totals[$0] ?? 0) }
        cachedTotal = cachedMonthly.reduce(0) { $0 + $1.cost }
    }

    var body: some View {
        let total = cachedTotal
        PacerCard("Last 12 months", trailing: {
            if let selectedMonth, let row = monthly.first(where: { $0.month == selectedMonth }) {
                HStack(spacing: 8) {
                    Text(longMonth(row.month))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(pacerCost(row.cost))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            } else if !monthly.isEmpty {
                Text("total \(pacerCost(total))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }) {
            if monthly.isEmpty {
                Text("No monthly history yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(height: 200)
            } else {
                chart
            }
        }
        .onAppear { refreshMonthly() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshMonthly() }
    }

    private var chart: some View {
        Chart {
            ForEach(monthly) { m in
                BarMark(
                    x: .value("Month", m.month),
                    y: .value("Cost", m.cost)
                )
                .foregroundStyle(.tint)
                .cornerRadius(2)
                .annotation(position: .top, alignment: .center, spacing: 2) {
                    if m.cost > 0 && m.month != selectedMonth {
                        Text(pacerCost(m.cost))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("\(longMonth(m.month))")
                .accessibilityValue(pacerCost(m.cost))
            }
            // Selection callout moved to the card header so the chart
            // doesn't reflow on hover. Just keep a thin dashed rule
            // to mark the selected bar.
            if selectedMonth != nil,
               let m = selectedMonth,
               monthly.contains(where: { $0.month == m }) {
                RuleMark(x: .value("Selected", m))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
        }
        .frame(height: 220)
        .chartXSelection(value: $selectedMonth)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.18))
                AxisValueLabel {
                    if let d = value.as(Double.self) {
                        Text(pacerCost(d))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let m = value.as(String.self) {
                        Text(shortMonth(m))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityLabel("Cost by month for the last 12 months")
    }

    /// `2026-04` → `Apr` (or `Apr '26` when the visible window straddles
    /// a year boundary). Previously this rendered as "Apr 26" which
    /// looked like the 26th of April rather than April 2026 — confusing
    /// when the cells are big.
    private func shortMonth(_ ym: String) -> String {
        guard ym.count == 7,
              let yearInt = Int(ym.prefix(4)),
              let monthInt = Int(ym.suffix(2))
        else { return ym }
        let names = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
        guard monthInt >= 1 && monthInt <= 12 else { return ym }
        let yearsInWindow = Set(monthly.map { String($0.month.prefix(4)) }).count
        if yearsInWindow > 1 {
            return "\(names[monthInt - 1]) ’\(String(format: "%02d", yearInt % 100))"
        }
        return names[monthInt - 1]
    }

    private func longMonth(_ ym: String) -> String {
        guard ym.count == 7,
              let yearInt = Int(ym.prefix(4)),
              let monthInt = Int(ym.suffix(2))
        else { return ym }
        let names = ["January","February","March","April","May","June","July","August","September","October","November","December"]
        guard monthInt >= 1 && monthInt <= 12 else { return ym }
        return "\(names[monthInt - 1]) \(yearInt)"
    }
}

// MARK: - Top days

enum TopDaysSort: String, CaseIterable, Identifiable {
    case date, tokens, cost
    var id: String { rawValue }
}

private struct TopDaysCard: View {
    let range: TimeRange
    let onDayTap: (String) -> Void

    @AppStorage("pacer.history.topDaysSort", store: PacerSettings.store)
    private var sortRaw: String = TopDaysSort.cost.rawValue
    @AppStorage("pacer.history.topDaysSortDescending", store: PacerSettings.store)
    private var descending: Bool = true

    private var sort: TopDaysSort { TopDaysSort(rawValue: sortRaw) ?? .cost }
    private var sortBinding: Binding<TopDaysSort> {
        Binding(get: { sort }, set: { sortRaw = $0.rawValue })
    }

    var body: some View {
        // The `.id()` value is prefixed per-card so it can't collide
        // with LifetimeSummary's own `.id(range)` sibling. See the
        // matching comment on LifetimeSummaryCard for why.
        TopDaysContent(
            range: range,
            sort: sort,
            descending: descending,
            onDayTap: onDayTap,
            sortBinding: sortBinding,
            descendingBinding: $descending
        )
        .id("top-days-\(range.rawValue)")
    }
}

private struct TopDaysContent: View {
    let range: TimeRange
    let sort: TopDaysSort
    let descending: Bool
    let onDayTap: (String) -> Void
    let sortBinding: Binding<TopDaysSort>
    let descendingBinding: Binding<Bool>

    @Query private var aggregates: [DailyAggregate]

    init(
        range: TimeRange,
        sort: TopDaysSort,
        descending: Bool,
        onDayTap: @escaping (String) -> Void,
        sortBinding: Binding<TopDaysSort>,
        descendingBinding: Binding<Bool>
    ) {
        self.range = range
        self.sort = sort
        self.descending = descending
        self.onDayTap = onDayTap
        self.sortBinding = sortBinding
        self.descendingBinding = descendingBinding
        if let since = range.since {
            let cutoffString = TokenSample.formatDate(since)
            _aggregates = Query(
                filter: #Predicate<DailyAggregate> { $0.date >= cutoffString },
                sort: \DailyAggregate.date,
                order: .reverse
            )
        } else {
            _aggregates = Query(
                sort: \DailyAggregate.date, order: .reverse
            )
        }
    }

    /// Toggle to reveal the next 90 (showing top 100). The user flagged
    /// "showing top 10 silently" — now there's a chip in the header
    /// indicating "showing N of M" plus a Show more / Show less link.
    @State private var showAll: Bool = false

    private struct DayRow: Identifiable {
        let date: String
        let cost: Double
        let tokens: Int64
        var id: String { date }
    }

    /// Days inside the active range, sorted by the user's chosen
    /// field. Computed per body fire from the range-scoped `@Query` —
    /// the previous `@State`-cached design populated on `.onAppear`,
    /// which fires AFTER first body and made every `.id(range)` re-init
    /// flash an empty list. The walk is O(aggregates) over a scoped
    /// slice (≤ ~5k rows even on .all); HoverRow lives inside each row
    /// so the parent body doesn't re-fire on row hover.
    private var sortedRows: [DayRow] {
        var byDate: [String: (cost: Double, tokens: Int64)] = [:]
        for row in aggregates {
            var v = byDate[row.date] ?? (0, 0)
            v.cost += row.totalCostUSD
            v.tokens += row.inputTokens + row.outputTokens
            byDate[row.date] = v
        }
        let rows = byDate.map { DayRow(date: $0.key, cost: $0.value.cost, tokens: $0.value.tokens) }
        let sorted: [DayRow]
        switch sort {
        case .date:
            sorted = rows.sorted { $0.date < $1.date }
        case .tokens:
            sorted = rows.sorted { $0.tokens < $1.tokens }
        case .cost:
            sorted = rows.sorted { $0.cost < $1.cost }
        }
        return descending ? sorted.reversed() : Array(sorted)
    }

    private var title: String {
        switch sort {
        case .cost:    return "Most expensive days"
        case .tokens:  return "Heaviest token days"
        case .date:    return descending ? "Most recent days" : "Earliest days"
        }
    }

    var body: some View {
        let all = sortedRows
        let visible: [DayRow] = showAll
            ? Array(all.prefix(min(all.count, 100)))
            : Array(all.prefix(10))
        return PacerCard(title, trailing: {
            if !all.isEmpty {
                Text("showing \(visible.count) of \(all.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }) {
            if all.isEmpty {
                Text("No data yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                let maxCost = visible.map(\.cost).max() ?? 1
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) {
                        // Empty rank column header
                        Spacer().frame(width: 28)
                        SortableColumnHeader(
                            "Date",
                            field: TopDaysSort.date,
                            alignment: .leading,
                            active: sortBinding,
                            descending: descendingBinding,
                            defaultDescending: false
                        ).frame(width: 140, alignment: .leading)
                        Spacer()
                        SortableColumnHeader(
                            "Tokens",
                            field: TopDaysSort.tokens,
                            alignment: .trailing,
                            active: sortBinding,
                            descending: descendingBinding
                        ).frame(width: 80)
                        SortableColumnHeader(
                            "Cost",
                            field: TopDaysSort.cost,
                            alignment: .trailing,
                            active: sortBinding,
                            descending: descendingBinding
                        ).frame(width: 80)
                        // Reserve space for the row's chevron column.
                        Spacer().frame(width: 16)
                    }
                    Divider().padding(.vertical, 2)
                    // Lazy inner stack so the "Show top 100" expansion
                    // doesn't realize all 100 `HoverRow`s + context
                    // menus at once. Same pattern applied to
                    // `ProjectsView`'s row list — defers off-screen
                    // rows until scrolled into view.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { idx, row in
                            topRow(idx: idx, row: row, maxCost: maxCost)
                        }
                    }
                    if all.count > 10 {
                        HStack {
                            Spacer()
                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    showAll.toggle()
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(showAll ? "Show top 10" : "Show top 100")
                                    Image(systemName: showAll ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 9, weight: .semibold))
                                }
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.tint)
                            }
                            .buttonStyle(.plain)
                            Spacer()
                        }
                        .padding(.top, 8)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func topRow(idx: Int, row: DayRow, maxCost: Double) -> some View {
        HoverRow(action: { onDayTap(row.date) }) {
            HStack(alignment: .center, spacing: 12) {
                Text("#\(idx + 1)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, alignment: .leading)
                Text(prettyDate(row.date))
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 140, alignment: .leading)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 6)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.accentColor.opacity(0.85))
                            .frame(
                                width: geo.size.width * CGFloat(row.cost / max(maxCost, 0.0001)),
                                height: 6
                            )
                    }
                    .frame(height: 6)
                }
                Text(pacerTokens(row.tokens))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 80, alignment: .trailing)
                Text(pacerCost(row.cost))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 80, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, alignment: .trailing)
            }
        }
        .contextMenu {
            Button("Open day") { onDayTap(row.date) }
            Divider()
            Button("Copy date") { pacerCopyToPasteboard(row.date) }
            Button("Copy cost") { pacerCopyToPasteboard(pacerCost(row.cost)) }
        }
    }

    /// `2026-04-30` → `Thu Apr 30`. Compact + day-of-week so the user
    /// can spot patterns ("oh I always burn on Wednesdays"). The two
    /// `DateFormatter` instances are now static — previously this
    /// function allocated both per call, and `topRow` calls it for
    /// every row on every render. With up to 100 visible rows under
    /// "Show top 100" plus context-menu re-evaluations, that was
    /// thousands of allocations per scroll.
    private static let prettyDateInFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()
    private static let prettyDateOutFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d"
        f.timeZone = .current
        return f
    }()

    private func prettyDate(_ ymd: String) -> String {
        guard let d = Self.prettyDateInFmt.date(from: ymd) else { return ymd }
        return Self.prettyDateOutFmt.string(from: d)
    }
}
