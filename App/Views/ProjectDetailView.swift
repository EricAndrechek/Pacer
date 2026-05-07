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
    /// Container handle for the rollup actor. Skips @Query for the
    /// project's TokenSamples — even one project can be thousands of
    /// rows, and SwiftData materializes them on every save while the
    /// sheet is open.
    @Environment(\.modelContext) private var modelContext
    @Query(ProjectDetailView.scanMetaProbe) private var scanMeta: [ClaudeCodeMeta]

    @State private var cached: ProjectDetailRollup = .init(
        totals: .init(),
        dailySeries: [],
        modelSlices: [],
        sessions: [],
        sampleCount: 0
    )
    @State private var hasLoaded = false
    @State private var refreshGen: Int = 0

    init(projectPath: String, displayName: String, since: Date?) {
        self.projectPath = projectPath
        self.displayName = displayName
        self.since = since
    }

    private static let scanMetaProbe: FetchDescriptor<ClaudeCodeMeta> = {
        let key = ClaudeCodeMetaKey.lastIncrementalScanAt
        return FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key }
        )
    }()

    private var totals: ProjectDetailRollup.Totals { cached.totals }
    private var dailySeries: [ProjectDetailRollup.DayPoint] { cached.dailySeries }
    private var modelSlices: [ProjectDetailRollup.ModelSlice] { cached.modelSlices }
    private var sessions: [ProjectDetailRollup.SessionRow] { cached.sessions }

    private func refreshCache() {
        let container = modelContext.container
        let path = projectPath
        let cutoff = since
        refreshGen &+= 1
        let myGen = refreshGen
        Task {
            let worker = RollupWorker(modelContainer: container)
            let result = await worker.projectDetail(projectPath: path, since: cutoff)
            guard myGen == refreshGen else { return }
            cached = result
            hasLoaded = true
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if hasLoaded {
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
                } else {
                    loadingCard
                }
            }
            .padding(24)
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 540, idealHeight: 700)
        .onAppear { refreshCache() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshCache() }
    }

    private var loadingCard: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Rolling up project…")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
