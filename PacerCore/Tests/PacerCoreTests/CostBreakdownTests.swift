import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import PacerCore
@testable import PacerUI

private func makeContainer() throws -> ModelContainer {
    try ModelContainer(
        for: DailyAggregate.self, AccountDailyAggregate.self,
        ProjectDailyAggregate.self, AccountProjectDailyAggregate.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
}

/// The cost breakdown (#225): which of the five priced parts made up a cost.
/// What these pin is what the screens promise — the parts add up to the total
/// the page shows, the shares add up to 100, the cache hit rate has one
/// definition, and every colour comes from the one palette.
@Suite("Cost breakdown")
@MainActor
struct CostBreakdownTests {

    /// Close to the real-store mix the issue reported (reads ~66%, 5m writes
    /// 15%, 1h writes 13%, output 7%, input under 0.1%), on a $1,000 total.
    private let realMix = CostComponents(
        input: 0.04, output: 70, cacheRead: 649.96, cacheWrite5m: 150, cacheWrite1h: 130)

    // MARK: The parts and the total

    @Test("the parts add up to the total, in the fixed order")
    func partsSumToTotal() {
        let b = CostBreakdown(cost: realMix)
        let parts = b.parts
        #expect(parts.map(\.component) == CostComponent.allCases)
        #expect(parts.map(\.usd).reduce(0, +) == b.total)
        #expect(abs(parts.map(\.share).reduce(0, +) - 1) < 1e-12)
        #expect(parts.first { $0.component == .cacheRead }?.usd == 649.96)
    }

    @Test("the order does not follow size")
    func orderIsFixed() {
        let outputHeavy = CostBreakdown(cost: CostComponents(input: 1, output: 90, cacheRead: 9))
        let readHeavy = CostBreakdown(cost: CostComponents(input: 1, output: 9, cacheRead: 90))
        #expect(outputHeavy.parts.map(\.component) == readHeavy.parts.map(\.component))
    }

    @Test("the shown percentages add up to exactly 100")
    func percentsSumTo100() {
        let parts = CostBreakdown(cost: realMix).parts
        #expect(parts.map(\.percent).reduce(0, +) == 100)
        #expect(parts.map(\.percent) == [0, 7, 65, 15, 13])
        // Input is real money, just under a whole percent: it says so rather
        // than claiming 0%.
        #expect(parts[0].percentLabel == "<1%")
        #expect(parts[2].percentLabel == "65%")

        // Three equal thirds would floor to 33 + 33 + 33 = 99; the leftover
        // point goes to one of them, not nowhere.
        let thirds = CostBreakdown(cost: CostComponents(input: 1, output: 1, cacheRead: 1))
        #expect(thirds.parts.map(\.percent).reduce(0, +) == 100)
        #expect(thirds.parts.map(\.percent).sorted() == [0, 0, 33, 33, 34])
    }

    @Test("an empty breakdown is all zeros and has no hit rate")
    func emptyBreakdown() {
        let b = CostBreakdown.zero
        #expect(b.total == 0)
        #expect(b.parts.allSatisfy { $0.usd == 0 && $0.share == 0 && $0.percent == 0 })
        #expect(b.parts.allSatisfy { $0.percentLabel == "0%" })
        #expect(b.cacheHitRatio == nil)
    }

    @Test("an unpriced day still shows its hit rate; an empty one shows nothing")
    func cardShowsWhenThereIsSomethingToSay() {
        let unpriced = CostBreakdown(tokens: TokenBreakdown(inputTokens: 10, cacheReadTokens: 90))
        #expect(PacerCostBreakdownView.hasContent(unpriced))
        #expect(unpriced.cacheHitRatio == 0.9)
        #expect(!PacerCostBreakdownView.hasContent(.zero))
        #expect(PacerCostBreakdownView.hasContent(CostBreakdown(cost: CostComponents(output: 1))))
    }

    @Test("float residue from apportioning is not drawn as a negative part")
    func negativeResidueIsClamped() {
        // `CostComponents.apportion` hands its remainder to the 1h tier,
        // which can come out as -1e-17.
        let b = CostBreakdown(cost: CostComponents(output: 2, cacheRead: 3, cacheWrite1h: -1e-17))
        let w1h = b.parts.first { $0.component == .cacheWrite1h }
        #expect(w1h?.usd == 0)
        #expect(w1h?.share == 0)
        #expect(b.parts.map(\.percent).reduce(0, +) == 100)
    }

    // MARK: Cache hit rate

    @Test("cache hit rate is reads over every prompt token, output excluded")
    func cacheHitRatioDefinition() {
        let t = TokenBreakdown(
            inputTokens: 20, outputTokens: 5_000, cacheReadTokens: 900,
            cacheCreation5mTokens: 50, cacheCreation1hTokens: 30)
        #expect(t.promptTokens == 1_000)
        #expect(t.cacheHitRatio == 0.9)
        #expect(CostBreakdown(tokens: t).cacheHitRatio == 0.9)
        // Output alone is not a prompt.
        #expect(TokenBreakdown(outputTokens: 10).cacheHitRatio == nil)
    }

    // MARK: Read from the rollups

    @Test("a day's parts, summed from either daily table, add up to the total it shows")
    func dailyRollupsSumToShownTotal() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let models = ["claude-opus-5", "claude-sonnet-5-5", "claude-haiku-5-5"]
        var global: [DailyAggregate] = []
        var scoped: [AccountDailyAggregate] = []
        for (i, model) in models.enumerated() {
            let c = CostComponents(
                input: 0.013 * Double(i + 1), output: 1.7 / Double(i + 1),
                cacheRead: 9.31 + Double(i), cacheWrite5m: 2.2 * Double(i),
                cacheWrite1h: 1.05)
            let g = DailyAggregate(
                date: "2026-10-08", model: model,
                inputTokens: 100, outputTokens: 2_000, cacheReadTokens: 90_000,
                cacheCreation5mTokens: 4_000, cacheCreation1hTokens: 1_000)
            g.costComponents = c
            let s = AccountDailyAggregate(
                accountId: "org-a", date: "2026-10-08", model: model,
                inputTokens: 100, outputTokens: 2_000, cacheReadTokens: 90_000,
                cacheCreation5mTokens: 4_000, cacheCreation1hTokens: 1_000,
                totalCostUSD: 0)
            s.costComponents = c
            ctx.insert(g)
            ctx.insert(s)
            global.append(g)
            scoped.append(s)
        }

        for rows in [global.map(\.dailyRow), scoped.map(\.dailyRow)] {
            let shownTotal = rows.reduce(0) { $0 + $1.totalCostUSD }
            let b = CostBreakdown.sum(rows, \.costBreakdown)
            #expect(abs(b.parts.map(\.usd).reduce(0, +) - shownTotal) < 1e-9)
            #expect(abs(b.total - shownTotal) < 1e-9)
            #expect(b.tokens.cacheReadTokens == 270_000)
            #expect(b.cacheHitRatio == 270_000.0 / 285_300.0)
        }
        // The row carries the components it was read from, from either table.
        #expect(global[1].dailyRow.cost == global[1].costComponents)
        #expect(global[1].dailyRow.cost == scoped[1].dailyRow.cost)
    }

    @Test("a project's parts, summed from either project table, add up to the total it shows")
    func projectRollupsSumToShownTotal() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        var rows: [any ProjectDailyReadable] = []
        for day in 1...3 {
            let c = CostComponents(
                input: 0.01, output: 0.7 * Double(day), cacheRead: 4.4,
                cacheWrite5m: 1.25, cacheWrite1h: 0.5 * Double(day))
            let g = ProjectDailyAggregate(
                projectPath: "/work/acme", date: "2026-10-0\(day)",
                inputTokens: 10, outputTokens: 500, cacheReadTokens: 8_000,
                cacheCreation5mTokens: 700, cacheCreation1hTokens: 300)
            g.costComponents = c
            let s = AccountProjectDailyAggregate(
                accountId: "org-a", projectPath: "/work/acme", date: "2026-10-0\(day)",
                inputTokens: 10, outputTokens: 500, cacheReadTokens: 8_000,
                cacheCreation5mTokens: 700, cacheCreation1hTokens: 300,
                totalCostUSD: 0, sessionCount: 1, modelCount: 1,
                lastActive: .distantPast, sessionIdsJSON: Data(),
                modelTokensJSON: Data(), modelCostJSON: Data())
            s.costComponents = c
            ctx.insert(g)
            ctx.insert(s)
            rows.append(g)
            rows.append(s)
        }
        let shownTotal = rows.reduce(0) { $0 + $1.totalCostUSD }
        let b = CostBreakdown.sum(rows) { $0.costBreakdown }
        #expect(abs(b.parts.map(\.usd).reduce(0, +) - shownTotal) < 1e-9)
        #expect(b.tokens.cacheCreation1hTokens == 1_800)
        #expect(b.cacheHitRatio == 8_000.0 / 9_010.0)
    }

    // MARK: One palette

    private func hex(_ c: Color) -> String? { pacerHexString(from: c) }

    @Test("every part has its own colour")
    func paletteColorsAreDistinct() {
        let hexes = CostComponent.allCases.compactMap { hex($0.color) }
        #expect(hexes.count == CostComponent.allCases.count)
        #expect(Set(hexes).count == hexes.count)
    }

    @Test("a part's colour, the chart scale and the palette are the same colour")
    func everyUseReadsThePalette() {
        #expect(PacerCostPalette.chartDomain == CostComponent.allCases.map(\.label))
        #expect(PacerCostPalette.chartRange.map(hex)
                == CostComponent.allCases.map { hex(PacerCostPalette.color($0)) })
        for part in CostComponent.allCases {
            #expect(hex(part.color) == hex(PacerCostPalette.color(part)))
        }
    }

    @Test("the two cache-write tiers are warm neighbours, apart from reads")
    func writeTiersReadAsAPair() {
        func gap(_ a: CostComponent, _ b: CostComponent) -> Double {
            let d = abs(PacerCostPalette.hue(a) - PacerCostPalette.hue(b))
            return min(d, 360 - d)
        }
        #expect(gap(.cacheWrite5m, .cacheWrite1h) < 60)
        #expect(gap(.cacheRead, .cacheWrite5m) > 90)
        #expect(gap(.cacheRead, .cacheWrite1h) > 90)
    }

    @Test("a cost bar's tooltip names all five parts, in order, with exact dollars")
    func barHelpListsEveryPart() {
        let lines = pacerCostBreakdownHelp(CostBreakdown(cost: realMix))
            .split(separator: "\n").map(String.init)
        #expect(lines.count == 5)
        for (line, part) in zip(lines, CostComponent.allCases) {
            #expect(line.hasPrefix(part.label + ": "))
        }
        #expect(lines[2].hasSuffix("(65%)"))
    }
}
