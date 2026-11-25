import Foundation

/// When the app re-fetches the pricing catalogs and the curated price
/// history (`AppBackgroundService`'s refresh loop), as plain logic.
///
/// Daily, normally: a catalog update only changes what future samples cost
/// at catalog rates, and the ledger records it either way. **Hourly while a
/// model with usage has no price** (`UnpricedModels`): every cost that model
/// touches reads $0 until a price arrives, and the one that arrives first is
/// usually a curated row added to `site/public/price-history.json` for a
/// launch the catalogs have not caught up with. The ledger reprices the
/// model's history the cycle after, so an hour is the longest it reads low.
///
/// A failed attempt waits `retryInterval` before the next, at either
/// cadence: an hourly cadence never retries sooner than a daily one did.
public enum PricingRefreshSchedule {

    /// Between refreshes while every used model has a price.
    public static let regularInterval: TimeInterval = 24 * 3600
    /// Between refreshes while some used model has none.
    public static let unpricedInterval: TimeInterval = 3600
    /// After an attempt that produced nothing new: network down, a decode
    /// failure. One hour matches typical CDN outage recovery windows.
    public static let retryInterval: TimeInterval = 3600
    /// The longest the loop sleeps before looking again, so a model that
    /// turns up unpriced in the middle of a daily wait is checked for within
    /// the hour, not at the next daily refresh. Waking costs a file stat.
    public static let recheckInterval: TimeInterval = 3600
    /// The shortest sleep, so a clock or mtime oddity cannot spin the loop.
    public static let minimumDelay: TimeInterval = 60

    public static func interval(hasUnpriced: Bool) -> TimeInterval {
        hasUnpriced ? unpricedInterval : regularInterval
    }

    /// Whether a refresh is due, given the catalog cache's age (nil when
    /// there is no cache yet: due).
    public static func isDue(cacheAge: TimeInterval?, hasUnpriced: Bool) -> Bool {
        guard let cacheAge else { return true }
        return cacheAge >= interval(hasUnpriced: hasUnpriced)
    }

    /// How long to sleep after a pass. `attempted`: the pass refreshed;
    /// `succeeded`: the catalog refresh produced a table. `cacheAge` is read
    /// after the pass.
    public static func delay(attempted: Bool, succeeded: Bool,
                             cacheAge: TimeInterval?, hasUnpriced: Bool) -> TimeInterval {
        if attempted && !succeeded { return retryInterval }
        let untilDue = interval(hasUnpriced: hasUnpriced) - (cacheAge ?? 0)
        return min(recheckInterval, max(minimumDelay, untilDue))
    }
}

/// One refresh pass: the catalogs, then the curated history, then the cost
/// cache reload if either produced a new copy.
///
/// The reload used to follow only a catalog refresh, so a curated-only
/// update (a price added to the published history while the catalogs were
/// unreachable or unchanged) sat on disk until the next catalog refresh or
/// relaunch: up to a day, for the one source that exists to be quick.
public enum PricingRefreshPass {

    public struct Outcome: Equatable, Sendable {
        public let catalogRefreshed: Bool
        public let curatedRefreshed: Bool
        /// `SampleCostCache.reload()` ran.
        public let reloaded: Bool
        /// The reload installed different catalog or curated prices
        /// (`SampleCostCache.catalogGeneration` moved): the ledger has
        /// something to sync.
        public let pricesChanged: Bool
    }

    /// The app's three steps; tests pass their own.
    public static func fetchCatalogs() async -> Bool { await PricingTable.shared.refresh() }
    public static func fetchCurated() async -> Bool { await CuratedPriceHistory.refresh() }
    @MainActor public static func reloadCostCache() async { await SampleCostCache.reload() }

    @MainActor
    public static func run(
        refreshCatalog: () async -> Bool = fetchCatalogs,
        refreshCurated: () async -> Bool = fetchCurated,
        reload: () async -> Void = reloadCostCache
    ) async -> Outcome {
        let catalog = await refreshCatalog()
        // Best-effort, and never blocks the catalog's result.
        let curated = await refreshCurated()
        guard catalog || curated else {
            return Outcome(catalogRefreshed: false, curatedRefreshed: false,
                           reloaded: false, pricesChanged: false)
        }
        let before = SampleCostCache.catalogGeneration
        await reload()
        return Outcome(catalogRefreshed: catalog, curatedRefreshed: curated, reloaded: true,
                       pricesChanged: SampleCostCache.catalogGeneration != before)
    }
}
