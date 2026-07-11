import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// Dashboard card for the **scoped per-model** rate-limit windows from
/// `/api/oauth/usage`'s `limits[]` (e.g. a "Fable" weekly cap) — promoted to
/// first-class pace items with the SAME forecast/projected-fill/burn-rate/
/// conformal-band treatment the fixed 5h/7d hero charts get. Each discovered
/// per-model window renders as a `ScopedPaceTile`: used%/pace hero, a burn
/// verdict chip, and a compact projection chart.
///
/// **Fully adaptive by construction.** Nothing here enumerates models, kinds,
/// groups, or severities. It reads back whatever the poller persisted for the
/// most recent poll (`latestBatch`), keeps only the model/surface-scoped rows
/// (the account-wide `session`/`weekly_all` limits are already the 5h/7d hero
/// windows — Decision C), and asks the engine for each identity's forecast. So
/// a new model, a new `kind`, or a removed limit all render with no code change
/// — a removed limit simply isn't in the latest batch and its tile goes quiet.
///
/// The card hides itself entirely when there's no scoped `limits[]` data.
struct LimitsCard: View {
    /// Open the compare-models projection modal for a scoped identity — routed
    /// by the dashboard to the same `PacerModalDestination.projection` used by
    /// the 5h/7d columns (which now accepts any window key / scoped identity).
    let onCompare: ((String) -> Void)?

    init(onCompare: ((String) -> Void)? = nil) { self.onCompare = onCompare }

    @Query(LimitsCard.recentDescriptor) private var recent: [UsageLimitSample]
    @Environment(\.usageEngine) private var engine

    /// Per-identity engine forecast, refreshed when the engine refits.
    @State private var outlooks: [String: UsageIntelligenceEngine.BurnOutlook] = [:]
    @State private var endEstimates: [String: Estimate] = [:]
    @State private var trajectories: [String: BurnTrajectory.Trajectory] = [:]

    /// The most-recent-poll rows only.
    private var batch: [UsageLimitSample] { recent.latestBatch() }

    /// Recent rows, newest first. Bounded so the query never scans the full
    /// append-only history; 300 spans several hours of the current cycle for a
    /// short actual line under each tile (the dashed projection carries the
    /// forecast to reset).
    private static let recentDescriptor: FetchDescriptor<UsageLimitSample> = {
        var d = FetchDescriptor<UsageLimitSample>(
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
        )
        d.fetchLimit = 300
        return d
    }()

    /// Model/surface-scoped rows only (Decision C), binding-first then hottest.
    private var scopedRows: [UsageLimitSample] {
        batch
            .filter { ($0.modelId?.isEmpty == false)
                   || ($0.modelDisplayName?.isEmpty == false)
                   || ($0.surface?.isEmpty == false) }
            .sorted { a, b in
                if a.isActive != b.isActive { return a.isActive && !b.isActive }
                return a.percent > b.percent
            }
    }

    var body: some View {
        let rows = scopedRows
        if rows.isEmpty {
            EmptyView()
        } else {
            PacerCard("Model rate limits", trailing: { bindingSummary(rows) }) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 240, maximum: 420), spacing: 14)],
                    alignment: .leading, spacing: 14
                ) {
                    ForEach(rows, id: \.identity) { row in
                        ScopedPaceTile(
                            row: row,
                            data: liveChartData(for: row),
                            outlook: outlooks[row.identity],
                            endEstimate: endEstimates[row.identity],
                            onTap: onCompare.map { cb in { cb(row.identity) } }
                        )
                    }
                }
            } footer: {
                Text("Per-model windows Anthropic reports for this account, forecast the same way as the 5-hour and 7-day pace — projected fill, time-to-limit, and calibrated bands. The highlighted tile is the one currently binding. Tap a tile to compare every forecast model.")
            }
            .task { await refresh(rows) }
            .onReceive(NotificationCenter.default.publisher(for: .pacerEngineDidRecompute)) { _ in
                Task { await refresh(rows) }
            }
        }
    }

    // MARK: - Trailing binding summary

    @ViewBuilder
    private func bindingSummary(_ rows: [UsageLimitSample]) -> some View {
        if let binding = rows.first(where: { $0.isActive }) {
            Chip(
                text: "\(binding.label) binding",
                systemImage: "target",
                tint: binding.displayBand.color,
                size: .compact
            )
        }
    }

    // MARK: - Chart data (actual line + dashed projection)

    /// The scoped window's duration from its `group` hint (session⇒5h,
    /// weekly⇒7d) — matches `WindowSpec.scopedDuration`, the same value the
    /// engine forecasts against.
    private func duration(for row: UsageLimitSample) -> TimeInterval {
        WindowSpec.scopedDuration(group: row.group)
    }

    /// Actuals for this identity's current cycle + a synthesized "now" tail,
    /// then the engine's selected trajectory re-anchored onto that tail.
    private func liveChartData(for row: UsageLimitSample) -> PaceChartView.Data? {
        guard let resets = row.resetsAt else { return nil }
        let dur = duration(for: row)
        let cycleStart = resets.addingTimeInterval(-dur)
        let now = Date()
        var points = recent
            .filter { $0.identity == row.identity && $0.resetsAt == resets
                   && $0.sampledAt >= cycleStart && $0.sampledAt <= now }
            .sorted { $0.sampledAt < $1.sampledAt }
            .map { PaceChartView.Data.Point(time: $0.sampledAt, value: $0.percent) }
        let tailTime = min(now, resets)
        if points.last?.time != tailTime {
            points.append(.init(time: tailTime, value: row.percent))
        }
        guard points.count >= 1 else { return nil }
        // Layer the projection re-anchored onto the live tail.
        var projection: [PaceChartView.Data.Point]?
        var crossesAt: Date?
        if let traj = trajectories[row.identity], let tail = points.last {
            let rebased = traj.reanchored(toTime: tail.time, value: tail.value)
            let pts = rebased.points.map { PaceChartView.Data.Point(time: $0.at, value: $0.usedPercentage) }
            if pts.count >= 2 { projection = pts; crossesAt = rebased.crossesFullAt }
        }
        return PaceChartView.Data(
            cycleStart: cycleStart, resetsAt: resets, durationSeconds: dur,
            points: points, usedPct: row.percent,
            projection: projection, projectionCrossesFullAt: crossesAt)
    }

    // MARK: - Engine refresh (off-main, like PaceChartCard)

    private func refresh(_ rows: [UsageLimitSample]) async {
        guard let engine else { return }
        let ids = rows.map(\.identity)
        let computed = await Task.detached(priority: .userInitiated) { [engine] in
            var outs: [String: UsageIntelligenceEngine.BurnOutlook] = [:]
            var ends: [String: Estimate] = [:]
            var trajs: [String: BurnTrajectory.Trajectory] = [:]
            for id in ids {
                if let o = await engine.burnOutlook(windowKey: id) { outs[id] = o }
                ends[id] = await engine.ask(.scopedOutlook(id))
                let list = await engine.rateLimitTrajectories(windowKey: id)
                if let chosen = list.first(where: { $0.isSelected }) ?? list.first {
                    trajs[id] = chosen.trajectory
                }
            }
            return (outs, ends, trajs)
        }.value
        outlooks = computed.0
        endEstimates = computed.1
        trajectories = computed.2
    }
}

