import Foundation
import Testing
@testable import PacerCore

/// "Tokens" means all five parts, everywhere (#215).
///
/// On a real store cache reads and writes are ~98% of every token, so a
/// surface that counts input + output alone ranks and sizes by almost nothing.
/// The fixtures here are cache-dominated on purpose: under the old input +
/// output sum, the June day would top "Heaviest token days" while costing the
/// least.
@Suite("Token totals")
@MainActor
struct TokenTotalsTests {

    // Every column a different power of ten, so a swapped or dropped column
    // changes the answer rather than hiding behind an equal neighbour.
    private static let input: Int64 = 1
    private static let output: Int64 = 20
    private static let cacheRead: Int64 = 300
    private static let write5m: Int64 = 4_000
    private static let write1h: Int64 = 50_000

    private static var distinct: TokenBreakdown {
        TokenBreakdown(
            inputTokens: input, outputTokens: output, cacheReadTokens: cacheRead,
            cacheCreation5mTokens: write5m, cacheCreation1hTokens: write1h)
    }

    // MARK: - The definition

    @Test("each accessor sums exactly its columns")
    func accessorsSumTheirColumns() {
        let t: TokenBreakdown = Self.distinct
        let all: Int64 = t.all
        let uncached: Int64 = t.uncached
        let cacheWrite: Int64 = t.cacheWrite
        #expect(all == 54_321)
        #expect(uncached == 21)
        #expect(cacheWrite == 54_000)
        #expect(t.cacheReadTokens == 300)
    }

    @Test("adding breakdowns adds every column")
    func addingAddsEveryColumn() {
        var sum: TokenBreakdown = .zero
        sum += Self.distinct
        sum += Self.distinct
        let all: Int64 = sum.all
        #expect(all == 108_642)
        #expect(sum.cacheCreation1hTokens == 100_000)
    }

    // MARK: - Every rollup reaches it the same way

    @Test("the daily rollups map their columns")
    func dailyRollupsMap() {
        let expected: TokenBreakdown = Self.distinct
        let global = DailyAggregate(
            date: "2026-10-01", model: "claude-opus-5",
            inputTokens: Self.input, outputTokens: Self.output,
            cacheReadTokens: Self.cacheRead,
            cacheCreation5mTokens: Self.write5m, cacheCreation1hTokens: Self.write1h,
            totalCostUSD: 1)
        let scoped = AccountDailyAggregate(
            accountId: "org-a", date: "2026-10-01", model: "claude-opus-5",
            inputTokens: Self.input, outputTokens: Self.output,
            cacheReadTokens: Self.cacheRead,
            cacheCreation5mTokens: Self.write5m, cacheCreation1hTokens: Self.write1h,
            totalCostUSD: 1)
        #expect(global.tokens == expected)
        #expect(scoped.tokens == expected)
        #expect(global.dailyRow.tokens == expected)
        #expect(scoped.dailyRow.tokens == expected)
    }

    @Test("the hourly rollups map their columns, cache included")
    func hourlyRollupsMap() {
        let expected: TokenBreakdown = Self.distinct
        let global = HourlyAggregate(
            date: "2026-10-01", hour: 9, model: "claude-opus-5",
            inputTokens: Self.input, outputTokens: Self.output,
            cacheReadTokens: Self.cacheRead,
            cacheCreation5mTokens: Self.write5m, cacheCreation1hTokens: Self.write1h,
            totalCostUSD: 1, sampleCount: 1)
        let scoped = AccountHourlyAggregate(
            accountId: "org-a", date: "2026-10-01", hour: 9, model: "claude-opus-5",
            inputTokens: Self.input, outputTokens: Self.output,
            cacheReadTokens: Self.cacheRead,
            cacheCreation5mTokens: Self.write5m, cacheCreation1hTokens: Self.write1h,
            totalCostUSD: 1)
        #expect(global.tokens == expected)
        #expect(scoped.tokens == expected)
        // `HourlyRow` carried input and output only, so the Now tile and
        // the hour chart could not count cache even when asked to.
        #expect(global.hourlyRow.tokens == expected)
        #expect(scoped.hourlyRow.tokens == expected)
    }

    @Test("the project rollups map their columns")
    func projectRollupsMap() {
        let expected: TokenBreakdown = Self.distinct
        let global: any ProjectDailyReadable = Self.project("/acme", "2026-10-01", Self.distinct, cost: 1)
        let scoped: any ProjectDailyReadable = AccountProjectDailyAggregate(
            accountId: "org-a", projectPath: "/acme", date: "2026-10-01",
            inputTokens: Self.input, outputTokens: Self.output,
            cacheReadTokens: Self.cacheRead,
            cacheCreation5mTokens: Self.write5m, cacheCreation1hTokens: Self.write1h,
            totalCostUSD: 1, sessionCount: 1, modelCount: 1,
            lastActive: Date(timeIntervalSince1970: 0), sessionIdsJSON: Data(),
            modelTokensJSON: Data(), modelCostJSON: Data())
        #expect(global.tokens == expected)
        #expect(scoped.tokens == expected)
        #expect(global.costBreakdown.tokens == expected)
    }

