import SwiftUI
import SwiftData
import Charts
import PacerCore

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
                sortDescendingBinding: $sortDescending
            )
            .id(range)
        }
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

    let sort: ModelsSort
    let descending: Bool
    let rangeBinding: Binding<TimeRange>
    let sortFieldBinding: Binding<ModelsSort>
    let sortDescendingBinding: Binding<Bool>

    init(
        range: TimeRange,
        sort: ModelsSort,
        descending: Bool,
        rangeBinding: Binding<TimeRange>,
        sortFieldBinding: Binding<ModelsSort>,
        sortDescendingBinding: Binding<Bool>
    ) {
        self.sort = sort
        self.descending = descending
        self.rangeBinding = rangeBinding
        self.sortFieldBinding = sortFieldBinding
        self.sortDescendingBinding = sortDescendingBinding
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

    private var rows: [ModelRow] {
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
        let sorted: [ModelRow]
        switch sort {
        case .name:
            sorted = unsorted.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .tokens:
            sorted = unsorted.sorted { $0.totalTokens < $1.totalTokens }
        case .days:
            sorted = unsorted.sorted { $0.activeDays < $1.activeDays }
        case .lastSeen:
            sorted = unsorted.sorted { $0.lastSeen < $1.lastSeen }
        case .cost:
            sorted = unsorted.sorted { $0.cost < $1.cost }
        }
        return descending ? sorted.reversed() : sorted
    }

    private var dailyMix: [DailyMix] {
        aggregates.map {
            DailyMix(
                date: $0.date,
                model: $0.model,
                displayName: pacerShortModel($0.model),
                tokens: $0.inputTokens + $0.outputTokens + $0.cacheReadTokens
            )
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
    }

    private var emptyState: some View {
        PacerCard {
            Text("No model activity in the selected range.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private var shareCard: some View {
        PacerCard("Token share") {
            HStack(alignment: .top, spacing: 24) {
                Chart(rows) { r in
                    SectorMark(
                        angle: .value("Tokens", r.totalTokens),
                        innerRadius: .ratio(0.6),
                        angularInset: 1.5
                    )
                    .foregroundStyle(by: .value("Model", r.displayName))
                    .cornerRadius(2)
                }
                .frame(width: 180, height: 180)
                .chartLegend(.hidden)
                VStack(alignment: .leading, spacing: 6) {
                    let total = rows.reduce(Int64(0)) { $0 + $1.totalTokens }
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

    private var trendCard: some View {
        PacerCard("Trend") {
            Chart(dailyMix) { d in
                BarMark(
                    x: .value("Date", d.date),
                    y: .value("Tokens", d.tokens)
                )
                .foregroundStyle(by: .value("Model", d.displayName))
                .cornerRadius(1.5)
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
        }
    }

    private var listCard: some View {
        PacerCard("All models", trailing: {
            // Inline range picker — same "controls live next to the data
            // they scope" pattern as ProjectsView.
            Picker("", selection: rangeBinding) {
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
