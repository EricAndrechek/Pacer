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
///
/// **Two layers since #296.** The catalog (`PricingTable`'s current rates) is
/// loaded here, but samples are priced by the *ledger* — dated records, read
/// from the store by `ScanCoordinator` and installed with `installLedger`.
/// Until that has happened, the snapshot carries a provisional ledger built
/// from the catalog and the bundled curated history; `ScanCoordinator`
/// installs the real one before it recomputes anything, so only views can
/// briefly see the stand-in.
@MainActor
public enum SampleCostCache {
    nonisolated(unsafe) private static var snapshotStorage: PricingTable.Snapshot =
        PricingTable.Snapshot(pricingByModel: [:], ledger: .empty)
    nonisolated(unsafe) private static var curatedStorage: CuratedPriceHistory = .empty
    nonisolated(unsafe) private static var hasStoreLedger = false

    /// Latest pricing snapshot. Sync. Empty until `reload()` has been
    /// awaited at least once. Safe to call from any thread.
    public static nonisolated func current() -> PricingTable.Snapshot {
        snapshotStorage
    }

    /// The curated price history last loaded by `reload()`.
    public static nonisolated func curated() -> CuratedPriceHistory {
        curatedStorage
    }

    /// Whether `reload()` has produced anything. False means every
    /// computed cost would come out $0 — see the type doc.
    public static nonisolated var isWarm: Bool {
        !snapshotStorage.pricingByModel.isEmpty
    }

    /// Whether the ledger in use came from the store rather than being the
    /// provisional stand-in.
    public static nonisolated var hasLedgerFromStore: Bool { hasStoreLedger }

    nonisolated(unsafe) private static var generationStorage: UInt64 = 0
    nonisolated(unsafe) private static var catalogGenerationStorage: UInt64 = 0

    /// Bumped every time the prices samples are priced with actually change
    /// — the ledger, not every `reload()`, which runs on each cost-mode flip
    /// and pricing refresh and usually installs identical prices. Anything
    /// that caches a cost computed from `current()` compares this to know its
    /// cached cost is stale: `ScanCoordinator` forgets `SessionRollupCache` on
    /// a change, since those cached values bake the old prices into
    /// `totalCostUSD` and the fast path would keep adding to them.
    public static nonisolated var generation: UInt64 { generationStorage }

    /// Bumped when the catalog or the curated file changes — the inputs the
    /// ledger is synced from. `ScanCoordinator` re-syncs the ledger when it
    /// moves.
    public static nonisolated var catalogGeneration: UInt64 { catalogGenerationStorage }

    /// Load (if needed) and atomically refresh the snapshot. Call
    /// from `applicationDidFinishLaunching` and on cost-mode change.
    public static func reload(_ table: PricingTable = .shared, curatedCacheURL: URL? = nil) async {
        try? await table.ensureLoaded()
        let catalog = await table.snapshot()
        install(catalog: catalog, curated: CuratedPriceHistory.load(cacheURL: curatedCacheURL))
    }

    /// Replace the catalog, keeping the store's ledger once there is one.
    static func install(catalog snap: PricingTable.Snapshot, curated: CuratedPriceHistory = .empty) {
        // `nonisolated(unsafe)` storage above lets readers from any
        // actor get the value sync; the write is single-threaded
        // because this is @MainActor-isolated.
        let catalogChanged = snap.pricingByModel != snapshotStorage.pricingByModel
        let curatedChanged = curated != curatedStorage
        guard catalogChanged || curatedChanged else { return }
        curatedStorage = curated
        catalogGenerationStorage &+= 1
        let ledger = hasStoreLedger
            ? snapshotStorage.ledger
            : PriceLedger.provisional(catalog: snap.pricingByModel, curated: curated.records)
        let previous = snapshotStorage.ledger
        snapshotStorage = snap.with(ledger: ledger)
        if !ledger.samePrices(as: previous) { generationStorage &+= 1 }
    }

    /// Kept for callers that install a ready snapshot (tests).
    static func install(_ snap: PricingTable.Snapshot) {
        let previous = snapshotStorage.ledger
        snapshotStorage = snap
        if !snap.ledger.samePrices(as: previous) { generationStorage &+= 1 }
    }

    /// Install the ledger read from the store. From here on, `reload()`
    /// updates the catalog but keeps this ledger until the next install.
    public static func installLedger(_ ledger: PriceLedger) {
        hasStoreLedger = true
        let previous = snapshotStorage.ledger
        snapshotStorage = snapshotStorage.with(ledger: ledger)
        if !ledger.samePrices(as: previous) { generationStorage &+= 1 }
    }
}

public extension TokenSample {
    /// Resolved cost for this sample under the given cost mode using
    /// the process-wide pricing cache. The single SOURCE OF TRUTH for
    /// "what does this sample cost" at the view layer — replaces the
    /// scattered `sourceCostUSD ?? 0` blocks that silently dropped
    /// the calculate-mode fallback.
    ///
    /// The recomputers price through the same cache (and the same
    /// `CostCalculator.sampleCost`), so a view and a rollup cannot disagree
    /// about a sample's cost.
    @MainActor
    func effectiveCostUSD(mode: CostMode) -> Double {
        CostCalculator.cost(self, mode: mode, snapshot: SampleCostCache.current())
    }
}
