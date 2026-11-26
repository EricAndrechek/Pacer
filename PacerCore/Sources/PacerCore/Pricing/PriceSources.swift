import Foundation

/// Where this Mac gets catalog prices from since #469, and when it asks.
///
/// **Our price list first.** `bin/price-catalog-sync.py` merges LiteLLM,
/// models.dev and Catwalk on a schedule, the same way `PricingTable` does, and
/// publishes the result as dated records in the price history the app already
/// fetches once a day (`CuratedPriceHistory`, its `catalog` section). Every Mac
/// then gets the same effective date for a price change, contacts no third
/// party, and downloads a few KB instead of LiteLLM's several MB.
///
/// **The catalogs directly, only as a fallback** (`directReason`), so a Mac
/// never ends up with fewer prices than it had: when the list is missing, when
/// it has not been confirmed for `listStaleAfter` (the job re-confirms it at
/// least weekly, so this means the job or the site is broken), or when a model
/// in use is priced by neither the curated history nor the list (another
/// backend Claude Code was pointed at, or a launch the job has not picked up).
/// The direct fetch keeps its daily cadence (hourly retries after a failure),
/// and the records this Mac dated
/// from it stay in the ledger: they fill whatever the list does not cover, and
/// the list's records win wherever both do (`PriceLedger.precedence`).
public enum PriceSources {

    /// Between direct catalog fetches, at any cadence. The list's own cadence
    /// (daily, hourly while a new model is unpriced, an hour after a failed
    /// check; a copy that is merely not newer is a good check) is
    /// `PricingRefreshSchedule`'s.
    public static let refreshInterval: TimeInterval = PricingRefreshSchedule.regularInterval
    /// The list is treated as stale once its `checkedAt` is this old. The
    /// job runs every six hours and writes a heartbeat at least every seven
    /// days, so ten days is three days of failures.
    public static let listStaleAfter: TimeInterval = 10 * 86_400

    /// Why the catalogs should be fetched directly.
    public enum DirectReason: String, Sendable, Equatable {
        /// The list has no catalog section (never fetched, or a site copy
        /// from before #469).
        case noList = "no_list"
        /// The list has not been confirmed for `listStaleAfter`.
        case stale
        /// A model in use is priced by neither the curated history nor the
        /// list, or which models are in use is not known yet.
        case uncovered
    }

    /// nil when the list is enough.
    ///
    /// `outsideList` nil means not known yet (no scan has worked it out on
    /// this Mac): treated as uncovered, which is what every Mac did before.
    public static func directReason(list: CuratedPriceHistory, outsideList: Set<String>?,
                                    now: Date = Date()) -> DirectReason? {
        guard !list.catalog.isEmpty, let checked = list.catalogCheckedAt else { return .noList }
        if now.timeIntervalSince(checked) > listStaleAfter { return .stale }
        guard let outsideList, outsideList.isEmpty else { return .uncovered }
        return nil
    }

    // MARK: - Models the list does not cover

    static let outsideListKey = "pacer.priceList.modelsOutside"

    /// Store which models in use the list and the curated history do not
    /// price (`ScanCoordinator` works it out). Persisted so a launch knows
    /// before its first scan. True when it changed.
    @discardableResult
    public static func recordModelsOutsideList(_ models: Set<String>,
                                               store: UserDefaults = PacerPreferences.store) -> Bool {
        let sorted = models.sorted()
        if let old = store.array(forKey: outsideListKey) as? [String], old == sorted { return false }
        store.set(sorted, forKey: outsideListKey)
        return true
    }

    /// nil until a scan has recorded it on this Mac.
    public static func modelsOutsideList(store: UserDefaults = PacerPreferences.store) -> Set<String>? {
        (store.array(forKey: outsideListKey) as? [String]).map(Set.init)
    }

    // MARK: - One pass

    /// What a pass reads and does; the app's by default, a test's own.
    public struct Steps {
        /// `listCheckAge`.
        public var listAge: () -> TimeInterval?
        /// `PricingTable.cacheAge`: the direct fetch's own clock.
        public var catalogAge: () -> TimeInterval?
        public var fetchList: () async -> CuratedPriceHistory.RefreshResult
        public var fetchCatalogs: () async -> Bool
        public var list: () -> CuratedPriceHistory
        public var outsideList: () -> Set<String>?

