import Foundation

/// When the app re-fetches the pricing catalogs and the curated price
/// history (`AppBackgroundService`'s refresh loop, through
/// `PricingRefreshLoop.tick`), as plain logic.
///
/// Daily, normally: a catalog update only changes what future samples cost
/// at catalog rates, and the ledger records it either way. **Hourly while a
/// newly used Claude model has no price** (`UnpricedModels.wantsHourlyChecks`:
/// a versioned Claude id first used within the last week): every cost that
/// model touches reads $0 until a price arrives, and the one that arrives
/// first is usually a curated row added to `site/public/price-history.json`
/// for a launch the catalogs have not caught up with. The ledger reprices the
/// model's history the cycle after, so an hour is the longest it reads low.
/// A model from another backend, or one unpriced for over a week, does not
/// keep the loop hourly: that would re-download the catalogs every hour for
/// good.
///
/// A pass that did not leave a fresh cache (the fetch failed, or its cache
/// write did) waits `retryInterval` before the next, at either cadence: an
/// hourly cadence never retries sooner than a daily one did.
public enum PricingRefreshSchedule {

    /// Between refreshes normally.
    public static let regularInterval: TimeInterval = 24 * 3600
    /// Between refreshes while a new Claude model has no price.
    public static let unpricedInterval: TimeInterval = 3600
    /// After a pass that produced nothing new: network down, a decode
    /// failure, a cache it could not write. One hour matches typical CDN
    /// outage recovery windows.
    public static let retryInterval: TimeInterval = 3600
    /// The longest the loop sleeps before looking again, so a model that
    /// turns up unpriced in the middle of a daily wait is checked for within
    /// the hour, not at the next daily refresh. Waking costs a file stat.
    public static let recheckInterval: TimeInterval = 3600
    /// The shortest sleep, so a clock or mtime oddity cannot spin the loop.
    public static let minimumDelay: TimeInterval = 60

    public static func interval(hourly: Bool) -> TimeInterval {
        hourly ? unpricedInterval : regularInterval
    }

    /// Whether a refresh is due, given the catalog cache's age (nil when
    /// there is no cache yet: due).
    public static func isDue(cacheAge: TimeInterval?, hourly: Bool) -> Bool {
        guard let cacheAge else { return true }
        return cacheAge >= interval(hourly: hourly)
    }

    /// How long to sleep after a pass. `attempted`: the pass refreshed;
    /// `succeeded`: the catalog refresh produced a table. `cacheAge` is read
    /// after the pass: a success whose cache is still due (its write failed)
    /// is a failure for this, or the loop would fetch again every minute.
    public static func delay(attempted: Bool, succeeded: Bool,
                             cacheAge: TimeInterval?, hourly: Bool) -> TimeInterval {
        if attempted && (!succeeded || isDue(cacheAge: cacheAge, hourly: hourly)) { return retryInterval }
        let untilDue = interval(hourly: hourly) - (cacheAge ?? 0)
        return min(recheckInterval, max(minimumDelay, untilDue))
    }
}

/// One turn of the app's pricing refresh loop: decide, maybe refresh, and say
/// how long to sleep. The app's loop is this and a sleep; tests drive it with
/// a clock of their own.
public enum PricingRefreshLoop {

    public struct Inputs {
        /// The catalog cache's age (`PricingTable.cacheAge`).
        public var cacheAge: () -> TimeInterval?
        /// `UnpricedModels.wantsHourlyChecks`.
        public var hourly: () -> Bool
        /// One refresh pass (`PricingRefreshPass.run` and what the app does
        /// with its outcome).
        public var refresh: (_ hourly: Bool) async -> PricingRefreshPass.Outcome

        public init(cacheAge: @escaping () -> TimeInterval?, hourly: @escaping () -> Bool,
                    refresh: @escaping (_ hourly: Bool) async -> PricingRefreshPass.Outcome) {
            self.cacheAge = cacheAge
            self.hourly = hourly
            self.refresh = refresh
        }
    }

    public struct Tick: Equatable, Sendable {
        /// nil when nothing was due.
        public let outcome: PricingRefreshPass.Outcome?
        public let delay: TimeInterval
    }

    @MainActor
    public static func tick(_ inputs: Inputs) async -> Tick {
        let hourly = inputs.hourly()
        let due = PricingRefreshSchedule.isDue(cacheAge: inputs.cacheAge(), hourly: hourly)
        let outcome = due ? await inputs.refresh(hourly) : nil
        let delay = PricingRefreshSchedule.delay(
            attempted: due, succeeded: outcome?.catalogRefreshed ?? false,
            cacheAge: inputs.cacheAge(), hourly: inputs.hourly())
        return Tick(outcome: outcome, delay: delay)
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

        public init(catalogRefreshed: Bool, curatedRefreshed: Bool, reloaded: Bool, pricesChanged: Bool) {
            self.catalogRefreshed = catalogRefreshed
            self.curatedRefreshed = curatedRefreshed
            self.reloaded = reloaded
            self.pricesChanged = pricesChanged
        }

        public static let nothing = Outcome(catalogRefreshed: false, curatedRefreshed: false,
                                            reloaded: false, pricesChanged: false)
    }

    /// The app's steps; tests pass their own.
    public static func fetchCatalogs() async -> Bool { await PricingTable.shared.refresh() }
    public static func fetchCurated() async -> Bool { await CuratedPriceHistory.refresh() }
    @MainActor public static func reloadCostCache() async { await SampleCostCache.reload() }
    public static func catalogGeneration() -> UInt64 { SampleCostCache.catalogGeneration }

    @MainActor
    public static func run(
        refreshCatalog: () async -> Bool = fetchCatalogs,
        refreshCurated: () async -> Bool = fetchCurated,
        reload: () async -> Void = reloadCostCache,
        generation: () -> UInt64 = catalogGeneration
    ) async -> Outcome {
        let catalog = await refreshCatalog()
        // Best-effort, and never blocks the catalog's result.
        let curated = await refreshCurated()
        guard catalog || curated else { return .nothing }
        let before = generation()
        await reload()
        return Outcome(catalogRefreshed: catalog, curatedRefreshed: curated, reloaded: true,
                       pricesChanged: generation() != before)
    }
}
