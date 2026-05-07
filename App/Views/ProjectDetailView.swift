import SwiftUI
import SwiftData
import Charts
import PacerCore

/// Drill-down for a single project. Presented as a sheet from
/// `ProjectsView`. Shows:
///   - Cost / tokens summary headline
///   - Daily-cost mini-chart over the visible range
///   - Models-used pie chart
///   - Recent sessions list (sessionId, last seen, model)
///
/// Reads `TokenSample` filtered to the given path. The same range
/// picker as the parent list is honored by the caller via `since`.
struct ProjectDetailView: View {
    let projectPath: String
    let displayName: String
    let since: Date?

    @Environment(\.dismiss) private var dismiss
    /// Predicate-filtered to this project (and optional since-date).
    /// Read only from `refreshCache()` — the body never touches it,
    /// so SwiftData saves don't trigger a re-iteration of every
    /// sample for this project on every refresh tick.
    @Query private var samples: [TokenSample]
    /// Cheap single-row scan-meta probe; the value changes once per
    /// scan cycle. Drives cache refresh while the sheet is open.
    @Query(ProjectDetailView.scanMetaProbe) private var scanMeta: [ClaudeCodeMeta]

    @State private var cached = Cached()

    init(projectPath: String, displayName: String, since: Date?) {
        self.projectPath = projectPath
        self.displayName = displayName
        self.since = since
        // Build a predicate: project path matches AND sampledAt >= since.
        // SwiftData predicates don't support "$0.field == capture && $0.field >= capture"
        // when capture is optional, so we conditionally branch on `since`.
        let path = projectPath
        if let cutoff = since {
            _samples = Query(
                filter: #Predicate<TokenSample> {
                    $0.projectPath == path && $0.sampledAt >= cutoff
                },
                sort: \.sampledAt,
                order: .reverse
            )
        } else {
            _samples = Query(
                filter: #Predicate<TokenSample> { $0.projectPath == path },
                sort: \.sampledAt,
                order: .reverse
            )
        }
    }

    private static let scanMetaProbe: FetchDescriptor<ClaudeCodeMeta> = {
        let key = ClaudeCodeMetaKey.lastIncrementalScanAt
        return FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key }
        )
    }()

    private struct DayPoint: Identifiable {
        let date: String
        let cost: Double
        let tokens: Int64
        var id: String { date }
    }

    private struct ModelSlice: Identifiable {
        let model: String
        let tokens: Int64
        var id: String { model }
    }

    private struct SessionRow: Identifiable {
        let sessionId: String
        let lastSeen: Date
        let totalTokens: Int64
        let cost: Double
        let topModel: String
        var id: String { sessionId }
    }

    /// All four derived collections built in a single pass over
    /// `samples`. Body reads these via `cached.*` so a refresh is the
    /// only thing that re-iterates the predicate's rows.
    private struct Cached {
        var totals: (cost: Double, input: Int64, output: Int64, cacheRead: Int64) = (0, 0, 0, 0)
        var dailySeries: [DayPoint] = []
        var modelSlices: [ModelSlice] = []
        var sessions: [SessionRow] = []
        var sampleCount: Int = 0
    }

    private var totals: (cost: Double, input: Int64, output: Int64, cacheRead: Int64) { cached.totals }
    private var dailySeries: [DayPoint] { cached.dailySeries }
    private var modelSlices: [ModelSlice] { cached.modelSlices }
    private var sessions: [SessionRow] { cached.sessions }

    private func refreshCache() {
        // One pass over `samples`, building all four output collections
        // simultaneously. Previously each was its own computed property
        // and ran an independent for-loop over samples — body called
        // them all, so a save fired four full iterations.
        var cost: Double = 0
        var input: Int64 = 0
        var output: Int64 = 0
        var cacheRead: Int64 = 0

        var byDate: [String: (cost: Double, tokens: Int64)] = [:]
        var byModel: [String: Int64] = [:]

        struct SessionAcc {
            var lastSeen: Date = .distantPast
            var input: Int64 = 0
            var output: Int64 = 0
            var cacheRead: Int64 = 0
            var cost: Double = 0
            var modelTokens: [String: Int64] = [:]
        }
        var bySession: [String: SessionAcc] = [:]

        for s in samples {
            let sCost = s.sourceCostUSD ?? 0
            let sTokens = s.inputTokens + s.outputTokens + s.cacheReadTokens

            cost += sCost
            input += s.inputTokens
            output += s.outputTokens
            cacheRead += s.cacheReadTokens

            var d = byDate[s.date] ?? (0, 0)
            d.cost += sCost
            d.tokens += sTokens
            byDate[s.date] = d

            byModel[s.model, default: 0] += sTokens

            if let sid = s.sessionId {
                var a = bySession[sid] ?? SessionAcc()
                a.input += s.inputTokens
                a.output += s.outputTokens
                a.cacheRead += s.cacheReadTokens
                a.cost += sCost
                a.modelTokens[s.model, default: 0] += sTokens
                if s.sampledAt > a.lastSeen { a.lastSeen = s.sampledAt }
                bySession[sid] = a
            }
        }

        let dailySeries = byDate.keys.sorted().map { date in
            DayPoint(date: date, cost: byDate[date]?.cost ?? 0, tokens: byDate[date]?.tokens ?? 0)
        }
        let modelSlices = byModel.map { ModelSlice(model: $0.key, tokens: $0.value) }
            .sorted { $0.tokens > $1.tokens }
        let sessions = bySession.map { (sid, a) in
            let topModel = a.modelTokens.max(by: { $0.value < $1.value })?.key ?? "—"
            return SessionRow(
                sessionId: sid,
                lastSeen: a.lastSeen,
                totalTokens: a.input + a.output + a.cacheRead,
                cost: a.cost,
                topModel: topModel
            )
        }.sorted { $0.lastSeen > $1.lastSeen }

        cached = Cached(
            totals: (cost, input, output, cacheRead),
            dailySeries: dailySeries,
            modelSlices: modelSlices,
            sessions: sessions,
            sampleCount: samples.count
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                summaryCard
                if !dailySeries.isEmpty {
                    dailyChartCard
                }
                if !modelSlices.isEmpty {
                    modelsCard
                }
                if !sessions.isEmpty {
                    sessionsCard
                }
            }
            .padding(24)
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 540, idealHeight: 700)
        .onAppear { refreshCache() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshCache() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.title.weight(.semibold))
                Text(projectPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private var summaryCard: some View {
        let t = totals
        return VStack(alignment: .leading, spacing: 10) {
            Text("Summary").font(.headline)
            HStack(alignment: .top, spacing: 32) {
                metric("cost", formatCost(t.cost))
                metric("input", formatTokens(t.input))
                metric("output", formatTokens(t.output))
                metric("cache read", formatTokens(t.cacheRead))
                metric("samples", "\(cached.sampleCount)")
                Spacer()
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var dailyChartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Daily activity").font(.headline)
            Chart(dailySeries) { d in
                BarMark(
                    x: .value("Date", d.date),
                    y: .value("Cost", d.cost)
                )
                .foregroundStyle(.tint)
            }
            .frame(height: 160)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(compactDollar(v))
                                .font(.system(size: 9, design: .monospaced))
                        }
                    }
                }
            }
            .chartXAxis(.hidden)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var modelsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Models").font(.headline)
            HStack(alignment: .top, spacing: 24) {
                Chart(modelSlices) { m in
                    SectorMark(
                        angle: .value("tokens", m.tokens),
                        innerRadius: .ratio(0.6),
                        angularInset: 1.5
                    )
                    .foregroundStyle(by: .value("Model", shortModel(m.model)))
                    .cornerRadius(2)
                }
                .frame(width: 160, height: 160)
                .chartLegend(.hidden)
                VStack(alignment: .leading, spacing: 6) {
                    let total = modelSlices.reduce(Int64(0)) { $0 + $1.tokens }
                    ForEach(modelSlices) { m in
                        HStack(alignment: .firstTextBaseline) {
                            Text(shortModel(m.model))
                                .font(.system(.body, design: .monospaced))
                            Spacer(minLength: 8)
                            Text(formatTokens(m.tokens))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            if total > 0 {
                                Text("\(Int(Double(m.tokens) / Double(total) * 100))%")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 36, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var sessionsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sessions").font(.headline)
                Spacer()
                Text("\(sessions.count) total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(sessions.prefix(20))) { row in
                HStack(alignment: .firstTextBaseline) {
                    Text(String(row.sessionId.prefix(8)))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 80, alignment: .leading)
                    Text(shortModel(row.topModel))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 220, alignment: .leading)
                    Spacer(minLength: 8)
                    Text(formatTokens(row.totalTokens))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 80, alignment: .trailing)
                    Text(formatCost(row.cost))
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .frame(width: 70, alignment: .trailing)
                    Text(relative(row.lastSeen))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 90, alignment: .trailing)
                }
            }
            if sessions.count > 20 {
                Text("…and \(sessions.count - 20) more")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func formatCost(_ usd: Double) -> String {
        if usd >= 1_000 { return String(format: "$%.0f", usd) }
        if usd >= 100   { return String(format: "$%.0f", usd) }
        if usd >= 10    { return String(format: "$%.1f", usd) }
        return String(format: "$%.2f", usd)
    }

    private func compactDollar(_ usd: Double) -> String {
        if usd >= 100 { return String(format: "$%.0f", usd) }
        if usd >= 10  { return String(format: "$%.0f", usd) }
        return String(format: "$%.1f", usd)
    }

    private func formatTokens(_ count: Int64) -> String {
        let n = Double(count)
        switch n {
        case 1_000_000_000...: return String(format: "%.2fB", n / 1_000_000_000)
        case 1_000_000...:     return String(format: "%.1fM", n / 1_000_000)
        case 1_000...:         return String(format: "%.1fK", n / 1_000)
        default:               return "\(count)"
        }
    }

    private func shortModel(_ name: String) -> String {
        if let lastSlash = name.lastIndex(of: "/") {
            return String(name[name.index(after: lastSlash)...])
        }
        return name
    }
}