    @Test("the session rollups map their cumulative columns")
    func sessionRollupsMap() {
        let expected: TokenBreakdown = Self.distinct
        let at = Date(timeIntervalSince1970: 1_780_000_000)
        let global = SessionInfo(
            sessionId: "s1", firstSeenAt: at, lastSeenAt: at, projectPath: "/acme",
            ccVersion: nil, cumulativeCostUSD: 1,
            cumulativeInputTokens: Self.input, cumulativeOutputTokens: Self.output,
            cumulativeCacheReadTokens: Self.cacheRead,
            cumulativeCacheCreation5mTokens: Self.write5m,
            cumulativeCacheCreation1hTokens: Self.write1h, topModel: "claude-opus-5")
        let scoped = AccountSessionInfo(
            accountId: "org-a", sessionId: "s1", firstSeenAt: at, lastSeenAt: at,
            projectPath: "/acme", ccVersion: nil, cumulativeCostUSD: 1,
            cumulativeInputTokens: Self.input, cumulativeOutputTokens: Self.output,
            cumulativeCacheReadTokens: Self.cacheRead,
            cumulativeCacheCreation5mTokens: Self.write5m,
            cumulativeCacheCreation1hTokens: Self.write1h, topModel: "claude-opus-5")
        #expect(global.tokens == expected)
        #expect(scoped.tokens == expected)
        #expect(global.sessionRow.tokens == expected)
        #expect(scoped.sessionRow.tokens == expected)
    }

    // MARK: - Top days

    private static func day(
        _ date: String, _ model: String,
        input: Int64, output: Int64, read: Int64, w5m: Int64, w1h: Int64, cost: Double
    ) -> DailyRow {
        DailyRow(
            date: date, model: model,
            inputTokens: input, outputTokens: output, cacheReadTokens: read,
            cacheCreation5mTokens: w5m, cacheCreation1hTokens: w1h,
            totalCostUSD: cost)
    }

    /// A June day of heavy fresh input and little cache, then three autumn
    /// days that are almost all cache reads and cost far more. 2026-10-01 is
    /// split across two models so the fold has to add them.
    private static var cacheDominatedDays: [DailyRow] {
        [
            day("2026-06-15", "claude-sonnet-5",
                input: 20_000_000, output: 500_000, read: 2_000_000,
                w5m: 100_000, w1h: 0, cost: 40),
            day("2026-09-20", "claude-opus-5",
                input: 20_000, output: 200_000, read: 80_000_000,
                w5m: 2_000_000, w1h: 500_000, cost: 70),
            day("2026-10-01", "claude-opus-5",
                input: 40_000, output: 300_000, read: 250_000_000,
                w5m: 6_000_000, w1h: 2_000_000, cost: 210),
            day("2026-10-01", "claude-haiku-5",
                input: 10_000, output: 100_000, read: 50_000_000,
                w5m: 2_000_000, w1h: 0, cost: 50),
            day("2026-10-02", "claude-opus-5",
                input: 30_000, output: 300_000, read: 150_000_000,
                w5m: 4_000_000, w1h: 1_000_000, cost: 130),
        ]
    }

    @Test("ranked by tokens, days come out in the same order as by cost")
    func topDaysTokensAgreeWithCost() {
        let rows: [DailyRow] = Self.cacheDominatedDays
        let byTokens: [String] = DayRanking.ranked(rows, by: .tokens, descending: true).map(\.date)
        let byCost: [String] = DayRanking.ranked(rows, by: .cost, descending: true).map(\.date)
        #expect(byTokens == byCost)
        #expect(byTokens == ["2026-10-01", "2026-10-02", "2026-09-20", "2026-06-15"])
    }

    @Test("the fixture really is the case input + output ranks wrongly")
    func uncachedRankingWouldDisagree() {
        let totals: [DayTotal] = DayRanking.totals(Self.cacheDominatedDays)
        let june = totals.first { $0.date == "2026-06-15" }
        let october = totals.first { $0.date == "2026-10-01" }
        let juneUncached: Int64 = june?.tokens.uncached ?? 0
        let octoberUncached: Int64 = october?.tokens.uncached ?? 0
        let octoberAll: Int64 = october?.tokens.all ?? 0
        #expect(juneUncached > octoberUncached)
        #expect(octoberAll == 310_450_000)
    }

    @Test("a day's total folds every model and every part")
    func dayTotalFoldsModels() {
        let totals: [DayTotal] = DayRanking.totals(Self.cacheDominatedDays)
        let october = totals.first { $0.date == "2026-10-01" }
        let cost: Double = october?.cost ?? 0
        let writes: Int64 = october?.tokens.cacheWrite ?? 0
        #expect(abs(cost - 260) < 1e-9)
        #expect(writes == 10_000_000)
        #expect(totals.count == 4)
    }

