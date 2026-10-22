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
        #expect(perPart == [1, 20, 300, 4_000, 50_000])
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
        #expect(perPart == [2, 40, 600, 8_000, 100_000])
    }

    @Test("an empty breakdown has zero tokens in every part")
    func emptyHasNoTokens() {
        let perPart: [Int64] = CostBreakdown.zero.parts.map(\.tokens)
        #expect(perPart == [0, 0, 0, 0, 0])
    }

    @Test("the legend text names the tokens; the tooltip has them exact")
    func legendAndTooltipText() {
        let t = TokenBreakdown(cacheReadTokens: 21_512_345_678)
        let cost = CostComponents(cacheRead: 12_603.12)
        let parts: [CostBreakdown.Part] = CostBreakdown(cost: cost, tokens: t).parts
        let read: CostBreakdown.Part = parts[2]
        #expect(pacerPartTokens(read.tokens) == "21.5B tokens")
        let help: String = pacerPartHelp(read)
        #expect(help.hasPrefix("Cache reads: "))
        #expect(help.hasSuffix(" · \(pacerTokensExact(21_512_345_678)) tokens"))
    }

    @Test("the one-argument init and hasContent stay source-compatible")
    func publicAPIShape() {
        let b = CostBreakdown(cost: CostComponents(output: 1), tokens: tokens)
        let regular: PacerCostBreakdownView<EmptyView> = PacerCostBreakdownView(b)
        let compact: PacerCostBreakdownView<EmptyView> = PacerCostBreakdownView(b, style: .compact)
        let slotted = PacerCostBreakdownView(b) { Text("saved") }
        _ = (regular, compact, slotted)
        #expect(PacerCostBreakdownView.hasContent(b))
        #expect(!PacerCostBreakdownView.hasContent(.zero))
        let line: PacerCacheHitLine<EmptyView> = PacerCacheHitLine(ratio: 0.5)
        let slottedLine = PacerCacheHitLine(ratio: 0.5) { Text("saved") }
        _ = (line, slottedLine)
    }
}
