import SwiftUI
import SwiftData
import PacerCore
import PacerUI

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
    /// Real distinct-session count per day comes from SessionInfo,
    /// the same source the day-detail modal pulls from. Iterating
    /// every session once and bucketing across the day(s) it touched
    /// is N (sessions) rather than D × N (days × sessions).
    ///
    /// Predicate-bounded to the heatmap's visible window so we don't
    /// pull thousands of historical `SessionInfo` rows that the grid
    /// can't display anyway. The previous unbounded query
    /// materialized every session in the table on every view
    /// creation — including on tab-switch back into History, where
    /// it dominated the re-mount cost.
    @Query private var sessions: [SessionInfo]
    @Query(HeatmapCard.scanMetaProbe) private var scanMeta: [ClaudeCodeMeta]
    @State private var cached = Cached()
    /// Suppress the decorative tooltip fade when the user has Reduce
    /// Motion enabled. The tooltip is informational, not load-bearing —
    /// snapping in is fine; respecting the system preference matters
    /// more than the polish of the fade.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        // Bound the session query to "sessions whose lastSeenAt falls
        // inside the visible heatmap window." The default 52-week
        // grid extends back 52*7 days from today; the `lastSeenAt`
        // index added in the schema makes this a range scan instead
        // of a full-table fetch. A few extra days of leeway covers
        // sessions that span midnight on the window boundary.
        let cal = Calendar(identifier: .iso8601)
        let cutoff = cal.date(byAdding: .day, value: -(weekCount * 7 + 7), to: Date())
            ?? Date(timeIntervalSince1970: 0)
        _sessions = Query(
            filter: #Predicate<SessionInfo> { $0.lastSeenAt >= cutoff }
        )
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
    ///
    /// `monthLabels` and `activeDaysByMetric` were moved in here from
    /// per-render helpers — `monthLabel(for:)` used to create a
    /// `Calendar(identifier: .iso8601)` per cell on every redraw, and
    /// `summaryFooter` flatMap+filter+count'd the whole grid on every
    /// render. Pre-computing both turns those into O(1) lookups.
    private struct Cached {
        var grid: [[Cell?]] = []
        var maxByMetric: [ProjectMetric: Double] = [:]
        var totalsByMetric: [ProjectMetric: Double] = [:]
        /// Parallel to `grid` indexes — `monthLabels[i]` is the column
        /// header text for week `i`, or nil for "same month as the
        /// previous column".
        var monthLabels: [String?] = []
        /// Count of cells in the grid whose value for the metric > 0.
        /// Pre-counted because `summaryFooter` shows "across N days"
        /// for the *active* metric, and the picker change isn't a
        /// data-change event.
        var activeDaysByMetric: [ProjectMetric: Int] = [:]
    }

    private var grid: [[Cell?]] { cached.grid }

    /// Shared Calendar / month-name table. Calendar instantiation is
    /// non-trivially expensive (locale + tz resolution); making it
    /// static dropped HeatmapCard hover render time materially.
    private static let isoCalendar = Calendar(identifier: .iso8601)
    private static let monthNames = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
    /// Shared date formatter for YYYY-MM-DD keying. Was being re-built
    /// every `refreshCache()` call and twice inside the session-bucket
    /// loop.
    private static let dateKeyFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func refreshCache() {
        // Per-day rollup: cost + tokens come from DailyAggregate;
        // distinct-session count comes from iterating SessionInfo and
        // bucketing each session across every day it overlapped. That
        // matches what the day-detail modal shows when the user clicks
        // a cell — both surfaces now answer the same "sessions active
        // on this day" question instead of two different proxies.
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
            byDate[row.date] = a
        }

        // Bucket each session into every YYYY-MM-DD it touched. The
        // overwhelming majority of sessions are single-day so this
        // loop is essentially `sessions.count` iterations — but
        // multi-day sessions get counted on each day they were active,
        // matching the day-detail predicate exactly.
        let bucketCal = Calendar.current
        for s in sessions {
            var day = bucketCal.startOfDay(for: s.firstSeenAt)
            let lastDay = bucketCal.startOfDay(for: s.lastSeenAt)
            while day <= lastDay {
                let key = Self.dateKeyFmt.string(from: day)
                var acc = byDate[key] ?? Acc()
                acc.sessions.insert(s.sessionId)
                byDate[key] = acc
                guard let next = bucketCal.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }

        let cal = Self.isoCalendar
        let today = cal.startOfDay(for: Date())
        guard let thisMonday = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today)),
              let firstMonday = cal.date(byAdding: .weekOfYear, value: -(weekCount - 1), to: thisMonday)
        else {
            cached = Cached()
            return
        }

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
                let key = Self.dateKeyFmt.string(from: day)
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

        // Precompute the column-header month label for each week —
        // moves a per-cell Calendar lookup out of the render path.
        // `monthLabels[i]` is non-nil when this column's first Monday
        // is in a different month than the previous column's Monday.
        var monthLabels: [String?] = []
        monthLabels.reserveCapacity(weeks.count)
        var lastMonth: Int = 0
        for (idx, week) in weeks.enumerated() {
            guard let monday = week.compactMap({ $0?.date }).first else {
                monthLabels.append(nil)
                continue
            }
            let month = cal.component(.month, from: monday)
            if idx == 0 || month != lastMonth {
                monthLabels.append(Self.monthNames[month - 1])
                lastMonth = month
            } else {
                monthLabels.append(nil)
            }
        }

        // 95th-percentile cap per metric so a single outlier doesn't
        // wash out the rest of the year. Same algorithm as before but
        // now run independently for each metric so switching metric
        // gives a usable color scale immediately. Also pre-count
        // active days per metric so the summary footer doesn't walk
        // the grid on every render.
        var maxByMetric: [ProjectMetric: Double] = [:]
        var totalsByMetric: [ProjectMetric: Double] = [:]
        var activeDaysByMetric: [ProjectMetric: Int] = [:]
        let flatCells = weeks.flatMap { $0 }.compactMap { $0 }
        for m in ProjectMetric.allCases {
            var values: [Double] = []
            values.reserveCapacity(flatCells.count)
            var total: Double = 0
            var activeCount = 0
            for cell in flatCells {
                let v = cell.value(for: m)
                if v > 0 {
                    values.append(v)
                    total += v
                    activeCount += 1
                }
            }
            totalsByMetric[m] = total
            activeDaysByMetric[m] = activeCount
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
            totalsByMetric: totalsByMetric,
            monthLabels: monthLabels,
            activeDaysByMetric: activeDaysByMetric
        )
    }

    /// Mon at top → Sun at bottom. Only Mon/Wed/Fri get rendered as
    /// labels — matches GitHub's compact convention.
    private static let weekdayLabels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private static let visibleWeekdayIndices: Set<Int> = [0, 2, 4]

    /// Coordinate space for tooltip anchoring. Each hovered cell
    /// publishes its frame in this space via a PreferenceKey; the
    /// tooltip overlay reads that frame and floats above the cell.
    /// Pulled into a constant to keep the cell-frame publisher and
    /// the overlay reader in sync.
    private static let coordSpaceName = "heatmap-card"

    var body: some View {
        PacerCard("Activity heatmap", trailing: { metricPicker }) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
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
                    // Floating popover-style tooltip anchored to the
                    // hovered cell's frame. Lives in a sibling layer of
                    // the ScrollView so it can extend ABOVE the grid
                    // without being clipped by the scroll view's bounds.
                    // `.allowsHitTesting(false)` keeps clicks falling
                    // through to the cell underneath.
                    if let id = hoveredCellId,
                       let cell = cellById(id),
                       let frame = hoveredCellFrame {
                        TooltipBubble(
                            color: color(for: cell.value(for: metric)),
                            valueText: formatTotal(cell.value(for: metric), kind: metric),
                            metricLabel: metric.label.lowercased(),
                            dateText: Self.tooltipDateFmt.string(from: cell.date)
                        )
                        .fixedSize()
                        .position(
                            x: frame.midX,
                            y: frame.minY - tooltipOffset
                        )
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hoveredCellId)
                        .zIndex(10)
                    }
                }
                .coordinateSpace(name: Self.coordSpaceName)
                .onPreferenceChange(HoveredCellFramePreferenceKey.self) { newFrame in
                    // Track the hovered cell's frame as published by
                    // the cell's GeometryReader. nil when nothing is
                    // hovered — clear the local state too so a stale
                    // frame doesn't survive into the next hover.
                    hoveredCellFrame = newFrame
                }
                summaryFooter
            }
        }
        .onAppear { refreshCache() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshCache() }
    }

    /// Vertical offset between the cell's top and the tooltip's
    /// center. Tooltip is ~40pt tall; positioning its center 30pt
    /// above the cell's top puts the tooltip's bottom ~10pt above the
    /// cell, leaving breathing room.
    private var tooltipOffset: CGFloat { 30 }

    private var metricPicker: some View {
        Picker("Heatmap metric", selection: Binding(
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
    /// heatmap. Updates with the metric. Both `total` and `activeDays`
    /// are O(1) lookups into the `Cached` snapshot now — used to do a
    /// fresh flatMap+compactMap+filter+count on every render.
    private var summaryFooter: some View {
        let total = cached.totalsByMetric[metric] ?? 0
        let activeDays = cached.activeDaysByMetric[metric] ?? 0
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

    /// O(1) lookup into the parallel `monthLabels` cache built in
    /// `refreshCache()`. Previous body of this function created a fresh
    /// `Calendar(identifier: .iso8601)` every call and was invoked once
    /// per grid column on every render — `~52 calls × Calendar
    /// instantiation` per hover state change adds up fast.
    private func monthLabel(for index: Int) -> String? {
        guard cached.monthLabels.indices.contains(index) else { return nil }
        return cached.monthLabels[index]
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

    /// Hovered-cell state. The cell's id drives which cell highlights
    /// and which one's frame we anchor the tooltip to. We track the
    /// frame via a PreferenceKey published from the hovered cell — so
    /// horizontal scrolling, window resizing, or layout reflows all
    /// keep the tooltip glued to the cell.
    @State private var hoveredCellId: String?
    @State private var hoveredCellFrame: CGRect?
    @State private var enterTask: Task<Void, Never>?
    @State private var exitTask: Task<Void, Never>?

    /// Initial hover dwell — tooltip waits this long before appearing
    /// so a fast cursor sweep across the grid doesn't flicker tooltips.
    /// Once a tooltip is showing, switching between cells is instant
    /// (matches GitHub's contribution-graph dwell).
    private static let initialHoverDelayMS: Int = 180
    /// Exit grace — keeps the tooltip up briefly when the cursor
    /// leaves a cell so a slide to a neighbor doesn't dismiss-then-
    /// re-show. The neighbor's enter cancels this grace before it
    /// fires, switching tooltips in place.
    private static let exitGraceMS: Int = 60

    private func enterCell(_ id: String) {
        exitTask?.cancel()
        if hoveredCellId != nil {
            // Tooltip is up — switch instantly.
            enterTask?.cancel()
            hoveredCellId = id
        } else {
            // First-entry dwell.
            enterTask?.cancel()
            enterTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(Self.initialHoverDelayMS))
                if Task.isCancelled { return }
                hoveredCellId = id
            }
        }
    }

    private func exitCell(_ id: String) {
        enterTask?.cancel()
        exitTask?.cancel()
        // Defer dismiss so a concurrent enterCell on a neighbor can
        // override before the tooltip blinks off.
        exitTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Self.exitGraceMS))
            if Task.isCancelled { return }
            if hoveredCellId == id { hoveredCellId = nil }
        }
    }

    @ViewBuilder
    private func cellView(_ cell: Cell) -> some View {
        let v = cell.value(for: metric)
        if v > 0 {
            // Active cell: clickable + hoverable + cursor flips to link.
            // The GeometryReader background publishes this cell's frame
            // in the card-local coordinate space whenever it's the
            // currently-hovered cell, which lets the tooltip overlay
            // anchor itself precisely above the cell.
            Button {
                onDayTap(cell.dateKey)
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(for: v))
                    if hoveredCellId == cell.dateKey {
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(Color.primary.opacity(0.55), lineWidth: 1)
                    }
                }
                .frame(width: Self.cellSize, height: Self.cellSize)
                .contentShape(Rectangle())
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: HoveredCellFramePreferenceKey.self,
                            value: hoveredCellId == cell.dateKey
                                ? geo.frame(in: .named(Self.coordSpaceName))
                                : nil
                        )
                    }
                )
            }
            .buttonStyle(.plain)
            // Arrow cursor (default) — Apple's macOS HIG reserves the
            // link cursor for hyperlinks. The hover stroke + tooltip is
            // the affordance.
            .onHover { inside in
                if inside { enterCell(cell.dateKey) }
                else { exitCell(cell.dateKey) }
            }
            .accessibilityLabel(cellAccessibilityLabel(cell))
            .accessibilityHint("Opens the day's detailed breakdown")
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

    /// Pretty date used by the floating tooltip ("Thu, May 7, 2026").
    private static let tooltipDateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d, yyyy"
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

    /// VoiceOver-friendly label for an active cell — speaks the date and
    /// the cell's value in the current metric ("Thu, May 7, 2026: $12.40").
    private func cellAccessibilityLabel(_ cell: Cell) -> String {
        let date = Self.tooltipDateFmt.string(from: cell.date)
        let v = cell.value(for: metric)
        let valueText: String
        switch metric {
        case .cost:
            valueText = pacerCost(v)
        case .tokens:
            valueText = "\(pacerTokens(Int64(v))) tokens"
        case .sessions:
            let n = Int(v)
            valueText = "\(n) \(n == 1 ? "session" : "sessions")"
        }
        return "\(date): \(valueText)"
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

// MARK: - Tooltip plumbing

/// PreferenceKey used by the hovered cell to publish its frame in
/// the heatmap-card coordinate space. The card's overlay reads it
/// to position the floating tooltip. The reduce keeps the first
/// non-nil value because at most one cell ever publishes (the
/// hovered one).
private struct HoveredCellFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = value ?? nextValue()
    }
}

