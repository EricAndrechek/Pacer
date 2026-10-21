import Foundation
import Testing
@testable import PacerCore

/// #216: price lookup is exact on a canonical id, deterministic, and never
/// falls back to a sibling model's price.
@Suite("Canonical price matching")
struct CanonicalPriceMatchTests {

    private func row(_ input: Double) -> LiteLLMModelPricing {
        LiteLLMModelPricing(
            inputCostPerToken: input, outputCostPerToken: input * 5,
            cacheCreationInputTokenCost: nil, cacheCreationInputTokenCostAbove1hr: nil,
            cacheReadInputTokenCost: nil,
            inputCostPerTokenAbove200kTokens: nil, outputCostPerTokenAbove200kTokens: nil,
            cacheCreationInputTokenCostAbove200kTokens: nil,
            cacheReadInputTokenCostAbove200kTokens: nil,
            cacheCreationInputTokenCostAbove1hrAbove200kTokens: nil,
            maxInputTokens: nil, maxOutputTokens: nil)
    }

    // MARK: Parsing

    @Test func plainIdsAreClaudeAPIGlobal() {
        let id = CanonicalModelID.parse("claude-sonnet-5-5")
        #expect(id == CanonicalModelID(model: "claude-sonnet-5-5", provider: .anthropic, region: .global))
    }

    @Test func contextSuffixIsStripped() {
        #expect(CanonicalModelID.parse("claude-opus-5-5[1m]").model == "claude-opus-5-5")
        #expect(CanonicalModelID.parse("Claude-Opus-5-5[1M]").model == "claude-opus-5-5")
    }

    @Test func datePinIsStrippedButVersionIsNot() {
        #expect(CanonicalModelID.parse("claude-haiku-4-5-20251001").model == "claude-haiku-4-5")
        #expect(CanonicalModelID.parse("claude-3-5-sonnet-20241022").model == "claude-3-5-sonnet")
        #expect(CanonicalModelID.parse("claude-opus-4-5").model == "claude-opus-4-5")
    }

