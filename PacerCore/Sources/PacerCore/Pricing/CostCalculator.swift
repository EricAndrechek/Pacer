import Foundation

/// Cost calculation modes mirroring ccusage's `--mode`. The names match
/// ccusage exactly so users can swap between the two tools and get the
/// same output for a given config.
public enum CostMode: String, Sendable, CaseIterable {
    /// Default. Use Claude Code's stored `costUSD` if present, compute
    /// from tokens × pricing otherwise.
    case auto

    /// Always compute from tokens × pricing. Useful for consistent
    /// methodology across history when CC's cost calculation evolves.
    case calculate

    /// Always use stored `costUSD`. Defaults to 0 when missing. Cheapest
    /// — no pricing lookup at all.
    case display
}

/// Applies pricing to usage. Every cost Pacer shows goes through
/// `sampleCost`, which prices one request at the rate in effect when it was
/// made (`PriceLedger`) and returns it split by category.
public struct CostCalculator: Sendable {

    public let mode: CostMode
    private let table: PricingTable

    public init(mode: CostMode = .auto, table: PricingTable = .shared) {
        self.mode = mode
        self.table = table
    }

    /// Cost for a single parsed entry, priced against `table`'s catalog plus
    /// the bundled curated history. A convenience for tools and tests that
    /// hold a `PricingTable` rather than the app's `SampleCostCache`.
    public func cost(for entry: ParsedUsageEntry) async -> Double {
        if mode == .display { return entry.storedCostUSD ?? 0 }
        try? await table.ensureLoaded()
        let snapshot = await table.snapshot()
        let ledger = PriceLedger.provisional(
            catalog: snapshot.pricingByModel,
            curated: (try? CuratedPriceHistory.bundled().records) ?? [])
        return Self.sampleCost(
            storedCostUSD: entry.storedCostUSD, model: entry.model, sampledAt: entry.timestamp,
            breakdown: entry.breakdown, mode: mode, ledger: ledger
        ).total
    }

    /// One flat catalog row applied to a breakdown, with no dates involved.
    /// Goes through the same ledger arithmetic as everything else, so a test
    /// of this is a test of the real path.
    public static func cost(breakdown: TokenBreakdown, pricing: LiteLLMModelPricing) -> Double {
        let id = CanonicalModelID(model: "flat")
        let records = PriceLedger.templates(for: id, pricing: pricing, source: .litellm)
            .map { r -> PriceRecordValue in
                var r = r
                r.effectiveFrom = .distantPast
                return r
            }
        return PriceLedger(records: records)
            .cost(model: "flat", at: Date(), breakdown: breakdown).total
    }

    /// What one sample costs under `mode`, split by category, and which
    /// price records decided it.
    ///
    /// - `.display`  — Claude Code's stored `costUSD`, or zero.
    /// - `.auto`     — the stored cost when there is one, else priced.
    /// - `.calculate`— always priced; a stored cost is ignored.
    ///
    /// A stored cost has no category split, so it is apportioned like the
    /// priced cost would have been (`CostComponents.apportion`): the five
    /// columns still sum to the total the user sees.
    public static func sampleCost(
        storedCostUSD: Double?,
        model: String,
        sampledAt: Date,
        speed: PriceSpeed = .standard,
        breakdown: TokenBreakdown,
        mode: CostMode,
        ledger: PriceLedger
    ) -> SampleCost {
        switch mode {
        case .display:
            guard let stored = storedCostUSD else { return .zero }
            return SampleCost(components: .apportion(stored, like: .zero, tokens: breakdown))
        case .auto:
            if let stored = storedCostUSD {
                let weights = ledger.cost(
                    model: model, at: sampledAt, speed: speed, breakdown: breakdown).components
                return SampleCost(components: .apportion(stored, like: weights, tokens: breakdown))
            }
            return ledger.cost(model: model, at: sampledAt, speed: speed, breakdown: breakdown)
        case .calculate:
            return ledger.cost(model: model, at: sampledAt, speed: speed, breakdown: breakdown)
        }
    }

    /// `sampleCost` for anything a rollup aggregates.
    public static func sampleCost<S: AggregatableSample>(
        _ sample: S, mode: CostMode, snapshot: PricingTable.Snapshot
    ) -> SampleCost {
        sampleCost(
            storedCostUSD: sample.sourceCostUSD, model: sample.model,
            sampledAt: sample.sampledAt, breakdown: sample.breakdown,
            mode: mode, ledger: snapshot.ledger)
    }

    /// The total of `sampleCost`.
    public static func cost<S: AggregatableSample>(
        _ sample: S, mode: CostMode, snapshot: PricingTable.Snapshot
    ) -> Double {
        sampleCost(sample, mode: mode, snapshot: snapshot).total
    }
}
