import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// Month-to-date spend and the engine's month-end projection, down in the
/// trends zone with the weekly/30-day cards (a planning number, not a
/// "right now" one). One slim row: hero month-to-date, the projection
/// chip, the spent→projected bar, and the pace context — the calibrated
/// range and exact figures live in tooltips.
struct MonthOutlookCard: View {
    @Query private var aggregates: [DailyAggregate]
    @Query(MonthOutlookCard.scanMetaProbe) private var scanMeta: [ClaudeCodeMeta]

    @Environment(\.usageEngine) private var engine

    @State private var cached = MonthFacts()
    @State private var projection: Estimate?

    struct MonthFacts: Equatable {
        var monthSoFar: Double = 0
        var averageDailyCost: Double = 0
        var daysWithData: Int = 0
        var daysInMonth: Int = 30
        var dayOfMonth: Int = 1
        var hasAnyData: Bool = false
    }

    init() {
        let cal = Calendar.current
        let now = Date()
        let firstOfMonth = cal.dateInterval(of: .month, for: now)?.start ?? now
        let lowerStr = TokenSample.formatDate(firstOfMonth)
        _aggregates = Query(
            filter: #Predicate<DailyAggregate> { $0.date >= lowerStr }
        )
    }

    private static let scanMetaProbe: FetchDescriptor<ClaudeCodeMeta> = {
        let key = ClaudeCodeMetaKey.lastIncrementalScanAt
        return FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key }
        )
    }()

    private func refreshFacts() {
        let cal = Calendar.current
        let now = Date()
        var byDate: [String: Double] = [:]
        for row in aggregates {
            byDate[row.date, default: 0] += row.totalCostUSD
        }
        var next = MonthFacts()
        next.monthSoFar = byDate.values.reduce(0, +)
        let active = byDate.values.filter { $0 > 0 }
        next.daysWithData = active.count
        next.averageDailyCost = active.isEmpty ? 0 : active.reduce(0, +) / Double(active.count)
        next.daysInMonth = cal.range(of: .day, in: .month, for: now)?.count ?? 30
        next.dayOfMonth = cal.component(.day, from: now)
        next.hasAnyData = !active.isEmpty
        cached = next
    }

    private func refreshProjection() async {
        guard let engine else { return }
        projection = await engine.ask(.projectedCost(.thisMonth))
    }

    var body: some View {
        PacerCard("This month", trailing: {
            Text(monthCaption)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }) {
            if cached.hasAnyData {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(pacerCost(cached.monthSoFar)).help(pacerCostExact(cached.monthSoFar))
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        if let p = projection, !p.isInsufficient {
                            Chip(
                                text: "≈\(IntelligenceFormatting.approxCost(p.value)) by month end",
                                systemImage: "chart.line.uptrend.xyaxis",
                                tint: .secondary,
                                size: .compact
                            )
                            .fixedSize()
                            .help(projectionHelp(p))
                        }
                        Spacer(minLength: 0)
                        Text(detailCaption)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let p = projection, !p.isInsufficient,
                       p.value >= cached.monthSoFar * 0.98 {
                        SpendProgressBar(
                            spent: cached.monthSoFar,
                            projected: max(p.value, cached.monthSoFar),
                            projectedLabel: "≈\(IntelligenceFormatting.approxCost(max(p.value, cached.monthSoFar)))",
                            help: projectionHelp(p)
                        )
                    }
                }
            } else {
                Text("Not enough data yet — a projection appears once Pacer has seen some usage this month.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { refreshFacts() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshFacts() }
        .task { await refreshProjection() }
        .onReceive(NotificationCenter.default.publisher(for: .pacerEngineDidRecompute)) { _ in
            Task { await refreshProjection() }
        }
    }

    /// "June · 18 days left"
    private var monthCaption: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMMM"
        let daysLeft = max(0, cached.daysInMonth - cached.dayOfMonth)
        return "\(fmt.string(from: Date())) · \(daysLeft) day\(daysLeft == 1 ? "" : "s") left"
    }

    /// "avg $126 per active day (11)"
    private var detailCaption: String {
        "avg \(pacerCost(cached.averageDailyCost)) per active day (\(cached.daysWithData))"
    }

    /// "↑ 18% above pace" — the engine's projection vs a pure linear
    /// forward-fill of the current run rate. Only meaningful past the
    /// first few days.
    private var paceHint: String? {
        guard let p = projection, !p.isInsufficient else { return nil }
        guard cached.dayOfMonth >= 3 else { return "if rate holds" }
        let purePace = cached.monthSoFar / Double(cached.dayOfMonth) * Double(cached.daysInMonth)
        guard purePace > 0.01 else { return "if rate holds" }
        let ratio = p.value / purePace
        if ratio > 1.05 {
            return String(format: "↑ %.0f%% above pace", (ratio - 1) * 100)
        }
        if ratio < 0.95 {
            return String(format: "↓ %.0f%% below pace", (1 - ratio) * 100)
        }
        return "on pace"
    }

    private func projectionHelp(_ p: Estimate) -> String {
        var parts = [pacerCostExact(p.value)]
        if let band = p.interval80 {
            parts.append(IntelligenceFormatting.anchors(band))
        }
        if let hint = paceHint { parts.append(hint) }
        return parts.joined(separator: " · ")
    }
}
