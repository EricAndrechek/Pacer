import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// Today's per-model breakdown, in the shared usage table: every token part,
/// the total, the cost, and each model's share of today's tokens. Pulls from
/// `DailyAggregate` filtered to today — same source as `TodayDetailsCard` but
/// kept as its own card so the @Query stays scoped (a model-only view doesn't
/// need to invalidate when the total-cost number changes).
///
/// It had a token-share donut beside a short legend. The table now carries
/// the share as a column, and a donut beside seven columns would have left the
/// table too narrow to read at the window's minimum width, so the share is
/// shown once, as a number (the "no number twice" rule).
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
    @State private var cached: [PacerUsageRow<TodayModelShare>] = []

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

    private func refreshCache() {
        let totalTokens = aggregates.reduce(Int64(0)) { $0 + $1.tokens.all }
        cached = aggregates.map { agg in
            let share = totalTokens > 0 ? Double(agg.tokens.all) / Double(totalTokens) : 0
            return PacerUsageRow(
                id: agg.model,
                label: pacerModelDisplayName(agg.model),
                color: pacerModelColor(agg.model),
                tokens: agg.tokens,
                cost: agg.totalCostUSD,
                extra: TodayModelShare(share: share))
        }
    }

    var body: some View {
        // Read here as well as inside `PacerCard`'s stored closure (#140).
        let rows = cached
        let sort = PacerUsageSort(column: sortRaw, descending: sortDescending)
        PacerCard("Today by model") {
            if rows.isEmpty {
                Text("No usage logged today yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                PacerUsageTable(
                    rows: rows,
                    tableId: "todayByModel",
                    labelTitle: "Model",
                    sort: sort,
                    onSort: { sortRaw = $0.column; sortDescending = $0.descending }
                ) {
                    PacerUsageColumns.extra(TodayModelShare.column, title: "Share",
                                            of: TodayModelShare.self,
                                            minWidth: 40, idealWidth: 48) { row in
                        Text("\(Int((row.extra.share * 100).rounded()))%")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                            .help("Share of today's tokens")
                    }
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
}

/// A model's share of today's tokens, all five parts (#215).
struct TodayModelShare: PacerUsageExtra {
    static let column = "share"
    let share: Double

    func sortKey(forColumn id: String) -> PacerUsageSortKey? {
        id == Self.column ? .number(share) : nil
    }
}
