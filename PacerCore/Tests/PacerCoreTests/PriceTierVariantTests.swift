import Foundation
import Testing
@testable import PacerCore

/// #297: tiers by request prompt size, the derived 1h write, fast mode and
/// regional variants, and Bedrock/Vertex ids — each component checked
/// against a hand calculation from Anthropic's pricing page.
@Suite("Price tiers and variants")
struct PriceTierVariantTests {

    static let t = Date(timeIntervalSince1970: 1_790_000_000)
    static let perM = 1.0 / 1_000_000

    /// Catalog rows shaped like the live LiteLLM entries.
    static func row(
        input: Double, output: Double, w5m: Double?, w1h: Double?, read: Double,
        above100k: (Double, Double, Double, Double)? = nil,
        above200k: (Double, Double, Double, Double)? = nil,
        fast: Double? = nil, us: Double? = nil
    ) -> LiteLLMModelPricing {
        var p = LiteLLMModelPricing(
            inputCostPerToken: input * perM, outputCostPerToken: output * perM,
            cacheCreationInputTokenCost: w5m.map { $0 * perM },
            cacheCreationInputTokenCostAbove1hr: w1h.map { $0 * perM },
            cacheReadInputTokenCost: read * perM,
            inputCostPerTokenAbove200kTokens: above200k.map { $0.0 * perM },
            outputCostPerTokenAbove200kTokens: above200k.map { $0.1 * perM },
            cacheCreationInputTokenCostAbove200kTokens: above200k.map { $0.2 * perM },
            cacheReadInputTokenCostAbove200kTokens: above200k.map { $0.3 * perM },
            cacheCreationInputTokenCostAbove1hrAbove200kTokens: nil,
            maxInputTokens: nil, maxOutputTokens: nil)
        if let a = above100k {
            p.inputCostPerTokenAbove100kTokens = a.0 * perM
            p.outputCostPerTokenAbove100kTokens = a.1 * perM
            p.cacheCreationInputTokenCostAbove100kTokens = a.2 * perM
            p.cacheReadInputTokenCostAbove100kTokens = a.3 * perM
        }
        var pse: [String: Double] = [:]
        if let fast { pse["fast"] = fast }
        if let us { pse["us"] = us }
        if !pse.isEmpty { p.providerSpecificEntry = NumberMap(pse) }
        return p
    }

    static let catalog: [String: LiteLLMModelPricing] = [
        // Haiku 5.5: $0.10 / $0.125 / $0.20 / $0.01 / $0.50, and over 100k
        // $0.50 / $0.625 / $1 / $0.05 / $2.50 (no 1h-over-100k field).
        "claude-haiku-5-5": row(input: 0.10, output: 0.50, w5m: 0.125, w1h: 0.20, read: 0.01,
                                above100k: (0.50, 2.50, 0.625, 0.05), us: 1.1),
        // Opus 5.5: $4 / $5 / $8 / $0.20 / $20, fast ×2.
        "claude-opus-5-5": row(input: 4, output: 20, w5m: 5, w1h: 8, read: 0.20, fast: 2, us: 1.1),
        // Sonnet 5: $2 / $2.50 / $4 / $0.20 / $10, no fast mode.
        "claude-sonnet-5": row(input: 2, output: 10, w5m: 2.5, w1h: 4, read: 0.20, us: 1.1),
        // Sonnet 4.5 with the old 1M-context tier: $6 / $22.50 / $7.50 / $0.60.
        "claude-sonnet-4-5": row(input: 3, output: 15, w5m: 3.75, w1h: 6, read: 0.30,
                                 above200k: (6, 22.5, 7.5, 0.6)),
        // A row that publishes no 1h write (models.dev / catwalk shape).
        "claude-opus-5": row(input: 5, output: 25, w5m: 6.25, w1h: nil, read: 0.50),
        // Vertex lists its own row for this one.
        "vertex_ai/claude-opus-5-5": row(input: 4, output: 20, w5m: 5, w1h: 8, read: 0.20),
    ]

    // Catalog only: the curated file must not stand in for these fixtures.
    static let ledger = PriceLedger.provisional(catalog: catalog, curated: [])

