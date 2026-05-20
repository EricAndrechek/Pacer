import SwiftUI
import SwiftData
import Charts
import PacerCore
import PacerUI

/// Per-model breakdown — analogous to ProjectsView but keyed on model
/// name. Useful for "is sonnet doing the bulk of work or am I always
/// reaching for opus?" / "did I switch off haiku 3 months ago?"
struct ModelsView: View {
    @AppStorage("pacer.models.range", store: PacerSettings.store)
    private var rangeRaw: String = TimeRange.ninetyDays.rawValue

    @AppStorage("pacer.models.sortField", store: PacerSettings.store)
    private var sortRaw: String = ModelsSort.cost.rawValue

    @AppStorage("pacer.models.sortDescending", store: PacerSettings.store)
    private var sortDescending: Bool = true

    @State private var modalRoot: PacerModalDestination?

    private var range: TimeRange { TimeRange(rawValue: rangeRaw) ?? .ninetyDays }
    private var sort: ModelsSort { ModelsSort(rawValue: sortRaw) ?? .cost }

    private var rangeBinding: Binding<TimeRange> {
        Binding(get: { range }, set: { rangeRaw = $0.rawValue })
    }
    private var sortFieldBinding: Binding<ModelsSort> {
        Binding(get: { sort }, set: { sortRaw = $0.rawValue })
    }

    var body: some View {
        PageScaffold("Models", subtitle: "How traffic splits across Claude models.") {
            ModelsContent(
                range: range,
                sort: sort,
                descending: sortDescending,
                rangeBinding: rangeBinding,
                sortFieldBinding: sortFieldBinding,
                sortDescendingBinding: $sortDescending,
                onSelectDay: { date in
                    modalRoot = .day(date: date)
                }
            )
            .id(range)
        }
        .pacerModalNavigation(root: $modalRoot)
    }
}

enum ModelsSort: String, CaseIterable, Identifiable {
    case name
    case tokens
    case days
    case lastSeen
    case cost

    var id: String { rawValue }
    var label: String {
        switch self {
        case .name:     return "Model"
        case .tokens:   return "Tokens"
        case .days:     return "Days"
        case .lastSeen: return "Last seen"
        case .cost:     return "Cost"
        }
    }
}

private struct ModelsContent: View {
    @Query private var aggregates: [DailyAggregate]
    /// Singleton-row probe that fires exactly once per completed scan
    /// cycle. Drives the cache refresh below so the O(aggregates)
    /// rollup runs at most once per cycle instead of once per body
    /// render (hover-driven re-renders on the donut were doing it on
    /// every mouse move pre-cache).
    @Query(ScanMetaFetchDescriptor.scanCompletedProbe)
    private var scanMeta: [ClaudeCodeMeta]

    let sort: ModelsSort
    let descending: Bool
    let rangeBinding: Binding<TimeRange>
    let sortFieldBinding: Binding<ModelsSort>
    let sortDescendingBinding: Binding<Bool>
    /// Callback to the page-level modal navigator when a chart bar
    /// is tapped — opens that day's day-detail modal.
    let onSelectDay: (String) -> Void

    /// Cached per-model rollup. Recomputed in `refreshDerived` on
    /// scan-meta tick, sort change, or appear — not on every body
    /// render. The trade-off vs. the previous "always compute" pattern:
    /// a tab switch into Models renders an empty grid for ~1 frame
    /// before `.onAppear` populates the cache. Worth it: pre-cache,
    /// every hover on the donut re-walked the `aggregates` array.
    @State private var cachedRows: [ModelRow] = []
    /// Same cache treatment for the trend chart's per-(date, model)
    /// flat list. Cheap to recompute (just a `.map`) but adds up when
    /// it fires on every render of the trend card.
    @State private var cachedDailyMix: [DailyMix] = []
    /// Pre-bucketed `[date: [(model, tokens)] sorted desc]` lookup so
    /// `hoveredTrendDay` is an O(1) dict access instead of an O(N)
    /// `filter().sorted().map()` walk over `dailyMix`. The walk fired
    /// on every chart-hover tick — when the user dragged across the
    /// bar chart, that was a re-walk per mouse-move sample.
    @State private var cachedTrendBuckets: [String: [(model: String, tokens: Int64)]] = [:]
    /// Cached cumulative-angle table for the share donut. Small N,
    /// but rebuilt on every chart-hover-induced re-render; trivial
    /// to cache alongside `cachedRows`.
    @State private var cachedShareCumulative: [(row: ModelRow, max: Double)] = []

