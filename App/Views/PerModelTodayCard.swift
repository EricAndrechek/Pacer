import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// Today's per-model breakdown: the shared donut beside the shared usage
/// table in its narrow form (Total, Out %, Write %, Cost; the token parts are
/// in the header's menu). Pulls from `DailyAggregate` filtered to today —
/// same source as `TodayDetailsCard` but kept as its own card so the @Query
/// stays scoped (a model-only view doesn't need to invalidate when the
/// total-cost number changes).
///
/// The donut measures whatever the table is sorted by (cost by default,
/// tokens when sorted by Total), and names that metric in its centre; a
/// hovered wedge shows its share there instead. The table carries every
/// number, so there is no Share column and no number printed twice.
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
        // Read here as well as inside `PacerCard`'s stored closures (#140).
        let rows = self.rows
        let sort = PacerUsageSort(column: sortRaw, descending: sortDescending)
        // Built in the body: a day has a handful of models, and the donut
        // must follow the sort the moment a header is clicked. The hover
        // lives inside the donut, so it does not run this again.
        let donut = PacerShareDonutData(rows: rows, sort: sort, maxSlices: 8)
        PacerCard("Today by model") {
            if rows.isEmpty {
                Text("No usage logged today yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                PacerDonutBesideTable(donut, accessibilityLabel: "Today's \(donut.metric.title.lowercased()) by model") {
                    PacerUsageTable(
                        rows: rows,
                        tableId: "todayByModel",
                        labelTitle: "Model",
                        sort: sort,
                        onSort: { sortRaw = $0.column; sortDescending = $0.descending },
                        defaultColumns: UsageColumn.narrowDefaults)
                }
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
