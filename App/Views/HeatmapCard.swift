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

    /// fileprivate so the HeatmapCellButton in this file can reference
    /// it. Still effectively scoped to this file via the outer struct.
    fileprivate struct Cell: Identifiable {
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
            // Reserve the tooltip row so the grid never reflows when
            // hover state flips between active/inactive. Empty 22pt
            // strip stays in place; the floating tooltip only changes
            // its content.
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .leading) {
                    Color.clear.frame(height: 22)
                    tooltipOverlay
                        .animation(.easeOut(duration: 0.12), value: hoveredCellId)
                }
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

    /// Hovered cell drives the floating tooltip overlay. Stored at
    /// the parent level (rather than per-cell state) so we can render
    /// the tooltip in a single overlay pass without each cell hosting
    /// its own popover — which was intercepting tap-through clicks.
    @State private var hoveredCellId: String?
    @State private var hoverTask: Task<Void, Never>?

    /// Initial hover takes ~200ms before the tooltip appears so a
    /// fast cursor sweep across the grid doesn't flicker tooltips.
    /// Once the tooltip is up, switching between cells updates
    /// immediately — same dwell behavior as GitHub.
    private static let initialHoverDelayMS: Int = 200

    private func enterCell(_ id: String) {
        hoverTask?.cancel()
        if hoveredCellId == nil {
            let delay = Self.initialHoverDelayMS
            hoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(delay))
                if Task.isCancelled { return }
                hoveredCellId = id
            }
        } else {
            // Tooltip already up — immediate switch.
            hoveredCellId = id
        }
    }

    private func exitCell(_ id: String) {
        hoverTask?.cancel()
        if hoveredCellId == id {
            hoveredCellId = nil
        }
    }

    @ViewBuilder
    private func cellView(_ cell: Cell) -> some View {
        let v = cell.value(for: metric)
        if v > 0 {
            // Active cell: clickable + hoverable + cursor flips to link.
            Button {
                onDayTap(cell.dateKey)
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(for: v))
                    if hoveredCellId == cell.dateKey {
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(Color.primary.opacity(0.5), lineWidth: 1)
                    }
                }
                .frame(width: Self.cellSize, height: Self.cellSize)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .onHover { inside in
                if inside { enterCell(cell.dateKey) }
                else { exitCell(cell.dateKey) }
            }
        } else {
            // Empty day: just a swatch, no hover affordance, not
            // clickable. Committed to one consistent behavior — no
            // teasing tooltip for cells with nothing to drill into.
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.secondary.opacity(0.12))
                .frame(width: Self.cellSize, height: Self.cellSize)
        }
    }

    /// Find the hovered cell across the full grid. O(weeks*7) but
    /// the data is already in @State and the lookup only fires on
    /// hover-state change, not per render.
    private func cellById(_ id: String) -> Cell? {
        for week in cached.grid {
            for cell in week where cell?.dateKey == id {
                return cell
            }
        }
        return nil
    }

    /// Floating tooltip layer rendered above the grid. Positioned at
    /// the top of the card body so it never overlaps the grid below
    /// the hovered cell. Single source of truth for the active hover —
    /// each cell only flips a binding rather than presenting its own
    /// popover. That fixes the prior bug where `.popover` per cell
    /// was intercepting tap-through clicks.
    @ViewBuilder
    private var tooltipOverlay: some View {
        if let id = hoveredCellId, let cell = cellById(id) {
            let v = cell.value(for: metric)
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(color(for: v))
                    .frame(width: 10, height: 10)
                Text(formatTotal(v, kind: metric))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(metric.label.lowercased())
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(Self.tooltipDateFmt.string(from: cell.date))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("· click to drill in")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(PacerDesign.cardStroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
            .transition(.opacity)
        }
    }

    private static let tooltipDateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f
    }()

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

    /// Color bins are derived from a 95th-percentile cap on the
    /// active metric. Show each swatch's upper-bound value so the user
    /// can read the legend at a glance — "this dark green = roughly
    /// $X+". Hover a swatch to see its precise band.
    private var legend: some View {
        let cap = max(cached.maxByMetric[metric] ?? 0, 0.0001)
        // Bin upper-bounds in metric units. Same thresholds as
        // `color(for:)`: 20%, 40%, 60%, 80%, 100% of cap.
        let upper: [Double] = [0.2, 0.4, 0.6, 0.8, 1.0].map { $0 * cap }
        return HStack(spacing: 4) {
            Text("Less")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            ForEach(Array(upper.enumerated()), id: \.offset) { idx, ub in
                LegendSwatch(
                    color: legendColor(intensity: Double(idx + 1) * 0.2 - 0.001),
                    upperBound: ub,
                    metric: metric,
                    isLast: idx == upper.count - 1
                )
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

/// One swatch in the heatmap legend. Hovering reveals the value
/// range that swatch represents — useful because the bins are
/// dynamic (95th-percentile cap on the active metric).
private struct LegendSwatch: View {
    let color: Color
    /// Upper bound of this bin in the active metric's units.
    let upperBound: Double
    let metric: ProjectMetric
    let isLast: Bool
    @State private var hovering: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: 10, height: 10)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.primary.opacity(hovering ? 0.4 : 0), lineWidth: 1)
            )
            .onHover { hovering = $0 }
            .help(helpText)
    }

    private var helpText: String {
        let formatted: String
        switch metric {
        case .cost:     formatted = pacerCost(upperBound)
        case .tokens:   formatted = pacerTokens(Int64(upperBound))
        case .sessions: formatted = "\(Int(upperBound))"
        }
        return isLast
            ? "≥ \(formatted) \(metric.label.lowercased())"
            : "up to \(formatted) \(metric.label.lowercased())"
    }
}

