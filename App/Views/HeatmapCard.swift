import SwiftUI
import SwiftData
import PacerCore

/// GitHub-style activity heatmap. Rows are days of the week (Mon at
/// top → Sun at bottom), columns are weeks, oldest on the left and
/// "this week" anchored on the right. Cell color intensity tracks
/// cost (USD) by default; clicking a cell calls back so the parent
/// view can drill into that day's detail.
///
/// Default span is 26 weeks (~6 months). On compact widths the layout
/// will scroll horizontally rather than shrinking cells past the
/// minimum readable size.
struct HeatmapCard: View {
    let weekCount: Int
    let onDayTap: (String) -> Void

    @Query(sort: \DailyAggregate.date, order: .reverse) private var aggregates: [DailyAggregate]
    @Query(HeatmapCard.scanMetaProbe) private var scanMeta: [ClaudeCodeMeta]
    @State private var cached = Cached()

    init(weekCount: Int = 26, onDayTap: @escaping (String) -> Void) {
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
        let dateKey: String  // YYYY-MM-DD
        let cost: Double
        var id: String { dateKey }
    }

    /// Pre-built grid + percentile-capped color scale. Recomputing this
    /// in body fired Calendar / DateFormatter calls 26 weeks × 7 days
    /// each save tick — a small but recurring CPU hit on every History
    /// tab while in the eval tree.
    private struct Cached {
        var grid: [[Cell?]] = []
        var maxCost: Double = 1
    }

    private var grid: [[Cell?]] { cached.grid }
    private var maxCost: Double { cached.maxCost }

    private func refreshCache() {
        // Sum cost per day across models.
        var byDate: [String: Double] = [:]
        for row in aggregates {
            byDate[row.date, default: 0] += row.totalCostUSD
        }

        let cal = Calendar(identifier: .iso8601)
        let today = cal.startOfDay(for: Date())
        // Anchor "this week" on the rightmost column. Find Monday of
        // this week's bucket; subtract (weekCount-1) weeks to find the
        // grid's starting Monday.
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
                    week.append(nil)
                    continue
                }
                if day > today {
                    week.append(nil)
                    continue
                }
                let key = formatter.string(from: day)
                week.append(Cell(date: day, dateKey: key, cost: byDate[key] ?? 0))
            }
            weeks.append(week)
        }

        // 95th percentile-ish cap so a single outlier doesn't make every
        // other day look colorless. Sort costs desc, take the 5th value
        // if we have at least 20 days; else fall back to overall max.
        var costs = weeks.flatMap { $0 }.compactMap { $0?.cost }.filter { $0 > 0 }
        let computedMax: Double
        if costs.isEmpty {
            computedMax = 1
        } else {
            costs.sort(by: >)
            computedMax = costs.count >= 20 ? costs[costs.count / 20] : costs[0]
        }

        cached = Cached(grid: weeks, maxCost: computedMax)
    }

    private static let weekdayLabels = ["M", "T", "W", "T", "F", "S", "S"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Activity heatmap")
                    .font(.title2.weight(.semibold))
                Spacer()
                legend
            }
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    monthLabelRow
                    HStack(alignment: .top, spacing: 4) {
                        weekdayColumn
                        ForEach(Array(grid.enumerated()), id: \.offset) { _, week in
                            weekColumn(week)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear { refreshCache() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshCache() }
    }

    /// Month label appears above the first week whose Monday falls
    /// inside that month. Keeps consecutive duplicates suppressed so
    /// you don't see "Apr Apr Apr" — only the transition column gets
    /// the label.
    @ViewBuilder
    private var monthLabelRow: some View {
        // Same width math as the grid below: weekdayColumn(width 12 +
        // padding 2 = 14) → 12-wide week columns each separated by 4pt.
        HStack(alignment: .center, spacing: 4) {
            // weekdayColumn spacer
            Spacer().frame(width: 14, height: 11)
            ForEach(Array(grid.enumerated()), id: \.offset) { idx, week in
                Group {
                    if let label = monthLabel(for: idx) {
                        Text(label)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 12, height: 11, alignment: .leading)
            }
        }
    }

    /// Returns "Apr" / "May" / etc. for the *first* week-of-month a
    /// new month appears in, nil otherwise. Compares the first Monday
    /// of the column to the previous column's first Monday.
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

    private var weekdayColumn: some View {
        VStack(alignment: .trailing, spacing: 3) {
            ForEach(Array(Self.weekdayLabels.enumerated()), id: \.offset) { idx, day in
                // Only show every other label so it doesn't feel cramped.
                if idx % 2 == 0 {
                    Text(day)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 12, height: 12)
                } else {
                    Spacer().frame(width: 12, height: 12)
                }
            }
        }
        .padding(.trailing, 2)
    }

    @ViewBuilder
    private func weekColumn(_ week: [Cell?]) -> some View {
        VStack(spacing: 3) {
            ForEach(0..<7, id: \.self) { idx in
                if let cell = week[idx] {
                    cellView(cell)
                } else {
                    Color.clear.frame(width: 12, height: 12)
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
                .fill(color(for: cell.cost))
                .frame(width: 12, height: 12)
        }
        .buttonStyle(.plain)
        .help(tooltip(for: cell))
    }

    private func tooltip(for cell: Cell) -> String {
        if cell.cost > 0 {
            return "\(cell.dateKey): \(formatCost(cell.cost))"
        }
        return "\(cell.dateKey): no usage"
    }

    private func color(for cost: Double) -> Color {
        guard cost > 0 else { return Color.secondary.opacity(0.12) }
        let intensity = min(1.0, cost / max(maxCost, 0.0001))
        // Five discrete bands matching GitHub's contribution graph.
        switch intensity {
        case 0..<0.2:   return Color.green.opacity(0.20)
        case 0.2..<0.4: return Color.green.opacity(0.40)
        case 0.4..<0.6: return Color.green.opacity(0.60)
        case 0.6..<0.8: return Color.green.opacity(0.80)
        default:        return Color.green
        }
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Text("less")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { intensity in
                RoundedRectangle(cornerRadius: 2)
                    .fill(legendColor(intensity: intensity))
                    .frame(width: 10, height: 10)
            }
            Text("more")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func legendColor(intensity: Double) -> Color {
        if intensity == 0 { return Color.secondary.opacity(0.12) }
        switch intensity {
        case 0..<0.2:   return Color.green.opacity(0.20)
        case 0.2..<0.4: return Color.green.opacity(0.40)
        case 0.4..<0.6: return Color.green.opacity(0.60)
        case 0.6..<0.8: return Color.green.opacity(0.80)
        default:        return Color.green
        }
    }

    private func formatCost(_ usd: Double) -> String {
        if usd >= 100 { return String(format: "$%.0f", usd) }
        if usd >= 10  { return String(format: "$%.1f", usd) }
        return String(format: "$%.2f", usd)
    }
}
