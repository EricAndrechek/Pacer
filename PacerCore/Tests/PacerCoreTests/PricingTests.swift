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

    // MARK: - Anthropic fallback pricing (Fable / Mythos)

    @Test func fableFiveResolvesFromEmbeddedSnapshot() async throws {
        // The embedded snapshot is the LiteLLM + models.dev merge
        // (`make pricing-snapshot`), so Fable resolves even before the
        // first network refresh. If a future source ships different
        // rates, this failing is the signal to re-check them against
        // Anthropic's published pricing.
        let table = PricingTable()
        try await table.ensureLoaded()
        let pricing = try #require(await table.pricing(for: "claude-fable-5"))
        #expect(pricing.inputCostPerToken == 1.0e-05)    // $10 / MTok
        #expect(pricing.outputCostPerToken == 5.0e-05)   // $50 / MTok
        #expect(pricing.cacheCreationInputTokenCost == 1.25e-05)
        #expect(pricing.cacheReadInputTokenCost == 1.0e-06)
        // Full 1M context at standard pricing — no above-200k tier.
        #expect(pricing.inputCostPerTokenAbove200kTokens == nil)
    }

    @Test func builtinFallbackTableCarriesDocumentedRates() {
        // Direct unit check on the static floor — these rows are what
        // price Glasswing models (absent from every public catalog)
        // and brand-new models on offline cold starts.
        let fable = AnthropicFallbackPricing.pricing(for: "claude-fable-5")
        #expect(fable?.inputCostPerToken == 1.0e-05)
        #expect(fable?.cacheCreationInputTokenCostAbove1hr == 2.0e-05)

        let mythos5 = AnthropicFallbackPricing.pricing(for: "claude-mythos-5")
        #expect(mythos5?.inputCostPerToken == 1.0e-05)
        #expect(mythos5?.outputCostPerToken == 5.0e-05)

        // Mythos Preview: $25/$125 partner pricing, cache rates via
        // the standard 1.25x / 2x / 0.1x multipliers.
        let preview = AnthropicFallbackPricing.pricing(for: "claude-mythos-preview")
        #expect(preview?.inputCostPerToken == 2.5e-05)
        #expect(preview?.outputCostPerToken == 1.25e-04)
        #expect(preview?.cacheCreationInputTokenCost == 3.125e-05)
        #expect(preview?.cacheCreationInputTokenCostAbove1hr == 5.0e-05)
        #expect(preview?.cacheReadInputTokenCost == 2.5e-06)
    }

    @Test func fableVariantsResolveToSameFallback() async throws {
        let table = PricingTable()
        try await table.ensureLoaded()
        // 1M-context beta suffix, Bedrock prefix, and Mythos 5 all
        // land on the same fallback tier.
        for name in ["claude-fable-5[1m]", "anthropic.claude-fable-5", "claude-mythos-5"] {
            let pricing = try #require(await table.pricing(for: name), "\(name) should resolve")
            #expect(pricing.inputCostPerToken == 1.0e-05)
            #expect(pricing.outputCostPerToken == 5.0e-05)
        }
    }

    @Test func snapshotMirrorsBuiltinFallback() async throws {
        let table = PricingTable()
        try await table.ensureLoaded()
        let snapshot = await table.snapshot()
        let pricing = try #require(snapshot.pricing(for: "claude-fable-5"))
        #expect(pricing.outputCostPerToken == 5.0e-05)
    }

    @Test func zeroPricedPlaceholderEntriesAreDroppedAtDecode() async throws {
        // LiteLLM ships placeholder rows with explicit $0 everywhere
        // (anthropic.claude-mythos-preview is one). They must be
        // dropped at decode: a $0 row costs the same as a missing row,
        // but if kept it would shadow the built-in fallback table via
        // the substring match and silently price real usage at $0.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pacer-pricing-cache-test-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fakeJSON = """
        {
          "dummy-real-model-1234": {
            "input_cost_per_token": 1e-06,
            "output_cost_per_token": 2e-06
          },
          "anthropic.claude-mythos-preview": {
            "input_cost_per_token": 0,
            "output_cost_per_token": 0,
            "max_input_tokens": 1000000
          }
        }
        """
        try Data(fakeJSON.utf8).write(to: tmp)

        let table = PricingTable()
        try await table.ensureLoaded(cacheURL: tmp)
        #expect(await table.modelCount() == 1)
        // With the $0 placeholder dropped, Mythos Preview falls
        // through to the fallback row carrying its reported partner
        // pricing instead of a fake $0 entry.
        let preview = try #require(await table.pricing(for: "claude-mythos-preview"))
        #expect(preview.inputCostPerToken == 2.5e-05)
        #expect(preview.outputCostPerToken == 1.25e-04)
        // Mythos 5 resolves via the fallback even though this
        // snapshot doesn't carry it.
        let mythos = try #require(await table.pricing(for: "claude-mythos-5"))
        #expect(mythos.inputCostPerToken == 1.0e-05)
    }

    @Test func liteLLMEntryWinsOverBuiltinFallback() async throws {
        // The fallback is a stopgap: the moment LiteLLM ships a usable
        // Fable row, that row must win.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pacer-pricing-cache-test-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fakeJSON = """
        {
          "claude-fable-5": {
            "input_cost_per_token": 9.9e-05,
            "output_cost_per_token": 9.9e-05
          }
        }
        """
        try Data(fakeJSON.utf8).write(to: tmp)

        let table = PricingTable()
        try await table.ensureLoaded(cacheURL: tmp)
        let pricing = try #require(await table.pricing(for: "claude-fable-5"))
        #expect(pricing.inputCostPerToken == 9.9e-05)
    }

    // MARK: - models.dev secondary source

    @Test func modelsDevParserMapsAnthropicEntriesToLiteLLMShape() throws {
        // Real shape: per-MTok dollars under cost{}, limits under
        // limit{}. Mixed Int/Double costs both convert to per-token.
        let json = """
        {
          "anthropic": {
            "models": {
              "claude-fable-5": {
                "cost": {"input": 10, "output": 50, "cache_read": 1, "cache_write": 12.5},
                "limit": {"context": 1000000, "output": 128000}
              },
              "zero-priced-placeholder": {
                "cost": {"input": 0, "output": 0}
              },
              "no-cost-model": {"limit": {"context": 200000}}
            }
          },
          "openai": {
            "models": {
              "gpt-x": {"cost": {"input": 5, "output": 15}}
            }
          }
        }
        """
        let entries = ModelsDevCatalog.anthropicEntries(from: Data(json.utf8))
        #expect(entries.count == 1)
        let fable = try #require(entries["claude-fable-5"])
        #expect(fable["input_cost_per_token"] as? Double == 1.0e-05)
        #expect(fable["output_cost_per_token"] as? Double == 5.0e-05)
        #expect(fable["cache_read_input_token_cost"] as? Double == 1.0e-06)
        #expect(fable["cache_creation_input_token_cost"] as? Double == 1.25e-05)
        #expect(fable["max_input_tokens"] as? Int == 1_000_000)
        #expect(fable["max_output_tokens"] as? Int == 128_000)
        // The synthesized entry must decode through the normal
        // LiteLLM per-entry path.
        let data = try JSONSerialization.data(withJSONObject: fable)
        let decoded = try JSONDecoder().decode(LiteLLMModelPricing.self, from: data)
        #expect(decoded.hasUsablePricing)
    }

    @Test func gapFillCoverageUsesLiteLLMMatchSemantics() {
        // The merge must skip models the LiteLLM table already covers
        // — including via provider-prefixed keys through the substring
        // match — and must NOT consult the static fallback table (or
        // fallback-listed models would never be gap-filled).
        let row = LiteLLMModelPricing(
            inputCostPerToken: 1e-06,
            outputCostPerToken: 2e-06,
            cacheCreationInputTokenCost: nil,
            cacheCreationInputTokenCostAbove1hr: nil,
            cacheReadInputTokenCost: nil,
            inputCostPerTokenAbove200kTokens: nil,
            outputCostPerTokenAbove200kTokens: nil,
            cacheCreationInputTokenCostAbove200kTokens: nil,
            cacheReadInputTokenCostAbove200kTokens: nil,
            cacheCreationInputTokenCostAbove1hrAbove200kTokens: nil,
            maxInputTokens: nil,
            maxOutputTokens: nil
        )
        let covered = [
            "claude-sonnet-4-6": row,
            "anthropic.claude-opus-4-8": row,
        ]
        // Literal key → covered.
        #expect(PricingTable.liteLLMMatch("claude-sonnet-4-6", in: covered) != nil)
        // Bedrock-prefixed key covers the bare ID via substring.
        #expect(PricingTable.liteLLMMatch("claude-opus-4-8", in: covered) != nil)
        // Absent from the table → gap-fill candidate, even though the
        // static fallback table knows it.
        #expect(PricingTable.liteLLMMatch("claude-fable-5", in: covered) == nil)
    }
}
