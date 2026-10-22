import Foundation
import SwiftUI
import Testing
@testable import PacerCore
@testable import PacerUI

/// Each part of the cost breakdown carries its own token count, and the
/// legend prints it (#215 follow-up). What these pin is the mapping: every
/// column has a distinct value, so a part reading its neighbour's column
/// fails rather than passing on equal numbers.
@Suite("Cost breakdown tokens per part")
@MainActor
struct CostBreakdownTokensTests {

    /// A distinct power of ten per column: any swap changes a digit.
    private let tokens = TokenBreakdown(
        inputTokens: 1, outputTokens: 20, cacheReadTokens: 300,
        cacheCreation5mTokens: 4_000, cacheCreation1hTokens: 50_000)

    @Test("each part maps to its own token column")
    func subscriptMapsEveryColumn() {
        let t = tokens
        #expect(t[.input] == 1)
        #expect(t[.output] == 20)
        #expect(t[.cacheRead] == 300)
        #expect(t[.cacheWrite5m] == 4_000)
        #expect(t[.cacheWrite1h] == 50_000)
    }

    @Test("the parts carry their tokens, in the fixed order, summing to all")
    func partsCarryTokens() {
        let cost = CostComponents(
            input: 0.5, output: 2, cacheRead: 3, cacheWrite5m: 4, cacheWrite1h: 5)
        let parts: [CostBreakdown.Part] = CostBreakdown(cost: cost, tokens: tokens).parts
        let perPart: [Int64] = parts.map(\.tokens)
        // Reads, 1h writes, 5m writes, uncached input, output.
        #expect(perPart == [300, 50_000, 4_000, 1, 20])
        let sum: Int64 = perPart.reduce(0, +)
        #expect(sum == tokens.all)
    }

    @Test("a part keeps its dollars and its tokens together")
    func dollarsAndTokensStayPaired() {
        let cost = CostComponents(cacheRead: 12.5, cacheWrite1h: 7)
        let parts: [CostBreakdown.Part] = CostBreakdown(cost: cost, tokens: tokens).parts
        let read: CostBreakdown.Part? = parts.first { $0.component == .cacheRead }
        let w1h: CostBreakdown.Part? = parts.first { $0.component == .cacheWrite1h }
        #expect(read?.usd == 12.5)
        #expect(read?.tokens == 300)
        #expect(w1h?.usd == 7)
        #expect(w1h?.tokens == 50_000)
    }

    @Test("a sum of breakdowns sums each part's tokens")
    func sumAddsTokensPerPart() {
        let a = CostBreakdown(cost: CostComponents(output: 1), tokens: tokens)
        let b = CostBreakdown(cost: CostComponents(output: 2), tokens: tokens)
        let parts: [CostBreakdown.Part] = (a + b).parts
        let perPart: [Int64] = parts.map(\.tokens)
        #expect(perPart == [600, 100_000, 8_000, 2, 40])
    }

    @Test("an empty breakdown has zero tokens in every part")
    func emptyHasNoTokens() {
        let perPart: [Int64] = CostBreakdown.zero.parts.map(\.tokens)
        #expect(perPart == [0, 0, 0, 0, 0])
    }

    @Test("the legend text names the tokens; the tooltip has them exact")
    func legendAndTooltipText() throws {
        let t = TokenBreakdown(cacheReadTokens: 21_512_345_678)
        let cost = CostComponents(cacheRead: 12_603.12)
        let parts: [CostBreakdown.Part] = CostBreakdown(cost: cost, tokens: t).parts
        let read: CostBreakdown.Part = try #require(parts.first { $0.component == .cacheRead })
        #expect(pacerPartTokens(read.tokens) == "21.5B tokens")
        // The fine print under the dollars: tokens and price multiple, one
        // quiet line (round 7).
        #expect(pacerPartFinePrint(read) == "21.5B tokens · 0.1×")
        let help: String = pacerPartHelp(read)
        let lines: [String] = help.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(help.hasPrefix("Cache reads: "))
        #expect(lines.first?.hasSuffix(" · \(pacerTokensExact(21_512_345_678)) tokens") == true)
        #expect(lines.last == CostComponent.cacheRead.billingNote)
    }

    @Test("the breakdown and the hit line take no trailing slot")
    func publicAPIShape() {
        let b = CostBreakdown(cost: CostComponents(output: 1), tokens: tokens)
        let regular: PacerCostBreakdownView = PacerCostBreakdownView(b)
        let compact: PacerCostBreakdownView = PacerCostBreakdownView(b, style: .compact)
        _ = (regular, compact)
        #expect(PacerCostBreakdownView.hasContent(b))
        #expect(!PacerCostBreakdownView.hasContent(.zero))
        let line: PacerCacheHitLine = PacerCacheHitLine(ratio: 0.5)
        _ = line
    }
}

@Suite("Part price multiples")
struct PartPriceMultipleTests {
    @Test("each part's list-price multiple of the uncached input price")
    func multiplesAndLabels() {
        let labels: [String] = CostComponent.allCases.map(\.listPriceMultipleLabel)
        // Prompt order: reads, 1h writes, 5m writes, uncached input; then output.
        #expect(labels == ["0.1×", "2×", "1.25×", "1×", "5×"])
        #expect(CostComponent.input.listPriceMultiple == 1)
    }
}
