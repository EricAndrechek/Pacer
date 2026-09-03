import Foundation
import Testing
@testable import PacerCore

@Suite("Catwalk pricing source")
struct CatwalkCatalogTests {

    private let payload = Data("""
    {"name":"Anthropic","id":"anthropic","models":[
      {"id":"claude-fable-5-1","name":"Claude Fable 5.1",
       "cost_per_1m_in":10,"cost_per_1m_out":50,
       "cost_per_1m_in_cached":12.5,"cost_per_1m_out_cached":0.25,
       "context_window":1000000,"default_max_tokens":128000},
      {"id":"free-model","cost_per_1m_in":0,"cost_per_1m_out":0},
      {"id":"","cost_per_1m_in":1},
      {"id":"partial","cost_per_1m_out":25}
    ]}
    """.utf8)

    @Test("per-MTok dollars become per-token dollars")
    func convertsToPerToken() {
        let entries = CatwalkCatalog.anthropicEntries(from: payload)
        let m = entries["claude-fable-5-1"]
        #expect(m?["input_cost_per_token"] as? Double == 10.0 / 1_000_000)
        #expect(m?["output_cost_per_token"] as? Double == 50.0 / 1_000_000)
        #expect(m?["max_input_tokens"] as? Int == 1_000_000)
        #expect(m?["max_output_tokens"] as? Int == 128_000)
    }

    /// The one mapping that is easy to get backwards and impossible to spot
    /// afterwards: `in_cached` is the cache WRITE rate (priced *above*
    /// input — 12.5 against 10), `out_cached` is the READ rate (far below).
    /// Swapping them inflates cache reads ~50x while still looking plausible,
    /// and cache reads dominate Claude Code usage.
    @Test("cache write and cache read are not transposed")
    func cacheFieldsMapTheRightWayRound() {
        let m = CatwalkCatalog.anthropicEntries(from: payload)["claude-fable-5-1"]
        let write = m?["cache_creation_input_token_cost"] as? Double
        let read = m?["cache_read_input_token_cost"] as? Double
        #expect(write == 12.5 / 1_000_000)
        #expect(read == 0.25 / 1_000_000)
        // The invariant behind it, in case the fixture ever drifts.
        #expect((write ?? 0) > (m?["input_cost_per_token"] as? Double ?? 0))
        #expect((read ?? 0) < (m?["input_cost_per_token"] as? Double ?? 0))
    }

    @Test("zero-cost and unusable entries are skipped")
    func skipsPlaceholders() {
        let entries = CatwalkCatalog.anthropicEntries(from: payload)
        #expect(entries["free-model"] == nil)   // all costs zero
        #expect(entries[""] == nil)             // no id
        #expect(entries["partial"] != nil)      // one real price is enough
    }

    @Test("malformed payloads yield nothing rather than throwing")
    func malformedIsEmpty() {
        #expect(CatwalkCatalog.anthropicEntries(from: Data("not json".utf8)).isEmpty)
        #expect(CatwalkCatalog.anthropicEntries(from: Data("{}".utf8)).isEmpty)
        #expect(CatwalkCatalog.anthropicEntries(
            from: Data(#"{"models":"nope"}"#.utf8)).isEmpty)
    }
}

@Suite("Pricing source chain")
struct PricingGapFillChainTests {

    private func entries(_ id: String, input: Double) -> [String: [String: Any]] {
        [id: ["input_cost_per_token": input]]
    }

    /// Order is the contract: a later source may only supply a price nobody
    /// had. If a secondary could overwrite, adding a source would silently
    /// re-price history — the thing that must never happen quietly.
    @Test("an earlier source wins; a later one only fills gaps")
    func laterSourcesOnlyFillGaps() {
        let merged = PricingTable.gapFill(
            sources: [
                ("models.dev", entries("model-a", input: 1)),
                ("catwalk", entries("model-a", input: 999)),
            ],
            into: [:],
            covered: [:]
        )
        let a = merged["model-a"] as? [String: Any]
        #expect(a?["input_cost_per_token"] as? Double == 1)
    }

    @Test("a later source supplies a model no earlier source had")
    func laterSourceAddsNewModels() {
        let merged = PricingTable.gapFill(
            sources: [
                ("models.dev", entries("model-a", input: 1)),
                ("catwalk", entries("model-b", input: 2)),
            ],
            into: [:],
            covered: [:]
        )
        #expect(merged.count == 2)
        #expect((merged["model-b"] as? [String: Any])?["input_cost_per_token"] as? Double == 2)
    }

    @Test("a failed source is skipped, not fatal")
    func nilSourceIsSkipped() {
        let merged = PricingTable.gapFill(
            sources: [("models.dev", nil), ("catwalk", entries("model-b", input: 2))],
            into: [:],
            covered: [:]
        )
        #expect(merged.count == 1)
        #expect(merged["model-b"] != nil)
    }

    @Test("no sources at all leaves the primary table untouched")
    func emptyChainIsIdentity() {
        let base: [String: Any] = ["kept": ["input_cost_per_token": 5.0]]
        let merged = PricingTable.gapFill(sources: [], into: base, covered: [:])
        #expect(merged.count == 1)
        #expect(merged["kept"] != nil)
    }
}