/// Popover-style hover tooltip for the heatmap. Anchored above the
/// hovered cell via `.position` in the heatmap-card coordinate space.
/// Renders as a rounded card with a downward arrow pointer + soft
/// shadow — same visual language as a macOS NSPopover, but it lives
/// inside our own SwiftUI tree so clicks pass through cleanly with
/// `.allowsHitTesting(false)`.
private struct TooltipBubble: View {
    let color: Color
    /// Already-formatted value for the active metric ("$12.40", "32K").
    let valueText: String
    /// Lowercased metric noun ("cost", "tokens", "sessions").
    let metricLabel: String
    /// Pretty date line ("Thu, May 7, 2026").
    let dateText: String

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: 10, height: 10)
                    Text(valueText)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(metricLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Text(dateText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("Click to drill in")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(PacerDesign.cardStroke, lineWidth: 1)
            )
            // Downward arrow pointer, mirrors macOS popover affordance.
            // Drawn as a small triangle at the bubble's bottom-center.
            BubbleArrow()
                .fill(Color(nsColor: .windowBackgroundColor))
                .frame(width: 10, height: 6)
                .overlay(
                    BubbleArrow()
                        .stroke(PacerDesign.cardStroke, lineWidth: 1)
                )
                .offset(y: -1)  // slight overlap so the bubble's stroke covers the arrow's top edge
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)
    }
}

private struct BubbleArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