    init(
        range: TimeRange,
        sort: ModelsSort,
        descending: Bool,
        rangeBinding: Binding<TimeRange>,
        sortFieldBinding: Binding<ModelsSort>,
        sortDescendingBinding: Binding<Bool>,
        onSelectDay: @escaping (String) -> Void
    ) {
        self.sort = sort
        self.descending = descending
        self.rangeBinding = rangeBinding
        self.sortFieldBinding = sortFieldBinding
        self.sortDescendingBinding = sortDescendingBinding
        self.onSelectDay = onSelectDay
        if let days = range.days {
            let cutoffString = TokenSample.formatDate(
                Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast
            )
            _aggregates = Query(
                filter: #Predicate<DailyAggregate> { $0.date >= cutoffString },
                sort: \.date
            )
        } else {
            _aggregates = Query(sort: \DailyAggregate.date)
        }
    }

    private struct ModelRow: Identifiable {
        let model: String
        let displayName: String
        let cost: Double
        let inputTokens: Int64
        let outputTokens: Int64
        let cacheReadTokens: Int64
        let totalTokens: Int64
        let activeDays: Int
        let firstSeen: String
        let lastSeen: String
        var id: String { model }
    }

    private struct DailyMix: Identifiable {
        let date: String
        let model: String
        let displayName: String
        let tokens: Int64
        var id: String { "\(date)|\(model)" }
    }

    private var rows: [ModelRow] { cachedRows }
    private var dailyMix: [DailyMix] { cachedDailyMix }

