import Foundation
import SwiftData

/// Reads what the live meter needs from the store, cheaply, and hands it to
/// `LiveMeter.value` (#318).
///
/// **Reads, all bounded.** Per window, the latest `SpendMeterFit` row
/// (`fetchLimit` 1 on the `(accountId, window, fittedDay)` index). Then one
/// read of the account's `TokenSample`s since the earliest reading among its
/// windows, on the `(accountId, sampledAt)` index with a `fetchLimit`
/// backstop. A reading is at most `LiveMeter.maxReadingAge` old, so that is
/// at most an hour of one account's turns, and in steady state the five
/// minutes since the last poll. No 14-day read: the fit is #317's daily job.
/// A window with no fit costs one probe and no sample read.
///
/// **Priced the way the fit was.** The fit's spend is
/// `AccountHourlyAggregate.totalCostUSD`, which `HourlyAggregateRecomputer`
/// sums from `CostCalculator.sampleCost` under the scan's cost mode
/// (`PacerPreferences.costMode()`) and the store's price ledger. Each sample
/// here goes through that same function with that same mode and ledger, so a
/// dollar here is the dollar the rate was fitted on. A different basis (the
/// stored `costUSD` alone, or the catalog's current price) would scale every
/// live point by the ratio between the two.
///
/// Not `Sendable`: it holds a `ModelContext`. Make one per build on the
/// thread that owns the context; never on the main actor for a build that
/// runs per scan tick (the API snapshot builds off it).
public struct LiveMeterSource {

    /// One window to estimate: its key, the reading to start from, and for a
    /// per-model cap, the model it names.
    public struct Window: Sendable, Equatable {
        /// `five_hour`, `seven_day`, or a scoped `limits[]` identity: the
        /// `SpendMeterFit.window` key.
        public let key: String
        public let duration: TimeInterval
        public let reading: MeterReading
        public var capModelId: String?
        public var capModelName: String?

        public init(key: String, duration: TimeInterval, reading: MeterReading,
                    capModelId: String? = nil, capModelName: String? = nil) {
            self.key = key
            self.duration = duration
            self.reading = reading
            self.capModelId = capModelId
            self.capModelName = capModelName
        }
    }

    /// More turns than this since a reading under an hour old means
    /// something is wrong (a replay, a backfill), and a partial sum would
    /// under-read, so there is no value rather than a low one.
    public static let sampleFetchLimit = 20_000

    private let context: ModelContext
    private let mode: CostMode
    private let pricingOverride: PricingTable.Snapshot?

    /// `mode` defaults to the user's setting, the one the scan priced the
    /// rollups with. `pricing` defaults to the store's ledger: the process's
    /// `SampleCostCache` once the scan has installed it there, else read from
    /// the store (the `pacer` command line, which never scans).
    public init(context: ModelContext, mode: CostMode = PacerPreferences.costMode(),
                pricing: PricingTable.Snapshot? = nil) {
        self.context = context
        self.mode = mode
        self.pricingOverride = pricing
    }

    // MARK: - Values

    /// Every window of `account` that has a fit and a recent enough reading,
    /// keyed by `Window.key`.
    public func values(account: String, windows: [Window], now: Date) -> [String: LiveMeterValue] {
        var plans: [(window: Window, rates: LiveMeterRates, from: Date)] = []
        for w in windows {
            guard now.timeIntervalSince(w.reading.at) <= LiveMeter.maxReadingAge,
                  let start = LiveMeter.start(reading: w.reading, duration: w.duration, now: now),
                  let rates = latestRates(account: account, window: w.key)
            else { continue }
            plans.append((w, rates, start.from))
        }
        guard let from = plans.map(\.from).min(), let spend = spend(account: account, after: from, through: now)
        else { return [:] }

        var out: [String: LiveMeterValue] = [:]
        for plan in plans {
            let counts = SpendMeterFitter.capCounts(modelId: plan.window.capModelId,
                                                    displayName: plan.window.capModelName)
            out[plan.window.key] = LiveMeter.value(
                reading: plan.window.reading, duration: plan.window.duration,
                rates: plan.rates, spend: spend, counts: counts, now: now)
        }
        return out
    }

