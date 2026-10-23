import Foundation
import SwiftData

/// Reads what the live meter needs from the store, cheaply, and hands it to
/// `LiveMeter.value` (#318).
///
/// **Reads, all bounded.** Per window, the latest `SpendMeterFit` row
/// (`fetchLimit` 1 on the `(accountId, window, fittedDay)` index), and the
/// window's readings in the hour before its latest one, for the carry
/// (`LiveMeter.carry`), on the `(accountId, window|identity, sampledAt)`
/// index. Then one read of the account's `TokenSample`s since the earliest of
/// those readings, on the `(accountId, sampledAt)` index with a `fetchLimit`
/// backstop. A reading is at most `LiveMeter.maxReadingAge` old, so that is at
/// most two hours of one account's turns, and in steady state the hour and a
/// few minutes since. No 14-day read: the fit is #317's daily job. A window
/// with no fit, or a weak one, costs one probe and nothing else.
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
        /// The window's readings in the `LiveMeter.carryLookback` before
        /// `reading`, ascending, `reading` last. Nil: the source reads them.
        public var history: [MeterReading]?

        public init(key: String, duration: TimeInterval, reading: MeterReading,
                    capModelId: String? = nil, capModelName: String? = nil,
                    history: [MeterReading]? = nil) {
            self.key = key
            self.duration = duration
            self.reading = reading
            self.capModelId = capModelId
            self.capModelName = capModelName
            self.history = history
        }
    }

    /// More turns than this since a reading under an hour old means
    /// something is wrong (a replay, a backfill), and a partial sum would
    /// under-read, so there is no value rather than a low one.
    public static let sampleFetchLimit = 20_000

    private let context: ModelContext
    private let mode: CostMode
    private let pricingOverride: PricingTable.Snapshot?
    /// Build a value even for a suspended window: the drift log, which keeps
    /// judging the estimate while it is not shown.
    var ignoresRunaway = false

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
        guard hasTables else { return [:] }
        let suspended = ignoresRunaway ? [:] : LiveMeterRunaway.suspendedDays(context: context, account: account)
        var plans: [(window: Window, rates: LiveMeterRates, history: [MeterReading], from: Date)] = []
        for w in windows {
            guard now.timeIntervalSince(w.reading.at) <= LiveMeter.maxReadingAge,
                  let start = LiveMeter.start(reading: w.reading, duration: w.duration, now: now),
                  let rates = latestRates(account: account, window: w.key), rates.isStrong,
                  // Suspended until the next daily fit after running high
                  // three readings in a row (`LiveMeterRunaway`).
                  suspended[w.key] != rates.fittedDay
            else { continue }
            let history = Self.carryHistory(w.history ?? readings(account: account, window: w.key,
                                                                    through: w.reading.at),
                                            ending: w.reading)
            plans.append((w, rates, history, min(start.from, history.first?.at ?? start.from)))
        }
        // Exclusive below, so the turn at the first reading's own instant
        // is out, as it is for the carry's first pair.
        guard let from = plans.map(\.from).min(), let spend = spend(account: account, after: from, through: now)
        else { return [:] }

        var out: [String: LiveMeterValue] = [:]
        for plan in plans {
            let counts = SpendMeterFitter.capCounts(modelId: plan.window.capModelId,
                                                    displayName: plan.window.capModelName)
            out[plan.window.key] = LiveMeter.estimate(
                history: plan.history, duration: plan.window.duration,
                rates: plan.rates, spend: spend, counts: counts, now: now)
        }
        return out
    }

    /// Every window of `account` as its latest poll left it: the fixed 5-hour
    /// and 7-day readings and the latest batch of per-model caps, each cap
    /// with the model it names. Empty when its newest reading is over
    /// `LiveMeter.maxReadingAge` old, which has no value to give.
    public func currentWindows(account: String, now: Date) -> [Window] {
        guard hasTables else { return [] }
        let fixed = [RateLimitWindowName.fiveHour, RateLimitWindowName.sevenDay]
            .compactMap { latestReading(account: account, window: $0) }
        guard let newest = fixed.map(\.reading.at).max(),
              now.timeIntervalSince(newest) <= LiveMeter.maxReadingAge else { return [] }
        let samples = (try? context.fetch(LimitScope.modelScopedLimits(account: account, limit: 64))) ?? []
        let scoped = samples.map(\.scopedWindowRow).latestBatch().map { row -> Window in
            // Newest first, so the first naming is the newest.
            let named = samples.filter { $0.identity == row.identity }
            return Window(
                key: row.identity, duration: WindowSpec.scopedDuration(group: row.group),
                reading: MeterReading(at: row.sampledAt, percent: row.percent, resetsAt: row.resetsAt),
                capModelId: named.lazy.compactMap { $0.modelId?.isEmpty == false ? $0.modelId : nil }.first,
                capModelName: named.lazy.compactMap {
                    $0.modelDisplayName?.isEmpty == false ? $0.modelDisplayName : nil
                }.first)
        }
        return fixed + scoped
    }

    /// Every live value `account` has at `now`, from its latest poll: what
    /// `LiveMeterBoard` holds in the app, and what a widget reads at its
    /// timeline refresh.
    public func currentValues(account: String, now: Date) -> [String: LiveMeterValue] {
        let windows = currentWindows(account: account, now: now)
        return windows.isEmpty ? [:] : values(account: account, windows: windows, now: now)
    }

    /// Whether one window's latest reading at or before `through` is a stale
    /// one (`LiveMeter.heldTick`): the tick it held at and the points the
    /// spend since implied. Nil without a strong fit or when it is believed.
    public func held(account: String, window key: String, through: Date) -> (tick: MeterReading, implied: Double)? {
        guard hasTables, let latest = latestReading(account: account, window: key, before: through.addingTimeInterval(0.001)),
              let rates = latestRates(account: account, window: key), rates.isStrong else { return nil }
        let history = Self.carryHistory(readings(account: account, window: key, through: latest.reading.at),
                                        ending: latest.reading)
        guard history.count >= 2, let first = history.first,
              let spend = spend(account: account, after: first.at, through: latest.reading.at) else { return nil }
        return LiveMeter.heldTick(
            readings: history, duration: latest.duration, rates: rates, spend: spend,
            counts: SpendMeterFitter.capCounts(modelId: latest.capModelId, displayName: latest.capModelName))
    }

    /// One window's value, reading its latest reading too: a fixed window
    /// from `RateLimitSample`, a scoped identity from `UsageLimitSample`.
    public func value(account: String, window key: String, now: Date) -> LiveMeterValue? {
        guard let window = latestReading(account: account, window: key) else { return nil }
        return values(account: account, windows: [window], now: now)[key]
    }

    // MARK: - Reads

    /// Whether the container has the two tables this reads. A reduced schema
    /// (a test's container of a few types) has no live value: fetching a type
    /// the schema lacks is not documented to throw rather than trap, so it is
    /// never asked.
    private var hasTables: Bool {
        let names = Set(context.container.schema.entities.map(\.name))
        return names.contains(Schema.entityName(for: SpendMeterFit.self))
            && names.contains(Schema.entityName(for: TokenSample.self))
    }

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

    /// `readings` cut to the carry's lookback and ending with `reading`,
    /// ascending: a caller's history may hold older rows, or not yet the
    /// reading itself.
    static func carryHistory(_ readings: [MeterReading], ending reading: MeterReading) -> [MeterReading] {
        let from = reading.at.addingTimeInterval(-LiveMeter.carryLookback)
        var out = readings.filter { $0.at >= from && $0.at < reading.at }.sorted { $0.at < $1.at }
        out.append(reading)
        return out
    }

    /// The most readings the history read returns, newest kept: a backstop.
    /// An account read every ~30 s across nine logins writes about 120 an
    /// hour per window, and past the cap the oldest are the ones the carry
    /// needs least.
    static let historyFetchLimit = 2_000

    /// One window's readings in the carry's lookback up to `through`,
    /// ascending.
    func readings(account: String, window key: String, through: Date) -> [MeterReading] {
        readings(account: account, window: key, from: through.addingTimeInterval(-LiveMeter.carryLookback),
                 through: through)
    }

    /// One window's readings in `[from, through]`, ascending, the newest
    /// `limit` of them.
    func readings(account: String, window key: String, from: Date, through: Date,
                  limit: Int = historyFetchLimit) -> [MeterReading] {
        if PaceMath.windowDuration(for: key) != nil {
            var d = FetchDescriptor<RateLimitSample>(
                predicate: #Predicate {
                    $0.accountId == account && $0.window == key && $0.sampledAt >= from && $0.sampledAt <= through
                },
                sortBy: [SortDescriptor(\.sampledAt, order: .reverse)])
            d.fetchLimit = limit
            return ((try? context.fetch(d)) ?? []).reversed()
                .map { MeterReading(at: $0.sampledAt, percent: $0.usedPercentage, resetsAt: $0.resetsAt) }
        }
        var d = FetchDescriptor<UsageLimitSample>(
            predicate: #Predicate {
                $0.accountId == account && $0.identity == key && $0.sampledAt >= from && $0.sampledAt <= through
            },
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)])
        d.fetchLimit = limit
        return ((try? context.fetch(d)) ?? []).reversed()
            .map { MeterReading(at: $0.sampledAt, percent: $0.percent, resetsAt: $0.resetsAt) }
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
