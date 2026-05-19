import Foundation
import Testing
@testable import PacerCore

@Suite("PricingTable + CostCalculator")
struct PricingTests {

    @Test func loadsEmbeddedSnapshot() async throws {
        let table = PricingTable()
        try await table.ensureLoaded()
        let count = await table.modelCount()
        // LiteLLM ships ~2700 models. Sanity-check we have plausibly
        // many. If this drops below 100 something is very wrong.
        #expect(count > 100)
    }

    @Test func looksUpClaudeOpus47Directly() async throws {
        let table = PricingTable()
        try await table.ensureLoaded()
        let pricing = try #require(await table.pricing(for: "claude-opus-4-7"))
        // From LiteLLM as of 2026-05-06: $5/1M input, $25/1M output.
        // Stored as per-token, so 5e-06 / 25e-06.
        #expect(pricing.inputCostPerToken == 5e-06)
        #expect(pricing.outputCostPerToken == 25e-06)
    }

    @Test func looksUpHaiku45ViaLiteralName() async throws {
        let table = PricingTable()
        try await table.ensureLoaded()
        let pricing = await table.pricing(for: "claude-haiku-4-5-20251001")
        #expect(pricing != nil)
    }

    @Test func unknownModelReturnsNil() async throws {
        let table = PricingTable()
        try await table.ensureLoaded()
        let pricing = await table.pricing(for: "totally-not-a-model-xyz123")
        #expect(pricing == nil)
    }

    @Test func costForOpus47SimpleBreakdownMatchesArithmetic() {
        // Hand-computed: 1000 input × $5/1M = $0.005
        //                500 output × $25/1M = $0.0125
        //                Total = $0.0175
        let pricing = LiteLLMModelPricing(
            inputCostPerToken: 5e-06,
            outputCostPerToken: 25e-06,
            cacheCreationInputTokenCost: 6.25e-06,
            cacheCreationInputTokenCostAbove1hr: 1e-05,
            cacheReadInputTokenCost: 5e-07,
            inputCostPerTokenAbove200kTokens: nil,
            outputCostPerTokenAbove200kTokens: nil,
            cacheCreationInputTokenCostAbove200kTokens: nil,
            cacheReadInputTokenCostAbove200kTokens: nil,
            cacheCreationInputTokenCostAbove1hrAbove200kTokens: nil,
            maxInputTokens: 1_000_000,
            maxOutputTokens: 128_000
        )
        let breakdown = TokenBreakdown(
            inputTokens: 1000,
            outputTokens: 500
        )
        let cost = CostCalculator.cost(breakdown: breakdown, pricing: pricing)
        #expect(abs(cost - 0.0175) < 1e-9)
    }

    @Test func costAppliesAllFiveCategoriesIndependently() {
        // 1000 input × 5e-06           = 0.005
        // 500 output × 25e-06          = 0.0125
        // 10000 cache_read × 5e-07     = 0.005
        // 2000 cache_5m × 6.25e-06     = 0.0125
        // 1000 cache_1h × 1e-05        = 0.01
        //                       Total  = 0.045
        let pricing = LiteLLMModelPricing(
            inputCostPerToken: 5e-06,
            outputCostPerToken: 25e-06,
            cacheCreationInputTokenCost: 6.25e-06,
            cacheCreationInputTokenCostAbove1hr: 1e-05,
            cacheReadInputTokenCost: 5e-07,
            inputCostPerTokenAbove200kTokens: nil,
            outputCostPerTokenAbove200kTokens: nil,
            cacheCreationInputTokenCostAbove200kTokens: nil,
            cacheReadInputTokenCostAbove200kTokens: nil,
            cacheCreationInputTokenCostAbove1hrAbove200kTokens: nil,
            maxInputTokens: 1_000_000,
            maxOutputTokens: 128_000
        )
        let breakdown = TokenBreakdown(
            inputTokens: 1000,
            outputTokens: 500,
            cacheReadTokens: 10000,
            cacheCreation5mTokens: 2000,
            cacheCreation1hTokens: 1000
        )
        let cost = CostCalculator.cost(breakdown: breakdown, pricing: pricing)
        #expect(abs(cost - 0.045) < 1e-9)
    }

    @Test func tieredPricingAppliesAbove200k() {
        // 250k input tokens: first 200k @ $5/1M = $1.00,
        //                    next 50k @ $9/1M  = $0.45
        //                    total              = $1.45
        let pricing = LiteLLMModelPricing(
            inputCostPerToken: 5e-06,
            outputCostPerToken: nil,
            cacheCreationInputTokenCost: nil,
            cacheCreationInputTokenCostAbove1hr: nil,
            cacheReadInputTokenCost: nil,
            inputCostPerTokenAbove200kTokens: 9e-06,
            outputCostPerTokenAbove200kTokens: nil,
            cacheCreationInputTokenCostAbove200kTokens: nil,
            cacheReadInputTokenCostAbove200kTokens: nil,
            cacheCreationInputTokenCostAbove1hrAbove200kTokens: nil,
            maxInputTokens: nil,
            maxOutputTokens: nil
        )
        let breakdown = TokenBreakdown(inputTokens: 250_000)
        let cost = CostCalculator.cost(breakdown: breakdown, pricing: pricing)
        #expect(abs(cost - 1.45) < 1e-9)
    }