    /// One window's value, reading its latest reading too: a fixed window
    /// from `RateLimitSample`, a scoped identity from `UsageLimitSample`.
    public func value(account: String, window key: String, now: Date) -> LiveMeterValue? {
        guard let window = latestReading(account: account, window: key) else { return nil }
        return values(account: account, windows: [window], now: now)[key]
    }

    // MARK: - Reads

    /// The newest fit for (account, window), whatever day it was made: rates
    /// drift slowly, and a Mac that has not run the daily job for a while
    /// still has a better estimate than the bare reading.
    func latestRates(account: String, window: String) -> LiveMeterRates? {
        var d = FetchDescriptor<SpendMeterFit>(
            predicate: #Predicate { $0.accountId == account && $0.window == window },
            sortBy: [SortDescriptor(\.fittedDay, order: .reverse)])
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first.map(LiveMeterRates.init)
    }

    /// The account's turns in `(after, through]`, priced; nil when the
    /// backstop was hit. Turns with no account are never counted: the
    /// predicate is on the account that billed them.
    func spend(account: String, after: Date, through: Date,
               limit: Int = sampleFetchLimit) -> [LiveSpend]? {
        var d = FetchDescriptor<TokenSample>(
            predicate: #Predicate {
                $0.accountId == account && $0.sampledAt > after && $0.sampledAt <= through
            },
            sortBy: [SortDescriptor(\.sampledAt)])
        d.fetchLimit = limit + 1
        guard let samples = try? context.fetch(d) else { return nil }
        guard samples.count <= limit else {
            Log.write("LiveMeter", "\(account.suffix(4)): over \(limit) turns since the reading; no live value")
            return nil
        }
        guard !samples.isEmpty else { return [] }
        let pricing = resolvedPricing()
        return samples.map {
            LiveSpend(at: $0.sampledAt, model: $0.model,
                      costUSD: CostCalculator.cost($0, mode: mode, snapshot: pricing))
        }
    }

    /// The latest reading of one window, with the model a scoped cap names;
    /// with `before`, the latest one taken before that instant.
    func latestReading(account: String, window key: String, before: Date = .distantFuture) -> Window? {
        if let duration = PaceMath.windowDuration(for: key) {
            var d = FetchDescriptor<RateLimitSample>(
                predicate: #Predicate { $0.accountId == account && $0.window == key && $0.sampledAt < before },
                sortBy: [SortDescriptor(\.sampledAt, order: .reverse)])
            d.fetchLimit = 1
            guard let row = (try? context.fetch(d))?.first else { return nil }
            return Window(key: key, duration: duration,
                          reading: MeterReading(at: row.sampledAt, percent: row.usedPercentage,
                                                resetsAt: row.resetsAt))
        }
        var d = FetchDescriptor<UsageLimitSample>(
            predicate: #Predicate { $0.accountId == account && $0.identity == key && $0.sampledAt < before },
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)])
        d.fetchLimit = 1
        guard let row = (try? context.fetch(d))?.first else { return nil }
        return Window(key: key, duration: WindowSpec.scopedDuration(group: row.group),
                      reading: MeterReading(at: row.sampledAt, percent: row.percent, resetsAt: row.resetsAt),
                      capModelId: row.modelId, capModelName: row.modelDisplayName)
    }

    /// The store's price ledger: the one the scan installed in this
    /// process, else read from the store. Never the provisional stand-in
    /// `SampleCostCache` holds before the scan's first cycle, which can
    /// price a model the store's ledger has a dated record for differently.
    private func resolvedPricing() -> PricingTable.Snapshot {
        if let pricingOverride { return pricingOverride }
        if SampleCostCache.hasLedgerFromStore { return SampleCostCache.current() }
        let ledger = (try? PriceLedgerStore.load(context: context)) ?? .empty
        return PricingTable.Snapshot(pricingByModel: SampleCostCache.current().pricingByModel, ledger: ledger)
    }
}
