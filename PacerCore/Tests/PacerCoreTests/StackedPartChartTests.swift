import Foundation
import Testing
import PacerCore
@testable import PacerUI

/// The pure half of the shared stacked-by-part cost chart: bucketing, the
/// top-three models, stack order, which bars carry a label, the y-domain and
/// where the hover card goes. Expressions are kept short with typed
/// intermediates — long mixed-literal ones time out Xcode 16's type checker
/// on the macOS 15 runner.
struct StackedPartChartTests {

    private func breakdown(
        input: Double = 0, output: Double = 0, read: Double = 0,
        w5m: Double = 0, w1h: Double = 0, tokens: Int64 = 0
    ) -> CostBreakdown {
        let cost = CostComponents(
            input: input, output: output, cacheRead: read,
            cacheWrite5m: w5m, cacheWrite1h: w1h)
        let t = TokenBreakdown(cacheReadTokens: tokens)
        return CostBreakdown(cost: cost, tokens: t)
    }

    /// A row with tokens in every part, so a model's total is `all`, not
    /// one column.
    private func spread(_ usd: Double, input: Int64, output: Int64, read: Int64) -> CostBreakdown {
        let cost = CostComponents(cacheRead: usd)
        let t = TokenBreakdown(
            inputTokens: input, outputTokens: output, cacheReadTokens: read,
            cacheCreation5mTokens: 7, cacheCreation1hTokens: 3)
        return CostBreakdown(cost: cost, tokens: t)
    }

    // MARK: Stack order

    @Test func segmentsStackInComponentOrderAndSkipZeroParts() {
        let b = PacerChartBucket(id: "2026-10-01", breakdown: breakdown(output: 2, read: 5, w1h: 1))
        let order: [CostComponent] = b.segments.map(\.component)
        #expect(order == [.output, .cacheRead, .cacheWrite1h])
    }

    @Test func stackTopIsTheLastNonEmptyPart() {
        let b = PacerChartBucket(id: "2026-10-01", breakdown: breakdown(input: 1, read: 5))
        #expect(b.stackTop == .cacheRead)
        let empty = PacerChartBucket(id: "2026-10-02", breakdown: .zero)
        #expect(empty.stackTop == nil)
        #expect(empty.segments.isEmpty)
    }

    @Test func totalIsThePartsSum() {
        let b = PacerChartBucket(id: "x", breakdown: breakdown(input: 1, output: 2, read: 3))
        let total: Double = b.total
        #expect(abs(total - 6) < 1e-9)
    }

    @Test func activityCountsTokensWithoutAPrice() {
        let unpriced = PacerChartBucket(id: "x", breakdown: breakdown(tokens: 500))
        #expect(unpriced.hasActivity)
        let empty = PacerChartBucket(id: "y", breakdown: .zero)
        #expect(!empty.hasActivity)
    }

    // MARK: Top models

    @Test func topModelsKeepsTheThreeMostExpensive() {
        let costs: [String: Double] = ["a": 1, "b": 9, "c": 4, "d": 6]
        let top: [String] = PacerChartBucket.topModels(costs).map(\.model)
        #expect(top == ["b", "d", "c"])
    }

    @Test func topModelsBreaksTiesByName() {
        let costs: [String: Double] = ["zeta": 2, "alpha": 2, "mid": 2]
        let top: [String] = PacerChartBucket.topModels(costs).map(\.model)
        #expect(top == ["alpha", "mid", "zeta"])
    }

    @Test func topModelsOfFewerThanThreeReturnsThemAll() {
        let top: [PacerChartModelCost] = PacerChartBucket.topModels(["only": 3])
        #expect(top.count == 1)
        #expect(PacerChartBucket.topModels([:]).isEmpty)
    }

    // MARK: Model shares

    @Test func topModelSharesAreOfTheWholeBucket() {
        let costs: [String: Double] = ["a": 6, "b": 3, "c": 0.5, "d": 0.5]
        let top: [PacerChartModelCost] = PacerChartBucket.topModels(costs, of: 10)
        let shares: [Double] = top.map(\.share)
        #expect(abs(shares[0] - 0.6) < 1e-9)
        #expect(abs(shares[1] - 0.3) < 1e-9)
        // Three of four models: their shares sum to what they were, not 1.
        let sum: Double = shares.reduce(0, +)
        #expect(abs(sum - 0.95) < 1e-9)
    }

    @Test func topModelSharesDefaultToTheModelsSum() {
        let costs: [String: Double] = ["a": 3, "b": 1]
        let top: [PacerChartModelCost] = PacerChartBucket.topModels(costs)
        #expect(abs(top[0].share - 0.75) < 1e-9)
        #expect(top[0].percentLabel == "75%")
        #expect(top[1].percentLabel == "25%")
    }

