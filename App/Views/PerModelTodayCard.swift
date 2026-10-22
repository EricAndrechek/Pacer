import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// Today's per-model breakdown: the token-share donut on the left, the shared
/// usage table on the right in its narrow form (Total, Out %, Write %, Cost;
/// the token parts are in the header's menu). Pulls from `DailyAggregate`
/// filtered to today — same source as `TodayDetailsCard` but kept as its own
/// card so the @Query stays scoped (a model-only view doesn't need to
/// invalidate when the total-cost number changes).
///
/// The donut is the share, so the table has no Share column: one encoding,
/// and no number printed twice. Hovering a wedge names its model and share in
/// the card's header, as it always did.
struct PerModelTodayCard: View {
    @Query private var globalAggregates: [DailyAggregate]
    /// The same rollup sliced to one account. Which of the two is
    /// rendered is the scope switch; the card's layout does not change.
    @Query private var scopedAggregates: [AccountDailyAggregate]
    @State private var scope = UsageScope.shared

    /// What the card renders: every account, or one. Both queries are
    /// live, so switching is a re-read rather than a recompute.
    private var aggregates: [DailyRow] {
        scope.isAll
            ? globalAggregates.map(\.dailyRow)
            : scopedAggregates.map(\.dailyRow)
    }
    @Query(PerModelTodayCard.scanMetaProbe) private var scanMeta: [ClaudeCodeMeta]
    @State private var cached = Cached()

    /// Selected wedge in the donut. Bound via `chartAngleSelection`
    /// — Charts hands us the angle hovered, mapped back to a row by
    /// accumulating slice widths (`Cached.cumulative`).
    @State private var hoveredAngle: Double?

    @AppStorage("pacer.todayByModel.sortField", store: PacerSettings.store)
    private var sortRaw: String = UsageColumn.cost.rawValue
    @AppStorage("pacer.todayByModel.sortDescending", store: PacerSettings.store)
    private var sortDescending: Bool = true

    init(scopeAccountId: String? = nil) {
        let todayString = TokenSample.formatDate(Date())
        _globalAggregates = Query(
            filter: #Predicate<DailyAggregate> { $0.date == todayString },
            sort: \.totalCostUSD,
            order: .reverse
        )
        let acct = scopeAccountId ?? UsageScope.noAccountSentinel
        _scopedAggregates = Query(
            filter: #Predicate<AccountDailyAggregate> {
                $0.date == todayString && $0.accountId == acct
            },
            sort: \AccountDailyAggregate.totalCostUSD,
            order: .reverse
        )
    }

    private static let scanMetaProbe: FetchDescriptor<ClaudeCodeMeta> = {
        let key = ClaudeCodeMetaKey.lastIncrementalScanAt
        return FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key }
        )
    }()

    /// Everything the card draws, built once per scan tick or scope switch.
    private struct Cached {
        var rows: [PacerUsageRow<PacerUsageNoExtra>] = []
        /// The donut's wedges, largest first.
        var slices: [PacerDonutSlice] = []
        /// Each wedge's end angle (running token total), for hover lookups:
        /// O(models) per pointer move over an array built here, not a
        /// `reduce` per move.
        var cumulative: [(id: String, label: String, end: Double)] = []
        var totalTokens: Int64 = 0
    }

    private func refreshCache() {
        let rows = aggregates
        var next = Cached()
        next.rows = rows.map { agg in
            PacerUsageRow(
                id: agg.model,
                label: pacerModelDisplayName(agg.model),
                color: pacerModelColor(agg.model),
                tokens: agg.tokens,
                costParts: agg.cost,
                cost: agg.totalCostUSD)
        }
        // The donut's order is its own, largest wedge first: the table can be
        // sorted any way, and the wedges and the hover table must walk one
        // array or a hover names the wrong model.
        let byTokens = rows.sorted {
            $0.tokens.all != $1.tokens.all ? $0.tokens.all > $1.tokens.all : $0.model < $1.model
        }
        var running = 0.0
        for agg in byTokens {
            let tokens = agg.tokens.all
            next.slices.append(PacerDonutSlice(id: agg.model, value: Double(tokens),
                                               color: pacerModelColor(agg.model)))
            running += Double(tokens)
            next.cumulative.append((agg.model, pacerModelDisplayName(agg.model), running))
            next.totalTokens += tokens
        }
        cached = next
    }

    /// The wedge under the pointer: its model id, name, and share of today's
    /// tokens.
    private func hovered(_ cached: Cached) -> (id: String, label: String, share: Double)? {
        guard let angle = hoveredAngle, cached.totalTokens > 0,
              let last = cached.cumulative.last else { return nil }
        var previous = 0.0
        for entry in cached.cumulative {
            if angle <= entry.end {
                return (entry.id, entry.label, (entry.end - previous) / Double(cached.totalTokens))
            }
            previous = entry.end
        }
        let start = cached.cumulative.dropLast().last?.end ?? 0
        return (last.id, last.label, (last.end - start) / Double(cached.totalTokens))
    }

    var body: some View {
        // Read here as well as inside `PacerCard`'s stored closures (#140).
        let cached = self.cached
        let hover = hovered(cached)
        let sort = PacerUsageSort(column: sortRaw, descending: sortDescending)
        PacerCard("Today by model", trailing: {
            // The hovered wedge's model and share. A tooltip-like readout,
            // shown only while the pointer is on the donut.
            if let hover {
                HStack(spacing: 8) {
                    Text(hover.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("\(Int((hover.share * 100).rounded()))%")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            }
        }) {
            if cached.rows.isEmpty {
                Text("No usage logged today yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 24) {
                    PacerDonut(
                        slices: cached.slices,
                        innerRatio: 0.62,
                        size: 140,
                        hoveredID: hover?.id,
                        hoveredAngle: $hoveredAngle,
                        accessibilityLabel: "Today's token share by model",
                        accessibilityValue: shareSummary(cached)
                    )
                    PacerUsageTable(
                        rows: cached.rows,
                        tableId: "todayByModel",
                        labelTitle: "Model",
                        sort: sort,
                        onSort: { sortRaw = $0.column; sortDescending = $0.descending },
                        defaultColumns: UsageColumn.narrowDefaults)
                }
            }
        }
        .onAppear { refreshCache() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshCache() }
        // The scope is an input to the cache like the data is: without this
        // the card kept the previous account after a switch until a scan
        // ingested something, which on an idle machine may be never (#141).
        .onChange(of: scope.accountId) { _, _ in refreshCache() }
    }

    /// What VoiceOver reads in place of the donut: each model's share.
    private func shareSummary(_ cached: Cached) -> String {
        guard cached.totalTokens > 0 else { return "no data yet" }
        return cached.slices.prefix(5).map { slice in
            let pct = Int((slice.value / Double(cached.totalTokens) * 100).rounded())
            return "\(pacerModelDisplayName(slice.id)) \(pct) percent"
        }.joined(separator: ", ")
    }
}
