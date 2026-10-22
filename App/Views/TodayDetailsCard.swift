import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// "Today's traffic" — what the day's cost and tokens were made of. The Now
/// strip's Today tile carries the headline (today's cost and today's total
/// tokens), so this card prints neither: it answers the next question, which
/// of the five priced parts they came from, through the shared
/// `PacerCostBreakdownView` — each part's dollars, share and tokens — and
/// the day's cache hit rate under them.
struct TodayDetailsCard: View {
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

    init(scopeAccountId: String? = nil) {
        let today = TokenSample.formatDate(Date())
        _globalAggregates = Query(
            filter: #Predicate<DailyAggregate> { $0.date == today }
        )
        // Taken as a parameter rather than read from `UsageScope` here, so a
        // scope change re-runs this initialiser. A `@Query` predicate is
        // captured once at init; reading the scope inside would pin the card
        // to whichever account was selected when it first appeared.
        let acct = scopeAccountId ?? UsageScope.noAccountSentinel
        _scopedAggregates = Query(
            filter: #Predicate<AccountDailyAggregate> {
                $0.date == today && $0.accountId == acct
            }
        )
    }

    private var totals: Totals { Totals(rows: aggregates) }

    var body: some View {
        // Fold the day's rows once per render — `totals` is a computed
        // property read several times below.
        let totals = totals
        return PacerCard("Today's traffic", trailing: {
            HStack(spacing: 8) {
                if !totals.isEmpty {
                    // Today's total tokens are on the Now strip's Today tile;
                    // here they are the tooltip, not a second printed copy.
                    Text("\(totals.distinctModels) model\(totals.distinctModels == 1 ? "" : "s")")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .help("\(pacerTokensExact(totals.breakdown.tokens.all)) tokens across \(totals.distinctModels) model\(totals.distinctModels == 1 ? "" : "s")")
                }
                Text(TokenSample.formatDate(Date()))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }) {
            if totals.isEmpty {
                Text("No usage logged today yet. Pacer will write within seconds of any Claude Code activity.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                PacerCostBreakdownView(totals.breakdown)
            }
        }
    }
}

/// The day's rows folded into what the card shows.
private struct Totals {
    /// The day's cost by priced part with the tokens behind each (#225),
    /// summed from the rows the card already holds — no extra query. Its
    /// hit rate is the shared `TokenBreakdown.cacheHitRatio`, so Today and
    /// Day detail show the same number for the same day.
    let breakdown: CostBreakdown
    let distinctModels: Int

    init(rows: [DailyRow]) {
        self.breakdown = CostBreakdown.sum(rows, \.costBreakdown)
        self.distinctModels = Set(rows.map(\.model)).count
    }

    var isEmpty: Bool {
        let t = breakdown.tokens
        return t.inputTokens == 0 && t.outputTokens == 0 && t.cacheReadTokens == 0
    }
}