    @Test func aFreeBucketHasNoShares() {
        let costs: [String: Double] = ["unpriced": 0]
        let top: [PacerChartModelCost] = PacerChartBucket.topModels(costs, of: 0)
        #expect(top[0].share == 0)
        #expect(top[0].percentLabel == "0%")
    }

    @Test func aSliverOfTheCostReadsLessThanOnePercent() {
        let sliver = PacerChartModelCost(model: "haiku", usd: 0.01, share: 0.001)
        #expect(sliver.percentLabel == "<1%")
        let none = PacerChartModelCost(model: "free", usd: 0, share: 0)
        #expect(none.percentLabel == "0%")
    }

    @Test func topModelsCarryTheirTokensWhenGiven() {
        let costs: [String: Double] = ["a": 2, "b": 1]
        let tokens: [String: Int64] = ["a": 900, "b": 100]
        let top: [PacerChartModelCost] = PacerChartBucket.topModels(costs, tokens: tokens)
        let counts: [Int64] = top.compactMap(\.tokens)
        let expected: [Int64] = [900, 100]
        #expect(counts == expected)
        let bare: [PacerChartModelCost] = PacerChartBucket.topModels(costs)
        #expect(bare.allSatisfy { $0.tokens == nil })
    }

    // MARK: Bucketing

    @Test func builderSumsRowsPerKeyAndPerModel() {
        var builder = PacerChartBucketBuilder()
        builder.add("2026-10-01", breakdown(read: 3), model: "m1")
        builder.add("2026-10-01", breakdown(output: 1), model: "m2")
        builder.add("2026-10-01", breakdown(read: 2), model: "m1")
        let buckets: [PacerChartBucket] = builder.buckets()
        #expect(buckets.count == 1)
        let day: PacerChartBucket = buckets[0]
        #expect(abs(day.total - 6) < 1e-9)
        let models: [String] = day.topModels.map(\.model)
        #expect(models == ["m1", "m2"])
        let m1: Double = day.topModels[0].usd
        #expect(abs(m1 - 5) < 1e-9)
    }

    @Test func builderSumsEachModelsTokensAcrossItsRows() throws {
        var builder = PacerChartBucketBuilder()
        builder.add("2026-10-01", spread(3, input: 10, output: 20, read: 1_000), model: "opus")
        builder.add("2026-10-01", spread(1, input: 5, output: 5, read: 90), model: "haiku")
        builder.add("2026-10-01", spread(2, input: 10, output: 20, read: 1_000), model: "opus")
        let top: [PacerChartModelCost] = builder.buckets()[0].topModels
        #expect(top.map(\.model) == ["opus", "haiku"])
        // Every part: input + output + reads + both write tiers (7 + 3).
        let opus: Int64 = try #require(top[0].tokens)
        let opusExpected: Int64 = 2 * (10 + 20 + 1_000 + 10)
        #expect(opus == opusExpected)
        let haiku: Int64 = try #require(top[1].tokens)
        let haikuExpected: Int64 = 5 + 5 + 90 + 10
        #expect(haiku == haikuExpected)
    }

    @Test func builderSharesAreOfTheBucketsTotal() {
        var builder = PacerChartBucketBuilder()
        builder.add("k", spread(6, input: 1, output: 1, read: 1), model: "a")
        builder.add("k", spread(2, input: 1, output: 1, read: 1), model: "b")
        builder.add("k", spread(1, input: 1, output: 1, read: 1), model: "c")
        builder.add("k", spread(1, input: 1, output: 1, read: 1), model: "d")
        let top: [PacerChartModelCost] = builder.buckets()[0].topModels
        #expect(top.count == 3)
        #expect(top[0].percentLabel == "60%")
        #expect(top[1].percentLabel == "20%")
    }

    @Test func monthsRollUpEachModelsTokens() throws {
        var builder = PacerChartBucketBuilder()
        let days: [String] = ["2026-10-01", "2026-10-02", "2026-11-01"]
        for day in days {
            guard let month = PacerChartBucket.monthKey(day) else { continue }
            builder.add(month, spread(1, input: 100, output: 0, read: 0), model: "opus")
        }
        let months: [PacerChartBucket] = builder.buckets()
        let october: Int64 = try #require(months[0].topModels[0].tokens)
        let octoberExpected: Int64 = 2 * (100 + 10)
        #expect(october == octoberExpected)
        let november: Int64 = try #require(months[1].topModels[0].tokens)
        let novemberExpected: Int64 = 100 + 10
        #expect(november == novemberExpected)
    }

    @Test func precomputedModelCostsLeaveTokensUnknown() {
        var builder = PacerChartBucketBuilder()
        let costs: [String: Double] = ["opus": 4, "haiku": 1]
        builder.add("2026-10-01", spread(5, input: 9, output: 9, read: 9), modelCosts: costs)
        let top: [PacerChartModelCost] = builder.buckets()[0].topModels
        #expect(top.allSatisfy { $0.tokens == nil })
        #expect(top[0].percentLabel == "80%")
    }

