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

    @AppStorage("pacer.models.metric", store: PacerSettings.store)
    private var metricRaw: String = ModelMetric.tokens.rawValue
    @AppStorage("pacer.models.grouping", store: PacerSettings.store)
    private var groupingRaw: String = ModelGrouping.none.rawValue

    private var metric: ModelMetric { ModelMetric(rawValue: metricRaw) ?? .tokens }
    private var grouping: ModelGrouping { ModelGrouping(rawValue: groupingRaw) ?? .none }
    private var metricBinding: Binding<ModelMetric> {
        Binding(get: { metric }, set: { metricRaw = $0.rawValue })
    }
    private var groupingBinding: Binding<ModelGrouping> {
        Binding(get: { grouping }, set: { groupingRaw = $0.rawValue })
    }

    var body: some View {
        PageScaffold(
            "Models",
            subtitle: "How traffic splits across Claude models.",
            trailing: {
                // Page-header controls scope every card on the tab (Token
                // share, Trend, the list): group-by folds versions together,
                // the range picker windows the data. The donut's metric
                // (tokens/cost) lives on its own card header, like Projects.
                HStack(spacing: 10) {
                    Picker("Group by", selection: groupingBinding) {
                        ForEach(ModelGrouping.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 132)
                    .controlSize(.small)
                    .labelsHidden()
                    Picker("Time range", selection: rangeBinding) {
                        ForEach(TimeRange.allCases) { r in
                            Text(r.shortLabel).tag(r)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                    .controlSize(.small)
                    .labelsHidden()
                }
            }
        ) {
            ModelsContent(
                range: range,
                sort: sort,
                descending: sortDescending,
                metric: metric,
                grouping: grouping,
                rangeBinding: rangeBinding,
                sortFieldBinding: sortFieldBinding,
                sortDescendingBinding: $sortDescending,
                metricBinding: metricBinding,
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

/// Which metric sizes the share donut (mirrors ProjectsView's overview
/// metric). Sessions-per-model isn't offered: unlike projects, our per-model
/// rollup carries no session count, and the only proxy (a session's single
/// dominant model) would misattribute mixed-model sessions.
enum ModelMetric: String, CaseIterable, Identifiable {
    case tokens
    case cost

    var id: String { rawValue }
    var label: String { self == .cost ? "Cost" : "Tokens" }
}

/// How the Models tab buckets rows. `.none` is one row per model, colored by
/// the blend palette. Grouping folds versions together and switches to
/// well-separated *hashed* colors — a few groups don't need (and read better
/// without) the within-family spectrum, which is what makes 4.7 vs 4.8 pop
/// once collapsed into "Opus" or "Opus 4".
enum ModelGrouping: String, CaseIterable, Identifiable {
    case none
    case family

    var id: String { rawValue }
    var label: String {
        switch self {
        case .none:   return "Model"
        case .family: return "Class"
        }
    }

    /// Bucket key + display label for a raw model id under this grouping.
    /// Unparseable ids fall back to the per-model form.
    func bucket(_ model: String) -> (key: String, label: String) {
        let id = PacerModelIdentity(model)
        switch self {
        case .none:
            return (model, pacerModelDisplayName(model))
        case .family:
            if let f = id.family { return (f.rawValue, f.label) }
        }
        return (model, pacerModelDisplayName(model))
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
    let metric: ModelMetric
    let grouping: ModelGrouping
    let rangeBinding: Binding<TimeRange>
    let sortFieldBinding: Binding<ModelsSort>
    let sortDescendingBinding: Binding<Bool>
    let metricBinding: Binding<ModelMetric>
    /// Callback to the page-level modal navigator when a chart bar
    /// is tapped — opens that day's day-detail modal.
    let onSelectDay: (String) -> Void

    /// Bundle the four derived views into a single cache. Populated
    /// via `.onAppear` / `.onChange` on scan tick / sort. Body falls
    /// back to a synchronous compute when the cache is nil — so the
    /// first render after a `.id(range)` re-init never flashes empty
    /// while waiting for `.onAppear` to fire. Hover-driven body
    /// re-fires (donut angle, chart selection) skip the recompute
    /// because the cache is populated by then.
    @State private var cachedDerived: DerivedData?

    init(
        range: TimeRange,
        sort: ModelsSort,
        descending: Bool,
        metric: ModelMetric,
        grouping: ModelGrouping,
        rangeBinding: Binding<TimeRange>,
        sortFieldBinding: Binding<ModelsSort>,
        sortDescendingBinding: Binding<Bool>,
        metricBinding: Binding<ModelMetric>,
        onSelectDay: @escaping (String) -> Void
    ) {
        self.sort = sort
        self.descending = descending
        self.metric = metric
        self.grouping = grouping
        self.rangeBinding = rangeBinding
        self.sortFieldBinding = sortFieldBinding
        self.sortDescendingBinding = sortDescendingBinding
        self.metricBinding = metricBinding
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
        let key: String          // bucket identity (raw model id when ungrouped)
        let model: String        // raw id for copy; empty when this row is a group
        let displayName: String  // "Opus 4.7" / "Opus" / "Opus 4"
        let subtitle: String?    // raw id (ungrouped) or "N versions" (grouped)
        let color: Color
        let cost: Double
        let inputTokens: Int64
        let outputTokens: Int64
        let cacheReadTokens: Int64
        let totalTokens: Int64
        let activeDays: Int
        let firstSeen: String
        let lastSeen: String
        var id: String { key }
    }

    private struct DailyMix: Identifiable {
        let date: String
        let model: String
        let displayName: String
        let tokens: Int64
        var id: String { "\(date)|\(model)" }
    }

    private struct DerivedData {
        var rows: [ModelRow] = []
        var dailyMix: [DailyMix] = []
        var trendBuckets: [String: [(model: String, tokens: Int64)]] = [:]
        var shareCumulative: [(row: ModelRow, max: Double)] = []
    }

    /// What body reads. Resolves to the cached snapshot when populated,
    /// otherwise computes synchronously — the latter is the path the
    /// first render after a `.id(range)` re-init takes, so the page
    /// shows real data immediately instead of flashing empty before
    /// `.onAppear` can populate the cache.
    private var derived: DerivedData {
        cachedDerived ?? computeDerived()
    }

    private var rows: [ModelRow] { derived.rows }
    private var dailyMix: [DailyMix] { derived.dailyMix }

    private func refreshDerived() {
        cachedDerived = computeDerived()
    }

    /// Pure computation over `aggregates` + `sort` + `descending`.
    /// Called both from `refreshDerived` (writes to `@State`) and from
    /// the `derived` fallback when the cache hasn't landed yet. Body
    /// invokes `derived` once via a `let`, so even the fallback path
    /// only walks `aggregates` once per body fire.
    private func computeDerived() -> DerivedData {
        struct Acc {
            var label: String = ""
            var members: Set<String> = []
            var cost: Double = 0
            var input: Int64 = 0
            var output: Int64 = 0
            var cacheRead: Int64 = 0
            var dates: Set<String> = []
            var firstSeen: String = "9999-99-99"
            var lastSeen: String = "0000-00-00"
        }
        // Fold rows into buckets — one per model when ungrouped, else per
        // class / per major version.
        var byKey: [String: Acc] = [:]
        for r in aggregates {
            let b = grouping.bucket(r.model)
            var a = byKey[b.key] ?? Acc()
            a.label = b.label
            a.members.insert(r.model)
            a.cost += r.totalCostUSD
            a.input += r.inputTokens
            a.output += r.outputTokens
            a.cacheRead += r.cacheReadTokens
            a.dates.insert(r.date)
            if r.date < a.firstSeen { a.firstSeen = r.date }
            if r.date > a.lastSeen { a.lastSeen = r.date }
            byKey[b.key] = a
        }
        let ungrouped = grouping == .none
        let unsorted = byKey.map { (key, a) -> ModelRow in
            ModelRow(
                key: key,
                model: ungrouped ? key : "",
                displayName: a.label,
                subtitle: ungrouped
                    ? key
                    : "\(a.members.count) version\(a.members.count == 1 ? "" : "s")",
                color: colorFor(a.label),
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
        // Stable tiebreaker on the bucket key so equal-value rows don't
        // reshuffle each refresh.
        let sorted = unsorted.sorted { lhs, rhs in
            if primary(lhs, rhs) { return true }
            if primary(rhs, lhs) { return false }
            return lhs.key < rhs.key
        }
        let rows: [ModelRow] = descending ? sorted.reversed() : sorted

        // Share-donut cumulative-angle table, sized by the chosen metric so a
        // per-hover `body` doesn't have to walk it.
        var running = 0.0
        var cumulative: [(row: ModelRow, max: Double)] = []
        cumulative.reserveCapacity(rows.count)
        for r in rows {
            running += metricValue(r)
            cumulative.append((r, running))
        }

        // Daily token mix, folded by the grouping so each (day, group) is one
        // stacked segment rather than one-per-model.
        struct DayKey: Hashable { let date: String; let key: String }
        var mix: [DayKey: (label: String, tokens: Int64)] = [:]
        for r in aggregates {
            let b = grouping.bucket(r.model)
            let dk = DayKey(date: r.date, key: b.key)
            var e = mix[dk] ?? (label: b.label, tokens: Int64(0))
            e.tokens += r.inputTokens + r.outputTokens
            mix[dk] = e
        }
        // `mix` is a Dictionary, so `.map` yields hash order. The trend
        // chart plots a categorical (String) x-axis, whose band order Swift
        // Charts takes from the order rows first appear here — and
        // `pacerDateAxis` assumes that band domain is chronological. Sort by
        // date (then group key) so the axis, its labels, and the bars stay
        // in a stable calendar order instead of reshuffling every time a
        // background refresh rebuilds the dictionary.
        let dailyMix: [DailyMix] = mix
            .map { (dk, v) in
                DailyMix(date: dk.date, model: dk.key, displayName: v.label, tokens: v.tokens)
            }
            .sorted { $0.date != $1.date ? $0.date < $1.date : $0.model < $1.model }
        var buckets: [String: [(model: String, tokens: Int64)]] = [:]
        for entry in dailyMix {
            buckets[entry.date, default: []].append(
                (model: entry.displayName, tokens: entry.tokens)
            )
        }
        for key in buckets.keys {
            buckets[key]?.sort { $0.tokens > $1.tokens }
        }

        return DerivedData(
            rows: rows,
            dailyMix: dailyMix,
            trendBuckets: buckets,
            shareCumulative: cumulative
        )
    }

    /// The metric that sizes the donut for a row.
    private func metricValue(_ row: ModelRow) -> Double {
        metric == .cost ? row.cost : Double(row.totalTokens)
    }
    /// Compact metric label / exact tooltip for legends + hover readouts.
    private func metricLabel(_ row: ModelRow) -> String {
        metric == .cost ? pacerCost(row.cost) : pacerTokens(row.totalTokens)
    }
    private func metricHelp(_ row: ModelRow) -> String {
        metric == .cost ? pacerCostExact(row.cost) : pacerTokensExact(row.totalTokens)
    }
    /// Color for a slice/label. Ungrouped uses the curated blend palette; a
    /// class-grouped view uses each family's class-center color, so a class
    /// reads the same color it does in the per-model view (and stays on the
    /// well-separated ~90°-apart class anchors).
    private func colorFor(_ label: String) -> Color {
        switch grouping {
        case .none:
            return pacerModelColor(label)
        case .family:
            if let f = PacerModelIdentity(label).family {
                return PacerModelPalette.classColor(f)
            }
            return pacerGeneratedColor(label)
        }
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
        .onChange(of: metric) { _, _ in refreshDerived() }
        .onChange(of: grouping) { _, _ in refreshDerived() }
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
    /// once in `computeDerived` alongside the per-model rollup.
    private var shareCumulative: [(row: ModelRow, max: Double)] {
        derived.shareCumulative
    }

    private var shareTotal: Double {
        rows.reduce(0) { $0 + metricValue($1) }
    }

    /// VoiceOver summary read in place of the donut. Lists the top 5
    /// rows with their share percentage so screen-reader users get the
    /// same info sighted users get from wedges + legend.
    private var shareSummary: String {
        let total = shareTotal
        guard total > 0 else { return "no data yet" }
        return rows.prefix(5).map { r in
            let pct = Int(metricValue(r) / total * 100)
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
        let total = shareTotal
        let title = metric == .cost ? "Cost share" : "Token share"
        return PacerCard(title, trailing: {
            HStack(spacing: 10) {
                if let r = hoveredShareRow {
                    let pct = total > 0 ? Int(metricValue(r) / total * 100) : 0
                    HStack(spacing: 6) {
                        Text(r.displayName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(metricLabel(r)).help(metricHelp(r))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("(\(pct)%)")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                Picker("Metric", selection: metricBinding) {
                    ForEach(ModelMetric.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 132)
                .controlSize(.small)
                .labelsHidden()
            }
        }) {
            HStack(alignment: .top, spacing: 24) {
                PacerDonut(
                    slices: rows.map {
                        PacerDonutSlice(id: $0.key, value: metricValue($0), color: $0.color)
                    },
                    size: 180,
                    hoveredID: hoveredShareRow?.key,
                    hoveredAngle: $hoveredShareAngle,
                    accessibilityLabel: "\(title) across models",
                    accessibilityValue: shareSummary
                )
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rows.prefix(8)) { row in
                        PacerDonutLegendRow(
                            color: row.color,
                            label: row.displayName
                        ) {
                            Text(metricLabel(row)).help(metricHelp(row))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(width: 90, alignment: .trailing)
                            if total > 0 {
                                Text("\(Int(metricValue(row) / total * 100))%")
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

    /// Debounced hover (chart RuleMark + per-day breakdown reads). Updated
    /// from `rawTrendHoverDate` only once the pointer settles, so a scroll
    /// sweeping the bars doesn't re-lay-out the chart per pointer event.
    /// See docs/perf-tuning.md.
    @State private var trendHoverDate: String?
    /// Raw `chartXSelection` binding (immediate); feeds the debounce + tap.
    @State private var rawTrendHoverDate: String?
    @State private var trendHoverDebounce: Task<Void, Never>?

    /// Per-day, per-model totals for the hovered date. O(1) lookup
    /// into the pre-bucketed `trendBuckets` — the previous version
    /// did filter+sort+map on every hover tick.
    private var hoveredTrendDay: (date: String, slices: [(model: String, tokens: Int64)])? {
        guard let h = trendHoverDate,
              let slices = derived.trendBuckets[h],
              !slices.isEmpty
        else { return nil }
        return (h, slices)
    }

    /// Distinct model names in the trend, sorted for a stable
    /// color-scale domain so the pinned per-model colors (and the Charts
    /// legend) don't reshuffle between renders.
    private var trendModelDomain: [String] {
        Array(Set(dailyMix.map(\.displayName))).sorted()
    }

    private var trendCard: some View {
        let trendAxis = pacerDateAxis(dailyMix.map(\.date))
        return PacerCard("Trend", trailing: {
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
                        .help("\(pacerTokensExact(total)) tokens")
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
                .chartForegroundStyleScale(
                    domain: trendModelDomain,
                    range: trendModelDomain.map { colorFor($0) }
                )
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.18))
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(pacerTokens(Int64(v))).help(pacerTokensExact(Int64(v)))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: trendAxis.values) { value in
                        AxisValueLabel {
                            if let date = value.as(String.self) {
                                Text(trendAxis.label(date))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .chartXSelection(value: $rawTrendHoverDate)
                .onChange(of: rawTrendHoverDate) { _, newValue in
                    trendHoverDebounce?.cancel()
                    trendHoverDebounce = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(40))
                        guard !Task.isCancelled else { return }
                        trendHoverDate = newValue
                    }
                }
                // Tap-to-drill — uses the chartXSelection binding,
                // same minimal pattern as DailyCostChartCard. Arrow
                // cursor (default) per macOS HIG.
                .contentShape(Rectangle())
                .onTapGesture {
                    // Immediate selection, not the debounced one.
                    if let date = rawTrendHoverDate {
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
                                Text(pacerTokens(s.tokens)).help(pacerTokensExact(s.tokens))
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
        // Range picker moved to the page header (it scopes the whole tab,
        // not just this list) — see `ModelsView.body`.
        PacerCard("All models") {
            VStack(alignment: .leading, spacing: 0) {
                tableHeader
                Divider().padding(.vertical, 4)
                ForEach(rows) { row in
                    modelRow(row)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .contextMenu {
                            if !row.model.isEmpty {
                                Button("Copy model name") { pacerCopyToPasteboard(row.model) }
                            }
                            Button("Copy display name") { pacerCopyToPasteboard(row.displayName) }
                            Divider()
                            // Copy precise dollars so a paste into a
                            // spreadsheet keeps full cents.
                            Button("Copy cost") { pacerCopyToPasteboard(pacerCostExact(row.cost)) }
                            Button("Copy token total") {
                                pacerCopyToPasteboard(pacerTokensExact(row.totalTokens))
                            }
                        }
                }
                HStack {
                    Text("\(rows.count) \(grouping == .none ? "model" : "group")\(rows.count == 1 ? "" : "s")")
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
                if let subtitle = row.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(pacerTokens(row.totalTokens)).help(pacerTokensExact(row.totalTokens))
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
            Text(pacerCost(row.cost)).help(pacerCostExact(row.cost))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 84, alignment: .trailing)
        }
    }
}