    @Test func bedrockIdsCarryProviderAndRegion() {
        #expect(CanonicalModelID.parse("us.anthropic.claude-sonnet-4-5-20250929-v1:0")
                == CanonicalModelID(model: "claude-sonnet-4-5", provider: .bedrock, region: .us))
        #expect(CanonicalModelID.parse("eu.anthropic.claude-opus-5")
                == CanonicalModelID(model: "claude-opus-5", provider: .bedrock, region: .eu))
        #expect(CanonicalModelID.parse("global.anthropic.claude-sonnet-5")
                == CanonicalModelID(model: "claude-sonnet-5", provider: .bedrock, region: .global))
        #expect(CanonicalModelID.parse("jp.anthropic.claude-opus-5").region == .apac)
        #expect(CanonicalModelID.parse("us-gov.anthropic.claude-sonnet-4-5-20250929-v1:0").region == .usGov)
        #expect(CanonicalModelID.parse("anthropic.claude-haiku-4-5-20251001-v1:0")
                == CanonicalModelID(model: "claude-haiku-4-5", provider: .bedrock, region: .global))
        #expect(CanonicalModelID.parse("bedrock/us-gov-west-1/anthropic.claude-haiku-4-5-20251001-v1:0")
                == CanonicalModelID(model: "claude-haiku-4-5", provider: .bedrock, region: .usGov))
    }

    @Test func vertexAndFoundryIdsCarryProvider() {
        #expect(CanonicalModelID.parse("claude-sonnet-4-5@20250929")
                == CanonicalModelID(model: "claude-sonnet-4-5", provider: .vertex, region: .global))
        #expect(CanonicalModelID.parse("vertex_ai/claude-opus-5@default")
                == CanonicalModelID(model: "claude-opus-5", provider: .vertex, region: .global))
        #expect(CanonicalModelID.parse("azure_ai/claude-opus-5-5")
                == CanonicalModelID(model: "claude-opus-5-5", provider: .foundry, region: .global))
        #expect(CanonicalModelID.parse("anthropic/claude-opus-5-5")
                == CanonicalModelID(model: "claude-opus-5-5", provider: .anthropic, region: .global))
    }

    @Test func unknownGatewaysStayOpaque() {
        let id = CanonicalModelID.parse("openrouter/anthropic/claude-opus-5")
        #expect(id.provider == .other)
        #expect(id.model == "openrouter/anthropic/claude-opus-5")
    }

    // MARK: Matching

    @Test func newerVersionNeverResolvesToItsSibling() {
        let table = ["claude-sonnet-5": row(2e-06)]
        #expect(PricingTable.liteLLMMatch("claude-sonnet-5-5", in: table) == nil)
        #expect(PricingTable.liteLLMMatchKey("claude-opus-4-1", in: ["claude-opus-4": row(1)]) == nil)
    }

    @Test func suffixedIdResolvesToItsOwnModel() {
        let table = ["claude-opus-5-5": row(4e-06), "claude-opus-5": row(5e-06)]
        #expect(PricingTable.liteLLMMatchKey("claude-opus-5-5[1m]", in: table) == "claude-opus-5-5")
        #expect(PricingTable.liteLLMMatchKey("claude-opus-5[1m]", in: table) == "claude-opus-5")
    }

    @Test func datePinnedIdResolvesToBaseModel() {
        let table = ["claude-haiku-4-5": row(1e-06)]
        #expect(PricingTable.liteLLMMatchKey("claude-haiku-4-5-20251001", in: table) == "claude-haiku-4-5")
    }

    @Test func versionCompleteSuffixResolves() {
        let table = ["claude-opus-4-7": row(5e-06)]
        #expect(PricingTable.liteLLMMatchKey("claude-opus-4-7-thinking", in: table) == "claude-opus-4-7")
    }

    @Test func regionalIdDoesNotTakeTheGlobalRow() {
        // `us.` is priced separately (×1.1). With only the global row there
        // is no exact match; #297 derives the regional rate explicitly.
        let table = ["claude-sonnet-5": row(2e-06)]
        #expect(PricingTable.liteLLMMatchKey("us.anthropic.claude-sonnet-5", in: table) == nil)
        let both = ["claude-sonnet-5": row(2e-06), "us.anthropic.claude-sonnet-5": row(2.2e-06)]
        #expect(PricingTable.liteLLMMatchKey("us.anthropic.claude-sonnet-5", in: both)
                == "us.anthropic.claude-sonnet-5")
    }

    @Test func resultIsIdenticalAcrossShuffledTableOrders() {
        // Several keys share each identity, with different values, so any
        // order-dependence in the winner shows up as a different key.
        let keys = [
            "claude-haiku-4-5", "claude-haiku-4-5-20251001", "anthropic/claude-haiku-4-5",
            "claude-sonnet-5", "claude-sonnet-5-5", "claude-sonnet-5-5-20260930",
            "claude-opus-5", "claude-opus-5-5", "vertex_ai/claude-opus-5-5",
            "anthropic.claude-opus-5-5", "us.anthropic.claude-opus-5-5",
        ]
        let probes = ["claude-haiku-4-5-20251001", "claude-sonnet-5-5", "claude-opus-5-5[1m]",
                      "claude-opus-5", "claude-sonnet-5", "us.anthropic.claude-opus-5-5"]
        var rng = SystemRandomNumberGenerator()
        var first: [String: String?]?
        for _ in 0..<100 {
            var table: [String: LiteLLMModelPricing] = [:]
            for (i, key) in keys.shuffled(using: &rng).enumerated() { table[key] = row(Double(i + 1)) }
            let answer = Dictionary(uniqueKeysWithValues: probes.map {
                ($0, PricingTable.liteLLMMatchKey($0, in: table)) })
            if let first { #expect(answer == first) } else { first = answer }
        }
        #expect(first?["claude-haiku-4-5-20251001"] == .some("claude-haiku-4-5"))
        #expect(first?["claude-sonnet-5-5"] == .some("claude-sonnet-5-5"))
        #expect(first?["claude-opus-5-5[1m]"] == .some("claude-opus-5-5"))
    }

    @Test func unmatchedModelIsUnpricedNotFree() {
        let snap = PricingTable.Snapshot(pricingByModel: ["claude-sonnet-5": row(2e-06)])
        #expect(snap.pricing(for: "claude-sonnet-5-5") == nil)
    }

    @Test func fallbackTableIsExactToo() {
        // `claude-fable-5` is a prefix of `claude-fable-5-1`'s id; the old
        // "contains" rule would have priced 5.1 at 5's cache-read rate.
        #expect(AnthropicFallbackPricing.pricing(for: "claude-fable-5-1") == nil)
        #expect(AnthropicFallbackPricing.pricing(for: "claude-fable-5[1m]") != nil)
        #expect(AnthropicFallbackPricing.pricing(for: "claude-fable-5-20260609") != nil)
    }
}