        public init(listAge: @escaping () -> TimeInterval?, catalogAge: @escaping () -> TimeInterval?,
                    fetchList: @escaping () async -> CuratedPriceHistory.RefreshResult,
                    fetchCatalogs: @escaping () async -> Bool,
                    list: @escaping () -> CuratedPriceHistory, outsideList: @escaping () -> Set<String>?) {
            self.listAge = listAge
            self.catalogAge = catalogAge
            self.fetchList = fetchList
            self.fetchCatalogs = fetchCatalogs
            self.list = list
            self.outsideList = outsideList
        }

        public static var app: Steps {
            Steps(listAge: { listCheckAge() },
                  catalogAge: { PricingTable.cacheAge() },
                  fetchList: { await CuratedPriceHistory.refreshResult() },
                  fetchCatalogs: { await PricingTable.shared.refresh() },
                  list: { CuratedPriceHistory.load() },
                  outsideList: { modelsOutsideList() })
        }
    }

    /// The direct fetch's clock: daily, whatever the loop's cadence. A failed
    /// attempt leaves the cache's age where it was, so it is due again at the
    /// loop's next (hourly at most) wake: the hourly retry.
    static func isDue(_ age: TimeInterval?) -> Bool { (age ?? .infinity) >= refreshInterval }

    /// Whether the catalogs are wanted directly and due: a pass needed for
    /// them alone (`PricingRefreshLoop.Inputs.alsoDue`).
    public static func catalogsDue(_ steps: Steps = .app, now: Date = Date()) -> Bool {
        directReason(list: steps.list(), outsideList: steps.outsideList(), now: now) != nil
            && isDue(steps.catalogAge())
    }

    /// How long ago the list last got a usable answer: a newer copy, or one
    /// that brought nothing new. Falls back to the cache file's age for a
    /// Mac that has not recorded one yet.
    public static func listCheckAge(store: UserDefaults = PacerPreferences.store, now: Date = Date()) -> TimeInterval? {
        CuratedPriceHistory.lastGoodCheck(store: store).map { now.timeIntervalSince($0) }
            ?? CuratedPriceHistory.cacheAge(now: now)
    }

    /// One pass of the app's loop, through `PricingRefreshPass.run`:
    ///
    /// - the price list, when it is due at this cadence: hourly while a new
    ///   model is unpriced (`PricingRefreshSchedule.interval(hourly:)`; the
    ///   list is where its price lands first), daily otherwise;
    /// - then the catalogs, only when the list (as it now stands) falls short
    ///   (`directReason`), and at most daily even while hourly: re-downloading
    ///   LiteLLM's several MB every hour would buy nothing the list does not
    ///   bring sooner.
    @MainActor
    public static func pass(hourly: Bool, steps: Steps = .app, now: Date = Date(),
                            reload: () async -> Void = PricingRefreshPass.reloadCostCache,
                            generation: () -> UInt64 = PricingRefreshPass.catalogGeneration)
        async -> PricingRefreshPass.Outcome {
        let listDue = PricingRefreshSchedule.isDue(cacheAge: steps.listAge(), hourly: hourly)
        var reason: DirectReason?
        var seconds: TimeInterval?
        let outcome = await PricingRefreshPass.run(
            refreshCatalog: {
                reason = directReason(list: steps.list(), outsideList: steps.outsideList(), now: now)
                guard reason != nil, isDue(steps.catalogAge()) else { return false }
                let started = Date()
                let ok = await steps.fetchCatalogs()
                seconds = Date().timeIntervalSince(started)
                return ok
            },
            // Not due is a good check too: the clock is fine.
            refreshCurated: { listDue ? await steps.fetchList() : .current },
            reload: reload, generation: generation)
        return PricingRefreshPass.Outcome(
            catalogRefreshed: outcome.catalogRefreshed, curatedRefreshed: outcome.curatedRefreshed,
            reloaded: outcome.reloaded, pricesChanged: outcome.pricesChanged,
            listChecked: outcome.listChecked, direct: reason, catalogSeconds: seconds)
    }
}
