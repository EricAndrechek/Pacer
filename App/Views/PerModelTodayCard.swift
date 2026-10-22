import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// Today's per-model breakdown: the shared donut card (`PacerDonutListCard`),
/// the ring beside the list every donut card has: Mix, Tokens, Cost and Share
/// (`PacerShareListColumn.standard`). Pulls from
/// `DailyAggregate` filtered to today — same source as `TodayDetailsCard` but
/// kept as its own card so the @Query stays scoped (a model-only view
/// doesn't need to invalidate when the total-cost number changes).
///
/// Clicking a column title sorts the list, and the ring measures that column
/// (cost by default, or tokens) and names it in its centre; Share is each
/// model's share of what the ring measures. A hovered wedge shows its share
/// and name there instead. Hit % and Out %, which round 4 listed here, are
/// not shares of anything and are in no donut list (`UsageAmount`); a sort
/// stored by one of them sorts by cost.
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
    /// The table's rows, built once per scan tick or scope switch.
    @State private var rows: [PacerUsageRow<PacerUsageNoExtra>] = []

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

    private func refreshRows() {
        rows = aggregates.map { agg in
            PacerUsageRow(
                id: agg.model,
                label: pacerModelDisplayName(agg.model),
                color: pacerModelColor(agg.model),
                tokens: agg.tokens,
                costParts: agg.cost,
                cost: agg.totalCostUSD)
        }
    }

    var body: some View {
        let rows = self.rows
        let sort = PacerUsageSort(column: sortRaw, descending: sortDescending)
        // Built in the body: a day has a handful of models, and the ring
        // must follow the sort the moment a title is clicked. The hover
        // lives inside the donut, so it does not run this again.
        let data = PacerShareListData(rows: rows, sort: sort, maxSlices: 8)
        Group {
            if rows.isEmpty {
                PacerCard("Today by model") {
                    Text("No usage logged today yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                PacerDonutListCard(
                    "Today by model",
                    data: data,
                    labelTitle: "Model",
                    accessibilityLabel: "Today's \(data.donut.metric.title.lowercased()) by model",
                    onSort: { sortRaw = $0.column; sortDescending = $0.descending })
            }
        }
        .onAppear { refreshRows() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshRows() }
        // The scope is an input to the rows like the data is: without this
        // the card kept the previous account after a switch until a scan
        // ingested something, which on an idle machine may be never (#141).
        .onChange(of: scope.accountId) { _, _ in refreshRows() }
    }
}