    @Test func builderOrdersByKeyAndKeepsTheNewest() {
        var builder = PacerChartBucketBuilder()
        for day in ["2026-10-03", "2026-10-01", "2026-10-04", "2026-10-02"] {
            builder.add(day, breakdown(read: 1), model: "m")
        }
        let ids: [String] = builder.buckets(last: 2).map(\.id)
        #expect(ids == ["2026-10-03", "2026-10-04"])
    }

    @Test func builderTakesPrecomputedModelCosts() {
        var builder = PacerChartBucketBuilder()
        let costs: [String: Double] = ["opus": 4, "haiku": 1]
        builder.add("2026-10-01", breakdown(read: 5), modelCosts: costs)
        builder.add("2026-10-01", breakdown(read: 1), modelCosts: ["haiku": 1])
        let top: [PacerChartModelCost] = builder.buckets()[0].topModels
        #expect(top.map(\.model) == ["opus", "haiku"])
        #expect(abs(top[1].usd - 2) < 1e-9)
    }

    @Test func hourBucketsFillEveryHour() {
        var builder = PacerChartBucketBuilder()
        builder.add(PacerChartBucket.hourKey(9), breakdown(read: 2), model: "m")
        builder.add(PacerChartBucket.hourKey(14), breakdown(read: 1), model: "m")
        let hours: [PacerChartBucket] = builder.buckets(keys: PacerChartBucket.allHourKeys)
        #expect(hours.count == 24)
        #expect(hours[9].id == "09")
        #expect(hours[9].total > 0)
        #expect(hours[10].total == 0)
        #expect(hours[14].total > 0)
    }

    @Test func hourKeysSortAsHours() {
        let keys: [String] = PacerChartBucket.allHourKeys
        #expect(keys.first == "00")
        #expect(keys.last == "23")
        #expect(keys == keys.sorted())
    }

    @Test func monthBucketsRollDaysUp() {
        var builder = PacerChartBucketBuilder()
        let days = ["2026-09-30", "2026-10-01", "2026-10-31", "bad"]
        for day in days {
            guard let key = PacerChartBucket.monthKey(day) else { continue }
            builder.add(key, breakdown(read: 1), model: "m")
        }
        let months: [PacerChartBucket] = builder.buckets()
        #expect(months.map(\.id) == ["2026-09", "2026-10"])
        #expect(abs(months[1].total - 2) < 1e-9)
    }

    // MARK: Labels and domain

    @Test func theMostExpensiveBarsCarryTheirTotal() {
        let totals: [Double] = [1, 7, 3, 9, 0, 5]
        let buckets: [PacerChartBucket] = totals.enumerated().map { i, v in
            PacerChartBucket(id: "d\(i)", breakdown: breakdown(read: v))
        }
        let top: Set<String> = PacerStackedPartChart.annotatedIDs(buckets, top: 3)
        #expect(top == ["d3", "d1", "d5"])
        #expect(PacerStackedPartChart.annotatedIDs(buckets, top: 0).isEmpty)
    }

    @Test func emptyBarsAreNeverLabelled() {
        let buckets: [PacerChartBucket] = [
            PacerChartBucket(id: "a", breakdown: .zero),
            PacerChartBucket(id: "b", breakdown: breakdown(read: 1)),
        ]
        let top: Set<String> = PacerStackedPartChart.annotatedIDs(buckets, top: 3)
        #expect(top == ["b"])
    }

    @Test func yDomainEndsAtTheTallestBar() {
        let buckets: [PacerChartBucket] = [
            PacerChartBucket(id: "a", breakdown: breakdown(read: 4, w5m: 1)),
            PacerChartBucket(id: "b", breakdown: breakdown(read: 12.5)),
        ]
        let top: Double = PacerStackedPartChart.yMax(buckets)
        #expect(abs(top - 12.5) < 1e-9)
        #expect(PacerStackedPartChart.yMax([]) == 1)
    }

    // MARK: Axis

    @Test func hourAxisMarksFiveHours() {
        let axis = PacerChartXAxis(kind: .hour, ids: PacerChartBucket.allHourKeys)
        #expect(axis.values == ["00", "06", "12", "18", "23"])
        #expect(axis.labelIfMarked("07") == nil)
        #expect(axis.labelIfMarked("12") != nil)
    }

    @Test func monthAxisLabelsADozenAndThinsPastIt() {
        let twelve: [String] = (1...12).map { String(format: "2026-%02d", $0) }
        let axis = PacerChartXAxis(kind: .month, ids: twelve)
        #expect(axis.values == twelve)
        #expect(axis.labelIfMarked("2026-04") == "Apr")

        let long: [String] = (1...12).map { String(format: "2025-%02d", $0) } + twelve
        let thinned: [String] = PacerChartXAxis.monthMarks(long)
        #expect(thinned.count <= 12)
        #expect(thinned.last == "2026-12")
    }

