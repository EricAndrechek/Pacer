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

    @Test("the parts run in prompt order, then output")
    func promptOrderThenOutput() {
        // The cached prefix, what is being cached now (1h before 5m, as
        // Anthropic orders breakpoints), the uncached tail, then the reply.
        let order: [CostComponent] = CostComponent.allCases
        #expect(order == [.cacheRead, .cacheWrite1h, .cacheWrite5m, .input, .output])
        // Only the drawing order moved: the raw values are the stable names.
        let raw: [String] = order.map(\.rawValue)
        #expect(raw == ["cacheRead", "cacheWrite1h", "cacheWrite5m", "input", "output"])
        #expect(CostComponent.input.label == "Uncached input")
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
        // Reads, 1h writes, 5m writes, uncached input, output.
        #expect(parts.map(\.percent) == [65, 13, 15, 0, 7])
        // Input is real money, just under a whole percent: it says so rather
        // than claiming 0%.
        #expect(parts[3].percentLabel == "<1%")
        #expect(parts[0].percentLabel == "65%")

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

    @Test("every pair of parts stays apart under red- and green-weak vision, light and dark",
          arguments: [NSAppearance.Name.aqua, .darkAqua])
    func partsSurviveColourBlindness(_ appearance: NSAppearance.Name) throws {
        // The data-viz CVD check: Machado 2009 at severity 1.0, distance in
        // OKLab ×100, target 8. Output at the ridge's purple measured 5.9
        // against the blue reads under protanopia.
        let protan: [[Double]] = [[0.152286, 1.052583, -0.204868],
                                  [0.114503, 0.786281, 0.099216],
                                  [-0.003882, -0.048116, 1.051998]]
        let deutan: [[Double]] = [[0.367322, 0.860646, -0.227968],
                                  [0.280085, 0.672501, 0.047413],
                                  [-0.011820, 0.042940, 0.968881]]
        // Every pair, not just neighbours: a legend puts any two side by side.
        let parts: [CostComponent] = CostComponent.allCases
        var hexes: [String?] = []
        try #require(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
            hexes = parts.map { pacerHexString(from: $0.color) }
        }
        let linear: [[Double]] = try hexes.map { try #require(Self.linearRGB($0)) }
        for i in 0..<parts.count {
            for j in (i + 1)..<parts.count {
                for m in [protan, deutan] {
                    let a: [Double] = Self.oklab(Self.apply(m, linear[i]))
                    let b: [Double] = Self.oklab(Self.apply(m, linear[j]))
                    let d: Double = Self.distance(a, b) * 100
                    #expect(d >= 8, "\(appearance.rawValue) \(parts[i]) vs \(parts[j]): ΔE \(d)")
                }
            }
        }
    }

    @Test("output is a deep violet on light backgrounds and a lavender on dark ones")
    func outputPurpleFollowsTheAppearance() throws {
        var light: String?, dark: String?
        try #require(NSAppearance(named: .aqua)).performAsCurrentDrawingAppearance {
            light = pacerHexString(from: CostComponent.output.color)
        }
        try #require(NSAppearance(named: .darkAqua)).performAsCurrentDrawingAppearance {
            dark = pacerHexString(from: CostComponent.output.color)
        }
        #expect(light == "#6F3BB2")
        #expect(dark == "#BC88F4")
    }

    private static func linearRGB(_ hex: String?) -> [Double]? {
        guard let hex, hex.count >= 7, let v = UInt32(hex.dropFirst().prefix(6), radix: 16) else { return nil }
        let channels: [Double] = [Double((v >> 16) & 0xff), Double((v >> 8) & 0xff), Double(v & 0xff)]
        return channels.map { c in
            let x: Double = c / 255
            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
    }

    private static func apply(_ m: [[Double]], _ v: [Double]) -> [Double] {
        m.map { row in min(max(row[0] * v[0] + row[1] * v[1] + row[2] * v[2], 0), 1) }
    }

    private static func oklab(_ rgb: [Double]) -> [Double] {
        let l: Double = cbrt(0.4122214708 * rgb[0] + 0.5363325363 * rgb[1] + 0.0514459929 * rgb[2])
        let m: Double = cbrt(0.2119034982 * rgb[0] + 0.6806995451 * rgb[1] + 0.1073969566 * rgb[2])
        let s: Double = cbrt(0.0883024619 * rgb[0] + 0.2817188376 * rgb[1] + 0.6299787005 * rgb[2])
        let lightness: Double = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let a: Double = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let b: Double = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        return [lightness, a, b]
    }

    private static func distance(_ x: [Double], _ y: [Double]) -> Double {
        let d0: Double = x[0] - y[0], d1: Double = x[1] - y[1], d2: Double = x[2] - y[2]
        return (d0 * d0 + d1 * d1 + d2 * d2).squareRoot()
    }

    @Test("a cost bar's tooltip names all five parts, in order, with exact dollars")
    func barHelpListsEveryPart() {
        let lines = pacerCostBreakdownHelp(CostBreakdown(cost: realMix))
            .split(separator: "\n").map(String.init)
        #expect(lines.count == 5)
        for (line, part) in zip(lines, CostComponent.allCases) {
            #expect(line.hasPrefix(part.label + ": "))
        }
        #expect(lines[0].hasSuffix("(65%)"))
    }

    @Test("the hit rate never rounds up to a perfect 100%")
    func cacheHitTextCapsShortOfEverything() {
        #expect(pacerCacheHitText(0.981) == "98.1%")
        // 99.96% would round to "100.0%", claiming the cache missed nothing.
        #expect(pacerCacheHitText(0.9996) == "99.9%")
        #expect(pacerCacheHitText(0.99949) == "99.9%")
        #expect(pacerCacheHitText(1) == "100.0%")
        #expect(pacerCacheHitText(0) == "0.0%")
    }
}
