import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// "Today's traffic" — what the day's cost and tokens were made of. The Now
/// strip's Today tile carries the headline (today's cost and today's total
/// tokens), so this card prints neither: it answers the next question, which
/// of the five priced parts they came from, through the shared
/// `PacerCostBreakdownView` — each part's dollars, share and tokens — and
/// the cache hit rate with what the cache saved.
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
                PacerCostBreakdownView(totals.breakdown) {
                    cacheExtras(totals)
                }
            }
        }
    }

    /// What Today adds after the shared cache-hit line: how many times each
    /// written token was read back, and the dollars the cache saved against
    /// a no-cache day. The read and written counts the old sub-line printed
    /// are in the breakdown's legend now (cache reads, 5m and 1h writes).
    @ViewBuilder
    private func cacheExtras(_ totals: Totals) -> some View {
        let savings = totals.cacheSavingsUSD(snapshot: SampleCostCache.current())
        if let reuse = reuseText(totals.cacheReuseFactor) {
            Text("\(reuse) reuse")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .help("Each cache-written token read back \(reuse)")
        }
        if savings > 0 {
            Text("saved \(pacerCost(savings))")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.green)
                .help("Saved \(pacerCostExact(savings)) by reusing cached prompts")
        }
    }

    /// "51×" / "3.2×"; nil when there were no writes (trivially infinite).
    private func reuseText(_ reuse: Double) -> String? {
        guard reuse > 0 else { return nil }
        return reuse >= 10
            ? String(format: "%.0f×", reuse)
            : String(format: "%.1f×", reuse)
    }
}

/// Sums across the day's per-model aggregate rows. Holds the rows
/// themselves (not just the column sums) so per-model pricing can be
/// applied for the savings calculation — a cross-model day priced at
/// a single average rate would mis-attribute Haiku/Opus savings.
private struct Totals {
    let rows: [DailyRow]
    /// The day's cost by priced part with the tokens behind each (#225),
    /// summed from the rows the card already holds — no extra query. Its
    /// hit rate is the shared `TokenBreakdown.cacheHitRatio`, so Today and
    /// Day detail show the same number for the same day.
    let breakdown: CostBreakdown
    let distinctModels: Int

    init(rows: [DailyRow]) {
        self.rows = rows
        self.breakdown = CostBreakdown.sum(rows, \.costBreakdown)
        self.distinctModels = Set(rows.map(\.model)).count
    }

    var isEmpty: Bool {
        let t = breakdown.tokens
        return t.inputTokens == 0 && t.outputTokens == 0 && t.cacheReadTokens == 0
    }

    /// How many times each cache-written token was read back. Tells
    /// you whether the cache writes paid for themselves — a 5m write
    /// costs 1.25× a fresh input token, so anything above 12.5× reuse
    /// is net-positive vs not caching.
    var cacheReuseFactor: Double {
        let t = breakdown.tokens
        guard t.cacheWrite > 0 else { return 0 }
        return Double(t.cacheReadTokens) / Double(t.cacheWrite)
    }

    /// Dollar savings vs. a hypothetical day where every input-side
    /// token (input + cache_read + cache_creation) was billed at the
    /// model's fresh-input rate. Output cost cancels out and is not
    /// included. Per-model so a mixed Opus/Haiku/Sonnet day prices
    /// each row at the right rate.
    ///
    /// Uses base (not above-200k) rates — daily aggregates lose the
    /// per-request tier boundary, so this is a display approximation.
    /// The dominant Claude Code message is under 200k, so the
    /// approximation is within a few percent of invoice-accurate.
    @MainActor
    func cacheSavingsUSD(snapshot: PricingTable.Snapshot) -> Double {
        var total: Double = 0
        // Today's rows, so today's rates from the dated ledger.
        let now = Date()
        for row in rows {
            guard let p = snapshot.ledger.rates(for: row.model, at: now) else { continue }
            let inputRate = p.input
            let cacheReadRate = p.cacheRead
            let cache5mRate = p.cacheWrite5m
            let cache1hRate = p.cacheWrite1h
            let inputSide = row.inputTokens + row.cacheReadTokens
                + row.cacheCreation5mTokens + row.cacheCreation1hTokens
            let hypothetical = Double(inputSide) * inputRate
            let actual = Double(row.inputTokens) * inputRate
                + Double(row.cacheReadTokens) * cacheReadRate
                + Double(row.cacheCreation5mTokens) * cache5mRate
                + Double(row.cacheCreation1hTokens) * cache1hRate
            total += max(0, hypothetical - actual)
        }
        return total
    }
}
