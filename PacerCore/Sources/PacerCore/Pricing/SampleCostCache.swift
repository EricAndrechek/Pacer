import Foundation

/// Process-wide pricing snapshot cache for SwiftUI views (and any
/// other sync caller) that needs to compute per-sample cost.
///
/// **Why this exists**: every "cost = sourceCostUSD ?? 0" hand-roll
/// silently drops the calculate/auto-mode fallback to tokens × pricing.
/// The recomputers fixed it by threading mode + PricingTable through
/// their constructors; views need the same fix but can't sit on an
/// async actor lookup per row. This cache loads pricing once at app
/// launch (PacerAppDelegate calls `reload()`) and exposes a synchronous
/// snapshot every view can use the same way.
///
/// **What's safe**: read access from any actor — the snapshot is a
/// `Sendable` value type. Writes go through `reload()` which serializes
/// onto MainActor.
///
/// **The empty default is sharp.** Before `reload()` has been awaited the
/// snapshot prices nothing, and `CostCalculator` renders "no pricing" as
/// **$0** rather than as "unknown". A view that reads it early shows a
/// stale zero for one frame; a *recomputer* that reads it early writes that
/// zero into a rollup, where it is indistinguishable from a real total and
/// is never revisited.
///
/// All four recomputers read this cache (the actor hop to `PricingTable`
/// was costing ~150 ms per phase per cycle). So the scan path must not run
/// a recompute until this is warm — `ScanCoordinator` awaits `reload()`
/// before its recomputer phase when `isWarm` is false. That guarantee used
/// to be stated here as "the recomputers don't read this cache at all",
/// which stopped being true when they started reading it and cost a day's
/// project costs their `claude-fable-5` share before `make verify-data`
/// caught it.
@MainActor
public enum SampleCostCache {
    nonisolated(unsafe) private static var snapshotStorage: PricingTable.Snapshot =
        PricingTable.Snapshot(pricingByModel: [:])

    /// Latest pricing snapshot. Sync. Empty until `reload()` has been
    /// awaited at least once. Safe to call from any thread.
    public static nonisolated func current() -> PricingTable.Snapshot {
        snapshotStorage
    }

    /// Whether `reload()` has produced anything. False means every
    /// computed cost would come out $0 — see the type doc.
    public static nonisolated var isWarm: Bool {
        !snapshotStorage.pricingByModel.isEmpty
    }

    /// Load (if needed) and atomically refresh the snapshot. Call
    /// from `applicationDidFinishLaunching` and on cost-mode change.
    public static func reload(_ table: PricingTable = .shared) async {
        try? await table.ensureLoaded()
        let snap = await table.snapshot()
        // `nonisolated(unsafe)` storage above lets readers from any
        // actor get the value sync; the write is single-threaded
        // because reload() itself is @MainActor-isolated.
        snapshotStorage = snap
    }
}

public extension TokenSample {
    /// Resolved cost for this sample under the given cost mode using
    /// the process-wide pricing cache. The single SOURCE OF TRUTH for
    /// "what does this sample cost" at the view layer — replaces the
    /// scattered `sourceCostUSD ?? 0` blocks that silently dropped
    /// the calculate-mode fallback.
    ///
    /// Recomputer code paths (AggregateRecomputer, etc.) keep their
    /// own pricing-table loading because they run during scan cycles
    /// and need to survive process restarts where the cache hasn't
    /// warmed yet. Views always run after launch, so the cache is
    /// always populated.
    @MainActor
    func effectiveCostUSD(mode: CostMode) -> Double {
        let breakdown = TokenBreakdown(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheCreation5mTokens: cacheCreation5mTokens,
            cacheCreation1hTokens: cacheCreation1hTokens
        )
        return CostCalculator.cost(
            storedCostUSD: sourceCostUSD,
            model: model,
            breakdown: breakdown,
            mode: mode,
            snapshot: SampleCostCache.current()
        )
    }
}