    /// Rebuild `cachedRows` (per-model rollup + sort) and
    /// `cachedDailyMix` (per-day flat list for the trend chart) from
    /// the current `aggregates` snapshot. Called on appear, scan-meta
    /// tick, and whenever sort/direction changes. O(aggregates) — used
    /// to run on every body render which compounded with every chart
    /// hover.
    private func refreshDerived() {
        struct Acc {
            var cost: Double = 0
            var input: Int64 = 0
            var output: Int64 = 0
            var cacheRead: Int64 = 0
            var dates: Set<String> = []
            var firstSeen: String = "9999-99-99"
            var lastSeen: String = "0000-00-00"
        }
        var byModel: [String: Acc] = [:]
        for r in aggregates {
            var a = byModel[r.model] ?? Acc()
            a.cost += r.totalCostUSD
            a.input += r.inputTokens
            a.output += r.outputTokens
            a.cacheRead += r.cacheReadTokens
            a.dates.insert(r.date)
            if r.date < a.firstSeen { a.firstSeen = r.date }
            if r.date > a.lastSeen { a.lastSeen = r.date }
            byModel[r.model] = a
        }
        let unsorted = byModel.map { (model, a) in
            ModelRow(
                model: model,
                displayName: pacerShortModel(model),
                cost: a.cost,
                inputTokens: a.input,
                outputTokens: a.output,
                cacheReadTokens: a.cacheRead,
                totalTokens: a.input + a.output + a.cacheRead,
                activeDays: a.dates.count,
                firstSeen: a.firstSeen,
                lastSeen: a.lastSeen
            )
        }
        let primary: (ModelRow, ModelRow) -> Bool
        switch sort {
        case .name:
            primary = { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .tokens:
            primary = { $0.totalTokens < $1.totalTokens }
        case .days:
            primary = { $0.activeDays < $1.activeDays }
        case .lastSeen:
            primary = { $0.lastSeen < $1.lastSeen }
        case .cost:
            primary = { $0.cost < $1.cost }
        }
        // Stable tiebreaker on the model identifier so rows with equal
        // primary values don't reshuffle each refresh.
        let sorted = unsorted.sorted { lhs, rhs in
            if primary(lhs, rhs) { return true }
            if primary(rhs, lhs) { return false }
            return lhs.model < rhs.model
        }
        cachedRows = descending ? sorted.reversed() : sorted

        // Pre-build the share donut's cumulative-angle table here so
        // the per-hover `body` doesn't have to.
        var running = 0.0
        var cumulative: [(row: ModelRow, max: Double)] = []
        cumulative.reserveCapacity(cachedRows.count)
        for r in cachedRows {
            running += Double(r.totalTokens)
            cumulative.append((r, running))
        }
        cachedShareCumulative = cumulative

        cachedDailyMix = aggregates.map {
            DailyMix(
                date: $0.date,
                model: $0.model,
                displayName: pacerShortModel($0.model),
                tokens: $0.inputTokens + $0.outputTokens
            )
        }
        // Bucket dailyMix by date once so the trend-chart hover
        // tooltip is an O(1) lookup. Per-date entries are pre-sorted
        // by tokens descending — same order the previous computed
        // property produced.
        var buckets: [String: [(model: String, tokens: Int64)]] = [:]
        for entry in cachedDailyMix {
            buckets[entry.date, default: []].append(
                (model: entry.displayName, tokens: entry.tokens)
            )
        }
        for key in buckets.keys {
            buckets[key]?.sort { $0.tokens > $1.tokens }
        }
        cachedTrendBuckets = buckets
    }

    var body: some View {
        Group {
            if rows.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: PacerDesign.sectionSpacing) {
                    shareCard
                    trendCard
                    listCard
                }
            }
        }
        // Cache refresh triggers — see `refreshDerived` for what runs.
        // Hover events on charts / table rows no longer cause the
        // O(aggregates) rollup to re-run.
        .onAppear { refreshDerived() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshDerived() }
        .onChange(of: sort) { _, _ in refreshDerived() }
        .onChange(of: descending) { _, _ in refreshDerived() }
    }

    private var emptyState: some View {
        PacerCard {
            Text("No model activity in the selected range.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    @State private var hoveredShareAngle: Double?

    /// Sorted-by-cumulative-angle table for the share donut. Built
    /// once in `refreshDerived` alongside the per-model rollup.
    private var shareCumulative: [(row: ModelRow, max: Double)] {
        cachedShareCumulative
    }

    private var shareTotalTokens: Int64 {
        rows.reduce(0) { $0 + $1.totalTokens }
    }

    /// VoiceOver summary read in place of the donut. Lists the top 5
    /// models with their token-share percentage so screen-reader users
    /// get the same info sighted users get from wedges + legend.
    private var shareSummary: String {
        let total = shareTotalTokens
        guard total > 0 else { return "no data yet" }
        return rows.prefix(5).map { r in
            let pct = Int(Double(r.totalTokens) / Double(total) * 100)
            return "\(r.displayName) \(pct) percent"
        }.joined(separator: ", ")
    }

    private var hoveredShareRow: ModelRow? {
        let cumulative = shareCumulative
        guard let angle = hoveredShareAngle, !cumulative.isEmpty else { return nil }
        // Linear scan over a precomputed table; cheap because N is
        // small (handful of models). Could binary-search but the
        // wins don't show up at this size.
        for entry in cumulative where angle <= entry.max {
            return entry.row
        }
        return cumulative.last?.row
    }

    private var shareCard: some View {
        let total = shareTotalTokens
        return PacerCard("Token share", trailing: {
            if let r = hoveredShareRow {
                let pct = total > 0 ? Int(Double(r.totalTokens) / Double(total) * 100) : 0
                HStack(spacing: 6) {
                    Text(r.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(pacerTokens(r.totalTokens))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("(\(pct)%)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }) {
            HStack(alignment: .top, spacing: 24) {
                Chart(rows) { r in
                    SectorMark(
                        angle: .value("Tokens", r.totalTokens),
                        innerRadius: .ratio(0.6),
                        angularInset: 1.5
                    )
                    .foregroundStyle(by: .value("Model", r.displayName))
                    .cornerRadius(2)
                    .opacity(hoveredShareRow.map { $0.id == r.id ? 1.0 : 0.45 } ?? 1.0)
                }
                .frame(width: 180, height: 180)
                .chartLegend(.hidden)
                .chartAngleSelection(value: $hoveredShareAngle)
                .accessibilityLabel("Token share across models")
                .accessibilityValue(shareSummary)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rows.prefix(8)) { row in
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.displayName)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(pacerTokens(row.totalTokens))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(width: 90, alignment: .trailing)
                            if total > 0 {
                                Text("\(Int(Double(row.totalTokens) / Double(total) * 100))%")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .monospacedDigit()
                                    .frame(width: 40, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
    }

    @State private var trendHoverDate: String?

    /// Per-day, per-model totals for the hovered date. O(1) lookup
    /// into the pre-bucketed `cachedTrendBuckets` — the previous
    /// version did filter+sort+map on every hover tick.
    private var hoveredTrendDay: (date: String, slices: [(model: String, tokens: Int64)])? {
        guard let h = trendHoverDate,
              let slices = cachedTrendBuckets[h],
              !slices.isEmpty
        else { return nil }
        return (h, slices)
    }

    private var trendCard: some View {
        PacerCard("Trend", trailing: {
            // Hover swaps the trailing slot for the date + total tokens.
            // Detail per-model breakdown shows below the chart on hover
            // — same overlay-text pattern keeps the chart geometry
            // stable and gives a useful tooltip without a popup.
            if let hov = hoveredTrendDay {
                let total = hov.slices.reduce(Int64(0)) { $0 + $1.tokens }
                HStack(spacing: 8) {
                    Text(hov.date)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("\(pacerTokens(total)) tokens")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            }
        }) {
            VStack(alignment: .leading, spacing: 8) {
                Chart {
                    ForEach(dailyMix) { d in
                        BarMark(
                            x: .value("Date", d.date),
                            y: .value("Tokens", d.tokens)
                        )
                        .foregroundStyle(by: .value("Model", d.displayName))
                        .cornerRadius(1.5)
                    }
                    if let h = trendHoverDate, dailyMix.contains(where: { $0.date == h }) {
                        RuleMark(x: .value("Selected", h))
                            .foregroundStyle(.secondary.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    }
                }
                .frame(height: 200)
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.18))
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(pacerTokens(Int64(v)))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .chartXAxis(.hidden)
                .chartXSelection(value: $trendHoverDate)
                // Tap-to-drill — uses the chartXSelection binding,
                // same minimal pattern as DailyCostChartCard. Arrow
                // cursor (default) per macOS HIG.
                .contentShape(Rectangle())
                .onTapGesture {
                    if let date = trendHoverDate {
                        onSelectDay(date)
                    }
                }
                .accessibilityLabel("Daily token mix by model")
                .accessibilityHint("Click a bar to drill into that day")

                // Per-model breakdown of the hovered day. Hidden until
                // hover so the card doesn't always show a placeholder
                // row.
                if let hov = hoveredTrendDay {
                    HStack(spacing: 16) {
                        ForEach(hov.slices.prefix(6), id: \.model) { s in
                            HStack(spacing: 5) {
                                Text(s.model)
                                    .font(.system(size: 11, weight: .medium))
                                Text(pacerTokens(s.tokens))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    private var listCard: some View {
        PacerCard("All models", trailing: {
            // Inline range picker — same "controls live next to the data
            // they scope" pattern as ProjectsView.
            Picker("Time range", selection: rangeBinding) {
                ForEach(TimeRange.allCases) { r in
                    Text(r.label).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 320)
            .controlSize(.small)
            .labelsHidden()
        }) {
            VStack(alignment: .leading, spacing: 0) {
                tableHeader
                Divider().padding(.vertical, 4)
                ForEach(rows) { row in
                    modelRow(row)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .contextMenu {
                            Button("Copy model name") { pacerCopyToPasteboard(row.model) }
                            Button("Copy display name") { pacerCopyToPasteboard(row.displayName) }
                            Divider()
                            Button("Copy cost") { pacerCopyToPasteboard(pacerCost(row.cost)) }
                            Button("Copy token total") {
                                pacerCopyToPasteboard(pacerTokens(row.totalTokens))
                            }
                        }
                }
                HStack {
                    Text("\(rows.count) model\(rows.count == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.top, 8)
            }
        }
    }

    private var tableHeader: some View {
        HStack {
            SortableColumnHeader(
                "Model",
                field: ModelsSort.name,
                alignment: .leading,
                active: sortFieldBinding,
                descending: sortDescendingBinding,
                defaultDescending: false
            )
            .padding(.leading, 8)
            Spacer()
            SortableColumnHeader(
                "Tokens",
                field: ModelsSort.tokens,
                alignment: .trailing,
                active: sortFieldBinding,
                descending: sortDescendingBinding
            ).frame(width: 100)
            SortableColumnHeader(
                "Days",
                field: ModelsSort.days,
                alignment: .trailing,
                active: sortFieldBinding,
                descending: sortDescendingBinding
            ).frame(width: 60)
            SortableColumnHeader(
                "Last seen",
                field: ModelsSort.lastSeen,
                alignment: .trailing,
                active: sortFieldBinding,
                descending: sortDescendingBinding
            ).frame(width: 100)
            SortableColumnHeader(
                "Cost",
                field: ModelsSort.cost,
                alignment: .trailing,
                active: sortFieldBinding,
                descending: sortDescendingBinding
            ).frame(width: 84)
        }
        .padding(.trailing, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func modelRow(_ row: ModelRow) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayName)
                    .font(.system(size: 13, weight: .medium))
                Text(row.model)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(pacerTokens(row.totalTokens))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 100, alignment: .trailing)
            Text("\(row.activeDays)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 60, alignment: .trailing)
            Text(row.lastSeen)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
            Text(pacerCost(row.cost))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 84, alignment: .trailing)
        }
    }
}
