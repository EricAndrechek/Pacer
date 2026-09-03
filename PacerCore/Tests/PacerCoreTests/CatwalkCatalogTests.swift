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

@Suite("Pricing consensus")
struct PricingConsensusTests {

    private func entry(_ input: Double? = nil, output: Double? = nil,
                       write: Double? = nil, read: Double? = nil) -> [String: Any] {
        var e: [String: Any] = [:]
        if let input { e["input_cost_per_token"] = input }
        if let output { e["output_cost_per_token"] = output }
        if let write { e["cache_creation_input_token_cost"] = write }
        if let read { e["cache_read_input_token_cost"] = read }
        return e
    }

    /// Decode rather than construct: `LiteLLMModelPricing` has a wide
    /// initialiser and the tests only care that the key is *covered*.
    private func covered(_ raw: [String: Any]) -> [String: LiteLLMModelPricing] {
        PricingTable.decode(json: raw)
    }

    /// The reason consensus exists at all: tiering can only fill a gap, so a
    /// wrong price in the primary survives forever — and downstream a wrong
    /// price is indistinguishable from a right one.
    @Test("two sources outvote a wrong primary")
    func majorityOverridesThePrimary() {
        let merged = PricingTable.reconcile(
            secondaries: [
                ("models.dev", ["m": entry(2)]),
                ("catwalk", ["m": entry(2)]),
            ],
            into: ["m": entry(99)],
            covered: covered(["m": entry(1)])
        )
        #expect((merged["m"] as? [String: Any])?["input_cost_per_token"] as? Double == 2)
    }

    @Test("a unanimous table is left exactly as it was")
    func unanimityChangesNothing() {
        let merged = PricingTable.reconcile(
            secondaries: [("models.dev", ["m": entry(2)]), ("catwalk", ["m": entry(2)])],
            into: ["m": entry(2)],
            covered: covered(["m": entry(1)])
        )
        #expect((merged["m"] as? [String: Any])?["input_cost_per_token"] as? Double == 2)
    }

    /// An arbitrary tie-break dressed up as consensus is worse than a
    /// known-provenance number, so a three-way split keeps the primary.
    @Test("no majority keeps the primary rather than inventing a winner")
    func threeWaySplitKeepsPrimary() {
        let merged = PricingTable.reconcile(
            secondaries: [("models.dev", ["m": entry(2)]), ("catwalk", ["m": entry(3)])],
            into: ["m": entry(1)],
            covered: covered(["m": entry(1)])
        )
        #expect((merged["m"] as? [String: Any])?["input_cost_per_token"] as? Double == 1)
    }

    /// Coverage is ragged — a catalog may publish input/output and omit the
    /// cache tiers. Voting per field keeps its votes on the fields it has.
    @Test("votes are counted per field, not per model")
    func consensusIsPerField() {
        let merged = PricingTable.reconcile(
            secondaries: [
                ("models.dev", ["m": entry(2, output: 20)]),
                ("catwalk", ["m": entry(2)]),          // no output at all
            ],
            into: ["m": entry(99, output: 20)],
            covered: covered(["m": entry(1)])
        )
        let m = merged["m"] as? [String: Any]
        #expect(m?["input_cost_per_token"] as? Double == 2)    // 2 of 3 agree
        #expect(m?["output_cost_per_token"] as? Double == 20)  // uncontested
    }

    @Test("a model no primary covers is added outright")
    func newModelsAreAdded() {
        let merged = PricingTable.reconcile(
            secondaries: [("catwalk", ["brand-new": entry(7, output: 70)])],
            into: [:], covered: [:]
        )
        let m = merged["brand-new"] as? [String: Any]
        #expect(m?["input_cost_per_token"] as? Double == 7)
        #expect(m?["output_cost_per_token"] as? Double == 70)
    }

    /// The primary keys entries under names Claude Code never emits, so a
    /// vote must land on the key a lookup resolves to — not the bare id, or
    /// the corrected price would sit in a row nothing reads.
    @Test("a correction lands on the key a lookup actually resolves to")
    func correctionsFollowFuzzyMatching() {
        let merged = PricingTable.reconcile(
            secondaries: [
                ("models.dev", ["claude-x": entry(2)]),
                ("catwalk", ["claude-x": entry(2)]),
            ],
            into: ["anthropic/claude-x": entry(99)],
            covered: covered(["anthropic/claude-x": entry(1)])
        )
        #expect((merged["anthropic/claude-x"] as? [String: Any])?["input_cost_per_token"] as? Double == 2)
        #expect(merged["claude-x"] == nil)   // not duplicated under the bare id
    }

    @Test("a source that failed to fetch simply does not vote")
    func nilSourceDoesNotVote() {
        let merged = PricingTable.reconcile(
            secondaries: [("models.dev", nil), ("catwalk", ["m": entry(2)])],
            into: ["m": entry(99)], covered: covered(["m": entry(1)])
        )
        // One vote each, no majority → primary stands.
        #expect((merged["m"] as? [String: Any])?["input_cost_per_token"] as? Double == 99)
    }

    @Test("zero and negative readings are not votes")
    func placeholdersDoNotVote() {
        let merged = PricingTable.reconcile(
            secondaries: [("models.dev", ["m": entry(0)]), ("catwalk", ["m": entry(0)])],
            into: ["m": entry(5)], covered: covered(["m": entry(1)])
        )
        #expect((merged["m"] as? [String: Any])?["input_cost_per_token"] as? Double == 5)
    }
}
