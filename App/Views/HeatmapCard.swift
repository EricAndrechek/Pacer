import SwiftUI
import SwiftData
import PacerCore

/// GitHub-contribution-style activity heatmap. Rows are days of the
/// week (Mon at top → Sun at bottom), columns are weeks, oldest on the
/// left and "this week" anchored on the right. Cell color intensity
/// tracks the user-selected metric (cost / tokens / sessions); clicking
/// a cell calls back so the parent view can drill into that day.
///
/// Spans 52 weeks (one year) by default — matches GitHub. The
/// 11×11 cells with 2pt gaps, and "Mon" / "Wed" / "Fri" weekday
/// labels at left were ported over after staring at the GitHub
/// reference screenshot side-by-side.
struct HeatmapCard: View {
    let weekCount: Int
    let onDayTap: (String) -> Void

    @Query(sort: \DailyAggregate.date, order: .reverse) private var aggregates: [DailyAggregate]
    @Query(HeatmapCard.scanMetaProbe) private var scanMeta: [ClaudeCodeMeta]
    @State private var cached = Cached()

    /// Persisted in App Group `UserDefaults` so the user's chosen
    /// coloring survives launches. Lives next to other view-state
    /// keys but is heatmap-specific (the projects view has its own
    /// `overviewMetric`).
    @AppStorage("pacer.heatmap.metric", store: PacerSettings.store)
    private var metricRaw: String = ProjectMetric.cost.rawValue

    private var metric: ProjectMetric {
        ProjectMetric(rawValue: metricRaw) ?? .cost
    }

    init(weekCount: Int = 52, onDayTap: @escaping (String) -> Void) {
        self.weekCount = weekCount
        self.onDayTap = onDayTap
    }