    static func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-12 }

    // MARK: Prompt-size tiers

    @Test func haikuAt99kPromptPaysTheBaseTierOnEveryCategory() {
        // 9k input + 80k reads + 10k 5m writes = 99,000 prompt tokens; 1k out.
        let b = TokenBreakdown(inputTokens: 9_000, outputTokens: 1_000,
                               cacheReadTokens: 80_000, cacheCreation5mTokens: 10_000)
        let c = Self.ledger.cost(model: "claude-haiku-5-5", at: Self.t, breakdown: b).components
        #expect(Self.close(c.input, 9_000 * 0.10 * Self.perM))
        #expect(Self.close(c.cacheRead, 80_000 * 0.01 * Self.perM))
        #expect(Self.close(c.cacheWrite5m, 10_000 * 0.125 * Self.perM))
        #expect(Self.close(c.output, 1_000 * 0.50 * Self.perM))
    }

    @Test func haikuAt101kPromptPaysTheUpperTierOnTheWholeRequest() {
        let b = TokenBreakdown(inputTokens: 11_000, outputTokens: 1_000,
                               cacheReadTokens: 80_000, cacheCreation5mTokens: 10_000)
        let c = Self.ledger.cost(model: "claude-haiku-5-5", at: Self.t, breakdown: b).components
        #expect(Self.close(c.input, 11_000 * 0.50 * Self.perM))
        #expect(Self.close(c.cacheRead, 80_000 * 0.05 * Self.perM))
        #expect(Self.close(c.cacheWrite5m, 10_000 * 0.625 * Self.perM))
        #expect(Self.close(c.output, 1_000 * 2.50 * Self.perM))
        #expect(Self.close(c.total, 0.0055 + 0.004 + 0.00625 + 0.0025))
    }

    @Test func cacheReadsAloneCanCrossTheThreshold() {
        // 1k input, 100,500 reads: the cache hit is what puts it over, and
        // Anthropic still charges the higher prices — reads included.
        let b = TokenBreakdown(inputTokens: 1_000, outputTokens: 200, cacheReadTokens: 100_500)
        let cost = Self.ledger.cost(model: "claude-haiku-5-5", at: Self.t, breakdown: b)
        #expect(Self.close(cost.components.cacheRead, 100_500 * 0.05 * Self.perM))
        #expect(Self.close(cost.components.input, 1_000 * 0.50 * Self.perM))
        #expect(Self.close(cost.components.output, 200 * 2.50 * Self.perM))
    }

    @Test func exactlyAtTheThresholdIsNotOverIt() {
        let b = TokenBreakdown(inputTokens: 100_000)
        let c = Self.ledger.cost(model: "claude-haiku-5-5", at: Self.t, breakdown: b).components
        #expect(Self.close(c.input, 100_000 * 0.10 * Self.perM))
    }

    @Test func upperTierOneHourWriteIsDerivedFromTheTiersInput() {
        // No 1h-over-100k rate is published: 2 × $0.50 = $1, as Anthropic lists.
        let b = TokenBreakdown(inputTokens: 101_000, cacheCreation1hTokens: 1_000)
        let cost = Self.ledger.cost(model: "claude-haiku-5-5", at: Self.t, breakdown: b)
        #expect(Self.close(cost.components.cacheWrite1h, 1_000 * 1.0 * Self.perM))
        #expect(cost.flags.contains(.derivedRate))
    }

    @Test func oldLongContextTierIsPerRequestToo() {
        // Sonnet 4.5: 150k reads + 60k input = 210k prompt, so every token is
        // at the 200k tier — not just the categories that crossed 200k alone.
        let b = TokenBreakdown(inputTokens: 60_000, outputTokens: 2_000, cacheReadTokens: 150_000)
        let c = Self.ledger.cost(model: "claude-sonnet-4-5-20250929", at: Self.t, breakdown: b).components
        #expect(Self.close(c.input, 60_000 * 6 * Self.perM))
        #expect(Self.close(c.cacheRead, 150_000 * 0.6 * Self.perM))
        #expect(Self.close(c.output, 2_000 * 22.5 * Self.perM))
    }

    // MARK: Derived 1h write

    @Test func unpublishedOneHourWriteIsTwiceInputNotTheFiveMinuteRate() {
        let b = TokenBreakdown(cacheCreation1hTokens: 1_000_000)
        let cost = Self.ledger.cost(model: "claude-opus-5", at: Self.t, breakdown: b)
        #expect(Self.close(cost.total, 10.0))           // 2 × $5, not $6.25
        #expect(cost.flags.contains(.derivedRate))
        let published = Self.ledger.cost(model: "claude-opus-5-5", at: Self.t, breakdown: b)
        #expect(!published.flags.contains(.derivedRate))
    }

    // MARK: Fast mode

    @Test func fastModeOpus55IsDoubleOnEveryCategory() {
        // $8 / $40 per Anthropic, and the cache multipliers stack on top.
        let b = TokenBreakdown(inputTokens: 1_000, outputTokens: 2_000, cacheReadTokens: 50_000,
                               cacheCreation5mTokens: 3_000, cacheCreation1hTokens: 4_000)
        let c = Self.ledger.cost(model: "claude-opus-5-5", at: Self.t, speed: .fast, breakdown: b)
        #expect(Self.close(c.components.input, 1_000 * 8 * Self.perM))
        #expect(Self.close(c.components.output, 2_000 * 40 * Self.perM))
        #expect(Self.close(c.components.cacheRead, 50_000 * 0.40 * Self.perM))
        #expect(Self.close(c.components.cacheWrite5m, 3_000 * 10 * Self.perM))
        #expect(Self.close(c.components.cacheWrite1h, 4_000 * 16 * Self.perM))
        #expect(c.flags.contains(.derivedRate))
    }

    @Test func fastModeWithNoKnownRateIsUnpricedPremium() {
        let b = TokenBreakdown(inputTokens: 1_000, outputTokens: 1_000)
        let c = Self.ledger.cost(model: "claude-sonnet-5", at: Self.t, speed: .fast, breakdown: b)
        #expect(c.total == 0)
        #expect(c.flags.contains(.unpricedPremium))
        // Still remembers its record, so a fast rate appearing rebuilds it.
        #expect(!c.pricedBy.isEmpty)
    }

    @Test func anExplicitFastRecordBeatsTheMultiplier() {
        let fast = PriceRecordValue(
            key: CanonicalModelID(model: "claude-opus-5-5"), speed: .fast,
            rates: PriceRates(input: 9 * Self.perM, output: 45 * Self.perM, cacheRead: 0,
                              cacheWrite5m: 0, cacheWrite1h: 0),
            effectiveFrom: .distantPast, source: .curated)
        let ledger = PriceLedger(records: Self.ledger.records + [fast])
        let c = ledger.cost(model: "claude-opus-5-5", at: Self.t, speed: .fast,
                            breakdown: TokenBreakdown(inputTokens: 1_000_000))
        #expect(Self.close(c.total, 9))
    }

    // MARK: Region and provider

    @Test func usDataResidencyIsTenPercentOnEveryCategory() {
        let b = TokenBreakdown(inputTokens: 1_000_000, outputTokens: 1_000_000,
                               cacheReadTokens: 1_000_000)
        let c = Self.ledger.cost(model: "claude-sonnet-5", at: Self.t, geo: .us, breakdown: b)
        #expect(Self.close(c.components.input, 2.2))
        #expect(Self.close(c.components.output, 11))
        #expect(Self.close(c.components.cacheRead, 0.22))
        #expect(c.flags.contains(.derivedRate))
    }

    @Test func usResidencyStacksWithFastAndWithTheHaikuTier() {
        let fast = Self.ledger.cost(model: "claude-opus-5-5", at: Self.t, speed: .fast, geo: .us,
                                    breakdown: TokenBreakdown(inputTokens: 1_000_000))
        #expect(Self.close(fast.total, 8 * 1.1))
        let tier = Self.ledger.cost(model: "claude-haiku-5-5", at: Self.t, geo: .us,
                                    breakdown: TokenBreakdown(inputTokens: 1_000_000))
        #expect(Self.close(tier.total, 0.50 * 1.1))
    }

    @Test func bedrockRegionalIdWithNoRowOfItsOwnIsDerived() {
        // `us.anthropic.claude-sonnet-5` is $2.20, not $2.00.
        let c = Self.ledger.cost(model: "us.anthropic.claude-sonnet-5", at: Self.t,
                                 breakdown: TokenBreakdown(inputTokens: 1_000_000))
        #expect(Self.close(c.total, 2.2))
        #expect(c.pricedBy.contains(PriceLedger.noneToken(
            CanonicalModelID(model: "claude-sonnet-5", provider: .bedrock, region: .us))))
    }

    @Test func bedrockGlobalAndVertexIdsArePricedAtTheGlobalRate() {
        let b = TokenBreakdown(inputTokens: 1_000_000)
        #expect(Self.close(Self.ledger.cost(model: "global.anthropic.claude-sonnet-5", at: Self.t,
                                            breakdown: b).total, 2))
        #expect(Self.close(Self.ledger.cost(model: "anthropic.claude-sonnet-5-v1:0", at: Self.t,
                                            breakdown: b).total, 2))
        #expect(Self.close(Self.ledger.cost(model: "claude-opus-5-5@20260922", at: Self.t,
                                            breakdown: b).total, 4))
        // The Vertex id took Vertex's own row.
        let vertex = Self.ledger.cost(model: "claude-opus-5-5@20260922", at: Self.t, breakdown: b)
        #expect(vertex.pricedBy.first?.contains("|vertex|") == true)
    }

    @Test func providerPremiumsDecodeLenientlyFromCatalogJSON() throws {
        let json = #"{"input_cost_per_token": 1e-06, "output_cost_per_token": 5e-06,"#
            + #""provider_specific_entry": {"fast": 2, "us": 1.1, "note": "x"}}"#
        let p = try JSONDecoder().decode(LiteLLMModelPricing.self, from: Data(json.utf8))
        #expect(p.providerSpecificEntry?["fast"] == 2)
        #expect(p.providerSpecificEntry?["us"] == 1.1)
        let odd = #"{"input_cost_per_token": 1e-06, "provider_specific_entry": "n/a"}"#
        #expect(try JSONDecoder().decode(LiteLLMModelPricing.self, from: Data(odd.utf8))
            .providerSpecificEntry?.values.isEmpty == true)
    }
}