    @Test("ascending and tied rankings are deterministic")
    func rankingTiesBreakOnDate() {
        let rows: [DailyRow] = [
            Self.day("2026-10-03", "m", input: 1, output: 1, read: 8, w5m: 0, w1h: 0, cost: 1),
            Self.day("2026-10-01", "m", input: 1, output: 1, read: 8, w5m: 0, w1h: 0, cost: 1),
            Self.day("2026-10-02", "m", input: 0, output: 0, read: 1, w5m: 0, w1h: 0, cost: 0.5),
        ]
        let ascending: [String] = DayRanking.ranked(rows, by: .tokens, descending: false).map(\.date)
        let byDate: [String] = DayRanking.ranked(rows, by: .date, descending: true).map(\.date)
        #expect(ascending == ["2026-10-02", "2026-10-01", "2026-10-03"])
        #expect(byDate == ["2026-10-03", "2026-10-02", "2026-10-01"])
    }

    // MARK: - One project, three screens

    private static func project(
        _ path: String, _ date: String, _ t: TokenBreakdown, cost: Double
    ) -> ProjectDailyAggregate {
        ProjectDailyAggregate(
            projectPath: path, date: date,
            inputTokens: t.inputTokens, outputTokens: t.outputTokens,
            cacheReadTokens: t.cacheReadTokens,
            cacheCreation5mTokens: t.cacheCreation5mTokens,
            cacheCreation1hTokens: t.cacheCreation1hTokens,
            totalCostUSD: cost, sessionCount: 1, modelCount: 1,
            lastActive: Date(timeIntervalSince1970: 1_780_000_000))
    }

    private static func parts(_ read: Int64, _ w5m: Int64, _ w1h: Int64) -> TokenBreakdown {
        TokenBreakdown(
            inputTokens: 1_000, outputTokens: 20_000, cacheReadTokens: read,
            cacheCreation5mTokens: w5m, cacheCreation1hTokens: w1h)
    }

    private static var projectRows: [ProjectDailyAggregate] {
        [
            project("/acme", "2026-10-01", parts(90_000_000, 3_000_000, 1_000_000), cost: 80),
            project("/acme", "2026-10-02", parts(40_000_000, 1_500_000, 0), cost: 35),
            project("/acme", "2026-10-03", parts(10_000_000, 200_000, 50_000), cost: 9),
            project("/globex", "2026-10-02", parts(70_000_000, 2_000_000, 400_000), cost: 60),
        ]
    }

    @Test("Project detail and the Projects list give one project the same total")
    func projectDetailMatchesProjectsList() {
        let range: [any ProjectDailyReadable] = Self.projectRows
        let acmeOnly: [any ProjectDailyReadable] = range.filter { $0.projectPath == "/acme" }
        // Projects: every project in the range, folded per path.
        let listed: ProjectUsageTotals? = CollectionUsageRollup.perPathTotals(from: range)["/acme"]
        // Project detail: that project's rows in the same range.
        let detail = ProjectUsageTotals(rows: acmeOnly)
        let listedAll: Int64 = listed?.tokens.all ?? -1
        let detailAll: Int64 = detail.tokens.all
        #expect(listedAll == detailAll)
        #expect(listed?.tokens == detail.tokens)
        #expect(detailAll == 145_813_000)
        let cost: Double = listed?.cost ?? 0
        #expect(abs(cost - detail.cost) < 1e-9)
    }

    @Test("Day detail gives a project the same total Project detail does for that day")
    func dayDetailMatchesProjectDetail() {
        let day: [any ProjectDailyReadable] = Self.projectRows.filter { $0.date == "2026-10-02" }
        let acmeDay: [any ProjectDailyReadable] = day.filter { $0.projectPath == "/acme" }
        let dayDetail: ProjectUsageTotals? = CollectionUsageRollup.perPathTotals(from: day)["/acme"]
        let projectDetail = ProjectUsageTotals(rows: acmeDay)
        let dayAll: Int64 = dayDetail?.tokens.all ?? -1
        let detailAll: Int64 = projectDetail.tokens.all
        #expect(dayAll == detailAll)
        // All five parts: the cache writes the old sums left out are in it.
        #expect(detailAll == 41_521_000)
    }

    @Test("a collection's total is the sum of its projects' totals")
    func collectionTotalsAddProjects() {
        let range: [any ProjectDailyReadable] = Self.projectRows
        let perPath = CollectionUsageRollup.perPathTotals(from: range)
        let both = CollectionUsageRollup.totals(for: ["/acme", "/globex"], perPath: perPath)
        let acme: Int64 = perPath["/acme"]?.tokens.all ?? 0
        let globex: Int64 = perPath["/globex"]?.tokens.all ?? 0
        #expect(both.tokens.all == acme + globex)
        #expect(both.sessionCount == 4)
    }
}