    @Test func tieredPricingDoesNotApplyBelow200k() {
        let pricing = LiteLLMModelPricing(
            inputCostPerToken: 5e-06,
            outputCostPerToken: nil,
            cacheCreationInputTokenCost: nil,
            cacheCreationInputTokenCostAbove1hr: nil,
            cacheReadInputTokenCost: nil,
            inputCostPerTokenAbove200kTokens: 9e-06,
            outputCostPerTokenAbove200kTokens: nil,
            cacheCreationInputTokenCostAbove200kTokens: nil,
            cacheReadInputTokenCostAbove200kTokens: nil,
            cacheCreationInputTokenCostAbove1hrAbove200kTokens: nil,
            maxInputTokens: nil,
            maxOutputTokens: nil
        )
        let breakdown = TokenBreakdown(inputTokens: 100_000)
        let cost = CostCalculator.cost(breakdown: breakdown, pricing: pricing)
        // 100k × 5e-06 = $0.50
        #expect(abs(cost - 0.5) < 1e-9)
    }

    @Test func costModeDisplayUsesStoredOnly() async {
        let calc = CostCalculator(mode: .display)
        let entry = ParsedUsageEntry(
            timestamp: Date(),
            model: "claude-opus-4-7",
            breakdown: TokenBreakdown(inputTokens: 1_000_000),
            storedCostUSD: 1.23,
            dedupKey: nil,
            sessionId: nil,
            projectPath: nil,
            claudeCodeVersion: nil,
            isApiErrorMessage: false
        )
        let cost = await calc.cost(for: entry)
        #expect(cost == 1.23)
    }

    @Test func costModeDisplayMissingStoredYieldsZero() async {
        let calc = CostCalculator(mode: .display)
        let entry = ParsedUsageEntry(
            timestamp: Date(),
            model: "claude-opus-4-7",
            breakdown: TokenBreakdown(inputTokens: 1_000_000),
            storedCostUSD: nil,
            dedupKey: nil,
            sessionId: nil,
            projectPath: nil,
            claudeCodeVersion: nil,
            isApiErrorMessage: false
        )
        let cost = await calc.cost(for: entry)
        #expect(cost == 0)
    }

    @Test func costModeAutoFallsBackToCalculate() async throws {
        let calc = CostCalculator(mode: .auto)
        let entry = ParsedUsageEntry(
            timestamp: Date(),
            model: "claude-opus-4-7",
            breakdown: TokenBreakdown(inputTokens: 1000, outputTokens: 500),
            storedCostUSD: nil,
            dedupKey: nil,
            sessionId: nil,
            projectPath: nil,
            claudeCodeVersion: nil,
            isApiErrorMessage: false
        )
        let cost = await calc.cost(for: entry)
        // 1000 × 5e-06 + 500 × 25e-06 = 0.0175
        #expect(abs(cost - 0.0175) < 1e-9)
    }

    @Test func costModeCalculateIgnoresStored() async {
        let calc = CostCalculator(mode: .calculate)
        let entry = ParsedUsageEntry(
            timestamp: Date(),
            model: "claude-opus-4-7",
            breakdown: TokenBreakdown(inputTokens: 1000, outputTokens: 500),
            storedCostUSD: 999.0,  // wildly wrong stored value — must be ignored
            dedupKey: nil,
            sessionId: nil,
            projectPath: nil,
            claudeCodeVersion: nil,
            isApiErrorMessage: false
        )
        let cost = await calc.cost(for: entry)
        #expect(abs(cost - 0.0175) < 1e-9)
    }

    // MARK: - Pricing cache file (24h refresh)

    @Test func cacheAgeIsNilForMissingFile() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pacer-pricing-cache-test-\(UUID()).json")
        #expect(PricingTable.cacheAge(at: tmp) == nil)
    }

    @Test func cacheAgeReflectsFileMtime() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pacer-pricing-cache-test-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data("{}".utf8).write(to: tmp)
        let twoHoursAgo = Date().addingTimeInterval(-7200)
        try FileManager.default.setAttributes(
            [.modificationDate: twoHoursAgo],
            ofItemAtPath: tmp.path
        )
        let age = try #require(PricingTable.cacheAge(at: tmp))
        // Allow a small window for filesystem mtime resolution.
        #expect(abs(age - 7200) < 5)
    }

    @Test func ensureLoadedPrefersInjectedCacheFile() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pacer-pricing-cache-test-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Minimal LiteLLM-shape JSON with one model the embedded
        // snapshot doesn't ship under that name — so finding it back
        // proves we loaded FROM the cache file rather than the
        // embedded fallback.
        let fakeJSON = """
        {
          "test-only-marker-model-9876": {
            "input_cost_per_token": 1e-06,
            "output_cost_per_token": 2e-06,
            "max_tokens": 100,
            "max_input_tokens": 100,
            "max_output_tokens": 100
          }
        }
        """
        try Data(fakeJSON.utf8).write(to: tmp)

        let table = PricingTable()
        try await table.ensureLoaded(cacheURL: tmp)
        let pricing = try #require(await table.pricing(for: "test-only-marker-model-9876"))
        #expect(pricing.inputCostPerToken == 1e-06)
        #expect(pricing.outputCostPerToken == 2e-06)
    }

    @Test func ensureLoadedFallsBackToEmbeddedWhenCacheIsCorrupt() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pacer-pricing-cache-test-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data("not json".utf8).write(to: tmp)

        let table = PricingTable()
        try await table.ensureLoaded(cacheURL: tmp)
        // Embedded snapshot has the well-known opus 4.7 entry; if we
        // can find it, the fall-through worked.
        let pricing = await table.pricing(for: "claude-opus-4-7")
        #expect(pricing != nil)
    }

    @Test func ensureLoadedFallsBackToEmbeddedWhenCacheIsEmpty() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pacer-pricing-cache-test-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Valid JSON, just nothing usable in it.
        try Data("{}".utf8).write(to: tmp)

        let table = PricingTable()
        try await table.ensureLoaded(cacheURL: tmp)
        let pricing = await table.pricing(for: "claude-opus-4-7")
        #expect(pricing != nil)
    }
}