    private static let scanMetaProbe: FetchDescriptor<ClaudeCodeMeta> = {
        let key = ClaudeCodeMetaKey.lastIncrementalScanAt
        return FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key }
        )
    }()

    private struct Cell: Identifiable {
        let date: Date
        let dateKey: String
        let cost: Double
        let tokens: Int64
        let sessions: Int
        var id: String { dateKey }

        func value(for metric: ProjectMetric) -> Double {
            switch metric {
            case .cost:     return cost
            case .tokens:   return Double(tokens)
            case .sessions: return Double(sessions)
            }
        }
    }

    /// Pre-built grid + max-cap that the body reads from. Recomputed
    /// only when the underlying data changes (via `scanMeta` tick) so
    /// hover/scroll over the card don't re-iterate.
    private struct Cached {
        var grid: [[Cell?]] = []
        var maxByMetric: [ProjectMetric: Double] = [:]
        var totalsByMetric: [ProjectMetric: Double] = [:]
    }

    private var grid: [[Cell?]] { cached.grid }

    private func refreshCache() {
        // Sum per-day totals for all three metrics in one pass over
        // the daily aggregates. We also union session-id sets per day
        // so the heatmap's "sessions" metric is distinct-session
        // count rather than per-aggregate-row count.
        struct Acc {
            var cost: Double = 0
            var tokens: Int64 = 0
            var sessions: Set<String> = []
        }
        var byDate: [String: Acc] = [:]
        for row in aggregates {
            var a = byDate[row.date] ?? Acc()
            a.cost += row.totalCostUSD
            a.tokens += row.inputTokens + row.outputTokens + row.cacheReadTokens
            // DailyAggregate doesn't carry session IDs, so for the
            // heatmap's "sessions" tier we approximate via the per-row
            // (date, model) count. Good enough for visual ranking;
            // the real per-day distinct-session number lives on the
            // ProjectDailyAggregate table.
            a.sessions.insert("\(row.date)|\(row.model)")
            byDate[row.date] = a
        }

        let cal = Calendar(identifier: .iso8601)
        let today = cal.startOfDay(for: Date())
        guard let thisMonday = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today)),
              let firstMonday = cal.date(byAdding: .weekOfYear, value: -(weekCount - 1), to: thisMonday)
        else {
            cached = Cached()
            return
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"

        var weeks: [[Cell?]] = []
        for w in 0..<weekCount {
            var week: [Cell?] = []
            for d in 0..<7 {
                guard let day = cal.date(byAdding: .day, value: w * 7 + d, to: firstMonday) else {
                    week.append(nil); continue
                }
                if day > today {
                    week.append(nil); continue
                }
                let key = formatter.string(from: day)
                let acc = byDate[key] ?? Acc()
                week.append(Cell(
                    date: day, dateKey: key,
                    cost: acc.cost,
                    tokens: acc.tokens,
                    sessions: acc.sessions.count
                ))
            }
            weeks.append(week)
        }

        // 95th-percentile cap per metric so a single outlier doesn't
        // wash out the rest of the year. Same algorithm as before but
        // now run independently for each metric so switching metric
        // gives a usable color scale immediately.
        var maxByMetric: [ProjectMetric: Double] = [:]
        var totalsByMetric: [ProjectMetric: Double] = [:]
        for m in ProjectMetric.allCases {
            var values = weeks.flatMap { $0 }
                .compactMap { $0?.value(for: m) }
                .filter { $0 > 0 }
            totalsByMetric[m] = values.reduce(0, +)
            if values.isEmpty {
                maxByMetric[m] = 1
            } else {
                values.sort(by: >)
                maxByMetric[m] = values.count >= 20 ? values[values.count / 20] : values[0]
            }
        }

        cached = Cached(
            grid: weeks,
            maxByMetric: maxByMetric,
            totalsByMetric: totalsByMetric
        )
    }

    /// Mon at top → Sun at bottom. Only Mon/Wed/Fri get rendered as
    /// labels — matches GitHub's compact convention.
    private static let weekdayLabels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private static let visibleWeekdayIndices: Set<Int> = [0, 2, 4]

    var body: some View {
        PacerCard("Activity heatmap", trailing: { metricPicker }) {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        monthLabelRow
                        HStack(alignment: .top, spacing: Self.cellSpacing) {
                            weekdayColumn
                            ForEach(Array(grid.enumerated()), id: \.offset) { _, week in
                                weekColumn(week)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                summaryFooter
            }
        }
        .onAppear { refreshCache() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshCache() }
    }

    private var metricPicker: some View {
        Picker("", selection: Binding(
            get: { metric },
            set: { metricRaw = $0.rawValue }
        )) {
            ForEach(ProjectMetric.allCases) { m in
                Text(m.label).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 220)
        .controlSize(.small)
        .labelsHidden()
    }

    /// "$6,123 across 47 days" — GitHub-style summary line under the
    /// heatmap. Updates with the metric.
    private var summaryFooter: some View {
        let total = cached.totalsByMetric[metric] ?? 0
        let activeDays = cached.grid
            .flatMap { $0 }
            .compactMap { $0 }
            .filter { $0.value(for: metric) > 0 }
            .count
        return HStack(spacing: 4) {
            Text(formatTotal(total, kind: metric))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
            Text("\(metric.label.lowercased()) across \(activeDays) day\(activeDays == 1 ? "" : "s") in the last year")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            legend
        }
        .padding(.top, 4)
    }

    private func formatTotal(_ value: Double, kind: ProjectMetric) -> String {
        switch kind {
        case .cost:     return pacerCost(value)
        case .tokens:   return pacerTokens(Int64(value))
        case .sessions: return "\(Int(value))"
        }
    }

    /// Cell + spacing dimensions. 11×11 cells with 2pt gaps mirrors
    /// the GitHub contribution graph closely. Weekday-label column
    /// width is wide enough to fit "Mon" / "Wed" / "Fri" without
    /// truncation (the prior 18pt was clipping).
    private static let cellSize: CGFloat = 11
    private static let cellSpacing: CGFloat = 2
    private static let weekdayColumnWidth: CGFloat = 28

    /// Month label appears above the first week whose Monday falls
    /// inside that month. Suppressed when the month would land on the
    /// rightmost couple of columns and clip — caller can scroll to
    /// see those.
    @ViewBuilder
    private var monthLabelRow: some View {
        HStack(alignment: .center, spacing: Self.cellSpacing) {
            Spacer().frame(width: Self.weekdayColumnWidth, height: 12)
            ForEach(Array(grid.enumerated()), id: \.offset) { idx, _ in
                Group {
                    if let label = monthLabel(for: idx) {
                        Text(label)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(width: Self.cellSize, height: 12, alignment: .leading)
                    } else {
                        Color.clear.frame(width: Self.cellSize, height: 12)
                    }
                }
            }
        }
    }

    private func monthLabel(for index: Int) -> String? {
        let names = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
        let cal = Calendar(identifier: .iso8601)
        guard let monday = grid[index].compactMap({ $0?.date }).first else { return nil }
        let month = cal.component(.month, from: monday)
        if index == 0 {
            return names[month - 1]
        }
        guard let prevMonday = grid[index - 1].compactMap({ $0?.date }).first else {
            return names[month - 1]
        }
        let prevMonth = cal.component(.month, from: prevMonday)
        return month == prevMonth ? nil : names[month - 1]
    }

    /// Weekday column: Mon/Wed/Fri text on rows 0/2/4, blank on the
    /// rest. Right-aligned into a 28pt column so the labels read flush
    /// against the grid instead of floating in the middle.
    private var weekdayColumn: some View {
        VStack(alignment: .trailing, spacing: Self.cellSpacing) {
            ForEach(Array(Self.weekdayLabels.enumerated()), id: \.offset) { idx, day in
                if Self.visibleWeekdayIndices.contains(idx) {
                    Text(day)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: Self.weekdayColumnWidth, height: Self.cellSize, alignment: .trailing)
                } else {
                    Spacer().frame(width: Self.weekdayColumnWidth, height: Self.cellSize)
                }
            }
        }
        .padding(.trailing, 6)
    }

    @ViewBuilder
    private func weekColumn(_ week: [Cell?]) -> some View {
        VStack(spacing: Self.cellSpacing) {
            ForEach(0..<7, id: \.self) { idx in
                if let cell = week[idx] {
                    cellView(cell)
                } else {
                    Color.clear.frame(width: Self.cellSize, height: Self.cellSize)
                }
            }
        }
    }

    @ViewBuilder
    private func cellView(_ cell: Cell) -> some View {
        Button {
            onDayTap(cell.dateKey)
        } label: {
            RoundedRectangle(cornerRadius: 2)
                .fill(color(for: cell.value(for: metric)))
                .frame(width: Self.cellSize, height: Self.cellSize)
        }
        .buttonStyle(.plain)
        .help(tooltip(for: cell))
    }

    private func tooltip(for cell: Cell) -> String {
        let v = cell.value(for: metric)
        if v > 0 {
            return "\(cell.dateKey): \(formatTotal(v, kind: metric)) \(metric.label.lowercased())"
        }
        return "\(cell.dateKey): no usage"
    }

    private func color(for value: Double) -> Color {
        guard value > 0 else { return Color.secondary.opacity(0.12) }
        let cap = max(cached.maxByMetric[metric] ?? 1, 0.0001)
        let intensity = min(1.0, value / cap)
        switch intensity {
        case 0..<0.2:   return Color.green.opacity(0.20)
        case 0.2..<0.4: return Color.green.opacity(0.45)
        case 0.4..<0.6: return Color.green.opacity(0.65)
        case 0.6..<0.8: return Color.green.opacity(0.85)
        default:        return Color.green
        }
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Text("Less")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { intensity in
                RoundedRectangle(cornerRadius: 2)
                    .fill(legendColor(intensity: intensity))
                    .frame(width: 10, height: 10)
            }
            Text("More")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private func legendColor(intensity: Double) -> Color {
        if intensity == 0 { return Color.secondary.opacity(0.12) }
        switch intensity {
        case 0..<0.2:   return Color.green.opacity(0.20)
        case 0.2..<0.4: return Color.green.opacity(0.45)
        case 0.4..<0.6: return Color.green.opacity(0.65)
        case 0.6..<0.8: return Color.green.opacity(0.85)
        default:        return Color.green
        }
    }
}