// MARK: - Tile

/// One scoped per-model window as a pace tile: label + binding marker, a
/// used%/pace hero, the shared burn verdict chip, and a compact projection
/// chart (actual line + dashed forecast). Tapping opens the compare-models
/// projection modal for the identity. Visual polish pending design sign-off.
private struct ScopedPaceTile: View {
    let row: UsageLimitSample
    /// Actual + projection chart data (nil when no live cycle).
    var data: PaceChartView.Data?
    var outlook: UsageIntelligenceEngine.BurnOutlook?
    var endEstimate: Estimate?
    var onTap: (() -> Void)?

    private var duration: TimeInterval { WindowSpec.scopedDuration(group: row.group) }

    /// Linear-pace fraction of the window elapsed (for the pace band coloring).
    private var paceEndPct: Double? {
        guard let resets = row.resetsAt else { return nil }
        return PaceMath.paceFraction(now: Date(), resetsAt: resets, windowDuration: duration) * 100
    }

    private var band: PaceBand? {
        paceEndPct.map { PaceBand(usedPct: row.percent, paceEndPct: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            heroLine
            chipRow
            if let data {
                PaceChartView(data: data, style: .compact)
                    .frame(height: 56)
            }
            if let caption = resetCaption {
                Text(caption).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(row.isActive ? 0.05 : 0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(row.isActive ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .help(onTap != nil ? "Compare every forecast model's projection for \(row.label)" : "")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.label), \(Int(row.percent.rounded()))% used\(row.isActive ? ", binding limit" : "")")
    }

    private var header: some View {
        HStack(spacing: 6) {
            if row.isActive {
                Circle().fill((band?.color ?? .accentColor))
                    .frame(width: 7, height: 7)
            }
            Text(row.label)
                .font(.system(size: 13.5, weight: .medium))
                .lineLimit(1)
            if row.isActive {
                Chip(text: "binding", tint: .accentColor, size: .compact)
            }
            if row.severityValue.isElevated {
                Chip(text: row.severity.lowercased(), tint: row.displayBand.color, size: .compact)
            }
            Spacer(minLength: 4)
        }
    }

    private var heroLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(Int(row.percent.rounded()))%")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(band?.color ?? .secondary)
            if let paceEndPct {
                Text("/").font(.system(size: 13)).foregroundStyle(.tertiary)
                Text("\(Int(paceEndPct.rounded()))%")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var chipRow: some View {
        if let outlook,
           let chip = IntelligenceFormatting.burnChip(
               outlook: outlook, endEstimate: endEstimate,
               duration: duration, usedPct: row.percent) {
            Chip(text: chip.text, systemImage: "flame.fill", tint: chip.tint, size: .compact)
                .fixedSize()
                .help(chip.help)
        }
    }

    private var resetCaption: String? {
        guard let resetsAt = row.resetsAt else { return nil }
        return pacerResetCaption(resetsAt: resetsAt, durationSeconds: duration)
    }
}