    @Test func monthLabelsCarryTheYearAcrossAYearBoundary() {
        let ids: [String] = ["2025-12", "2026-01"]
        let axis = PacerChartXAxis(kind: .month, ids: ids)
        #expect(axis.labelIfMarked("2026-01") == "Jan ’26")
    }

    @Test func dayAxisUsesTheSharedDateAxis() {
        let ids: [String] = (1...30).map { String(format: "2026-09-%02d", $0) }
        let axis = PacerChartXAxis(kind: .day, ids: ids)
        let shared: [String] = pacerDateAxis(ids).values
        #expect(axis.values == shared)
        #expect(axis.labelIfMarked("2026-09-01") == nil)
    }

    @Test func titlesNameTheBucket() {
        let month = PacerChartXAxis(kind: .month, ids: ["2026-10"])
        #expect(month.title("2026-10").contains("2026"))
        let day = PacerChartXAxis(kind: .day, ids: ["2026-10-21"])
        #expect(day.title("2026-10-21").contains("21"))
        #expect(day.title("not-a-date") == "not-a-date")
    }

    @Test func dayTitlesCarryTheYearOnlyAcrossYears() {
        let one = PacerChartXAxis(kind: .day, ids: ["2026-10-20", "2026-10-21"])
        #expect(!one.title("2026-10-21").contains("2026"))
        let two = PacerChartXAxis(kind: .day, ids: ["2025-12-31", "2026-01-01"])
        #expect(two.title("2026-01-01").contains("2026"))
    }

    // MARK: Hover placement

    private let bounds = CGRect(x: 0, y: 0, width: 800, height: 220)
    private let card = CGSize(width: 300, height: 200)

    @Test func cardSitsRightOfTheBarWhenItFits() {
        let p: CGPoint = PacerHoverPlacement.origin(card: card, anchorX: 100, gap: 12, in: bounds)
        #expect(p.x == 112)
        #expect(p.y == 0)
    }

    @Test func cardFlipsLeftNearTheTrailingEdge() {
        let p: CGPoint = PacerHoverPlacement.origin(card: card, anchorX: 700, gap: 12, in: bounds)
        #expect(p.x == 388)
    }

    @Test func cardIsClampedInsideANarrowChart() {
        let narrow = CGRect(x: 0, y: 0, width: 320, height: 220)
        let p: CGPoint = PacerHoverPlacement.origin(card: card, anchorX: 160, gap: 12, in: narrow)
        #expect(p.x >= 0)
        #expect(p.x + card.width <= narrow.maxX)
    }

    @Test func cardThatFitsNeitherSideTakesTheRoomierOne() {
        let narrow = CGRect(x: 0, y: 0, width: 400, height: 220)
        let nearLeft: CGPoint = PacerHoverPlacement.origin(card: card, anchorX: 150, gap: 12, in: narrow)
        #expect(nearLeft.x == 100)
        let nearRight: CGPoint = PacerHoverPlacement.origin(card: card, anchorX: 250, gap: 12, in: narrow)
        #expect(nearRight.x == 0)
    }

    @Test func placementHonoursAnOffsetBounds() {
        let offset = CGRect(x: 40, y: 10, width: 800, height: 220)
        let p: CGPoint = PacerHoverPlacement.origin(card: card, anchorX: 140, gap: 12, in: offset)
        #expect(p.x == 152)
        #expect(p.y == 10)
    }
}

@Suite("Stacked part chart segment gaps")
struct StackedPartChartGapTests {
    @Test("every segment but the top one gives up the gap; a sliver keeps half its height")
    func spansLeaveAGapBetweenParts() {
        let cost = CostComponents(input: 0.01, output: 2, cacheRead: 5, cacheWrite5m: 1, cacheWrite1h: 0)
        let bucket = PacerChartBucket(id: "2026-10-01", breakdown: CostBreakdown(cost: cost))
        let spans: [PacerStackSpan] = bucket.spans(gap: 0.1)
        #expect(spans.map(\.part.component) == [.input, .output, .cacheRead, .cacheWrite5m])
        // The input sliver is smaller than twice the gap: it keeps half.
        let input: PacerStackSpan = spans[0]
        #expect(abs(input.end - 0.005) < 1e-9)
        // Output starts where input's full value ends, and loses the gap.
        let output: PacerStackSpan = spans[1]
        #expect(abs(output.start - 0.01) < 1e-9)
        #expect(abs(output.end - 1.91) < 1e-9)
        // The top segment is whole, so the bar still reaches the total.
        let top: PacerStackSpan = spans[3]
        #expect(abs(top.end - bucket.total) < 1e-9)
    }
}
