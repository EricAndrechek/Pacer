import SwiftUI
import SwiftData
import Charts
import PacerCore

/// Per-model breakdown — analogous to ProjectsView but keyed on model
/// name. Shows which models you actually use, how heavily, and over
/// what timeframe. Useful for "is sonnet doing the bulk of work or am
/// I always reaching for opus?" / "did I switch off haiku 3 months ago?"
struct ModelsView: View {
    @State private var range: ModelsRange = .ninetyDays

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                ModelsContent(range: range)
                    .id(range)
            }
            .padding(24)
        }
        .frame(minWidth: 720, minHeight: 600)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Models")
                .font(.largeTitle.weight(.semibold))
            Spacer()
            Picker("", selection: $range) {
                ForEach(ModelsRange.allCases) { r in
                    Text(r.label).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
        }
        .padding(.bottom, 4)
    }
}

enum ModelsRange: String, CaseIterable, Identifiable {
    case thirtyDays = "30d"
    case ninetyDays = "90d"
    case all        = "all"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .thirtyDays: return "Last 30 days"
        case .ninetyDays: return "Last 90 days"
        case .all:        return "All time"
        }
    }
    var days: Int? {
        switch self {
        case .thirtyDays: return 30
        case .ninetyDays: return 90
        case .all:        return nil
        }
    }
}

private struct ModelsContent: View {
    /// Container handle for the rollup actor. We bypass @Query for
    /// DailyAggregate too — even though the table is small, having
    /// the rollup live on the actor keeps the iteration off the
    /// main thread on every scan-meta tick (consistent with
    /// ProjectsView; matters less in absolute terms but eliminates a
    /// recurring main-thread blocker).
    @Environment(\.modelContext) private var modelContext
    @Query(ModelsContent.scanMetaProbe) private var scanMeta: [ClaudeCodeMeta]

    @State private var cached = Cached()
    @State private var hasLoaded = false
    @State private var refreshGen: Int = 0

    private let rangeCutoff: String?

    init(range: ModelsRange) {
        if let days = range.days {
            self.rangeCutoff = TokenSample.formatDate(
                Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast
            )
        } else {
            self.rangeCutoff = nil
        }
    }

    private static let scanMetaProbe: FetchDescriptor<ClaudeCodeMeta> = {
        let key = ClaudeCodeMetaKey.lastIncrementalScanAt
        return FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key }
        )
    }()

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

    private struct Cached {
        var rows: [ModelRow] = []
        var dailyMix: [DailyMix] = []
    }

    private var rows: [ModelRow] { cached.rows }
    private var dailyMix: [DailyMix] { cached.dailyMix }

    private func refreshCache() {
        let container = modelContext.container
        let cutoff = rangeCutoff
        refreshGen &+= 1
        let myGen = refreshGen
        Task {
            let worker = RollupWorker(modelContainer: container)
            let result = await worker.modelRollups(rangeSince: cutoff)
            guard myGen == refreshGen else { return }
            cached = Cached(
                rows: result.rows.map { dto in
                    ModelRow(
                        model: dto.model,
                        displayName: shortModel(dto.model),
                        cost: dto.cost,
                        inputTokens: dto.inputTokens,
                        outputTokens: dto.outputTokens,
                        cacheReadTokens: dto.cacheReadTokens,
                        totalTokens: dto.totalTokens,
                        activeDays: dto.activeDays,
                        firstSeen: dto.firstSeen,
                        lastSeen: dto.lastSeen
                    )
                },
                dailyMix: result.dailyMix.map { dto in
                    DailyMix(
                        date: dto.date,
                        model: dto.model,
                        displayName: shortModel(dto.model),
                        tokens: dto.tokens
                    )
                }
            )
            hasLoaded = true
        }
    }

    var body: some View {
        Group {
            if !hasLoaded {
                loadingState
            } else if rows.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    shareCard
                    trendCard
                    listCard
                }
            }
        }
        .onAppear { refreshCache() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshCache() }
    }

    private var loadingState: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Rolling up models…")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var emptyState: some View {
        Text("No model activity in the selected range.")
            .foregroundStyle(.secondary)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var shareCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Token share")
                .font(.title2.weight(.semibold))
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
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(formatTokens(row.totalTokens))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 90, alignment: .trailing)
                            if total > 0 {
                                Text("\(Int(Double(row.totalTokens) / Double(total) * 100))%")
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

    private var trendCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trend")
                .font(.title2.weight(.semibold))
            Chart(dailyMix) { d in
                BarMark(
                    x: .value("Date", d.date),
                    y: .value("Tokens", d.tokens)
                )
                .foregroundStyle(by: .value("Model", d.displayName))
            }
            .frame(height: 200)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.18))
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(formatTokens(Int64(v)))
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

    private var listCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("All models")
                    .font(.title2.weight(.semibold))
                Spacer()
                Text("\(rows.count) model\(rows.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Model").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("Tokens").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .trailing)
                Text("Days").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
                Text("Last seen").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .trailing)
                Text("Cost").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .trailing)
            }
            Divider()
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.displayName)
                            .font(.system(.body, design: .monospaced))
                        Text(row.model)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(formatTokens(row.totalTokens))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 100, alignment: .trailing)
                    Text("\(row.activeDays)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                    Text(row.lastSeen)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 100, alignment: .trailing)
                    Text(formatCost(row.cost))
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .frame(width: 80, alignment: .trailing)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func shortModel(_ name: String) -> String {
        if let lastSlash = name.lastIndex(of: "/") {
            return String(name[name.index(after: lastSlash)...])
        }
        return name
    }

    private func formatCost(_ usd: Double) -> String {
        if usd >= 1_000 { return String(format: "$%.0f", usd) }
        if usd >= 100   { return String(format: "$%.0f", usd) }
        if usd >= 10    { return String(format: "$%.1f", usd) }
        return String(format: "$%.2f", usd)
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
}
