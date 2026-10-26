import Foundation
import SwiftData

/// An account's history in the arena's terms, built from the store: what the
/// arena's exporter writes (`research/arena/export/readings.py`), cut down the
/// way its port fixtures are (`arena/cli_portfix.py`: `thin`, `spend_turns`).
///
/// - **Meters.** `RateLimitSample` five-hour and seven-day readings and
///   `UsageLimitSample` weekly per-model caps, unioned with
///   `AccountUsageArchive` (the live tables are a 35-day cache; older rows
///   move there), one row per (meter, instant) with the live copy winning,
///   as the exporter dedups. A null reset is an idle row. `tKnown = tEvent =
///   sampledAt`: the app knows a row when it writes it (port spec, "Mapping
///   to Pacer's data"). Each meter is thinned: a row is kept when its value,
///   state or cycle changes, at least hourly, and the first and last. The
///   rule only looks back, so a cut of a thinned series is the thinned cut:
///   no leak.
/// - **Spend.** `TokenSample`s priced at the rate in effect at `sampledAt`
///   (`PriceLedger`, the way the live meter prices), attributed by
///   `accountId`, `<synthetic>` skipped (correctness rule 2), summed into
///   one row per model family per five minutes with `turns` and `tokens`.
///   A bucket of only unpriced turns has a nil cost, never 0 (the cost
///   silent-zero class).
///
/// Bounded: `depthDays` of history (120, the deepest any port reads: the
/// analog model), limit reads through raw SQLite where the store has a file
/// (`RawLimitReader`, as the engine does) and SwiftData otherwise, and turns
/// paged through fresh contexts (`ModelWalk`), never `enumerate`.
public enum ArenaHistoryBuilder {

    public static let depthDays = 120
    /// `KEEPALIVE_MIN` in `cli_portfix.py`.
    public static let keepaliveMillis: Millis = 60 * ArenaTime.minute
    /// A reset this far from the previous row's is a new cycle (`thin`).
    public static let cycleChangeMillis: Millis = 30 * ArenaTime.minute
    /// `SPEND_BUCKET_MS`.
    public static let spendBucketMillis: Millis = 5 * ArenaTime.minute

    // MARK: - Naming

    /// The arena's `scope_model` for a scoped reading
    /// (`export/readings.py::_scope_model`): the display name when there is
    /// one, else the model named in a `weekly_scoped|<model>|…` identity.
    public static func scopeModel(identity: String?, display: String?) -> String? {
        if let display, !display.isEmpty { return display }
        if let identity {
            let parts = identity.split(separator: "|", omittingEmptySubsequences: false)
            if parts.count >= 2, parts[0] == "weekly_scoped", !parts[1].isEmpty { return String(parts[1]) }
        }
        return nil
    }

    /// The arena's model family (`export/util.py::model_family`): the first
    /// of fable, opus, sonnet, haiku the lowercased id contains, else other.
    public static func family(_ model: String?) -> String {
        guard let model, !model.isEmpty else { return "other" }
        let m = model.lowercased()
        for f in arenaFamilies.dropLast() where m.contains(f) { return f }
        return "other"
    }

    // MARK: - Thinning

    /// `cli_portfix.thin` over one meter's readings in event order: keep the
    /// first and last, every change of value, state or cycle (a reset 30 min
    /// or more from the previous row's), and at least one every hour.
    public static func thin(_ rows: [ArenaReading]) -> [ArenaReading] {
        guard rows.count > 2 else { return rows }
        var out = [rows[0]]
        out.reserveCapacity(rows.count / 4 + 2)
        thinTail(rows.dropFirst(), previous: rows[0], into: &out)
        return out
    }

    /// The thinning loop over `rows`, continuing after `previous` (the raw row
    /// before them, which is also the last one kept). Always keeps the last.
    static func thinTail(_ rows: ArraySlice<ArenaReading>, previous: ArenaReading, into out: inout [ArenaReading]) {
        var prev = previous
        var lastKept = previous.tEvent
        let lastIndex = rows.indices.last
        for i in rows.indices {
            let r = rows[i]
            // Unknown values and resets compare as -1, as the Python's
            // `fill_null(-1)`: a reset appearing or vanishing is a change.
            let changed = (r.utilPct ?? -1) != (prev.utilPct ?? -1)
                || r.active != prev.active
                || abs((r.resetsAt ?? -1) - (prev.resetsAt ?? -1)) >= cycleChangeMillis
                || r.tEvent - lastKept >= keepaliveMillis
            if changed || i == lastIndex {
                out.append(r)
                lastKept = r.tEvent
            }
            prev = r
        }
    }

    // MARK: - Meters

    /// Raw limit rows as the engine reads them, live and archived merged.
    public struct LimitRows: Sendable {
        var rate: [EngineFeatures.RateRow]
        var scoped: [EngineFeatures.ScopedRow]
        public var count: Int { rate.count + scoped.count }
    }

    /// The meters these rows describe, thinned. Only the windows the arena
    /// forecasts: five-hour, seven-day and weekly per-model caps (the
    /// account-wide `session` / `weekly_all` twins repeat the first two).
    static func meters(account: String, rows: LimitRows) -> [ArenaMeterID: [ArenaReading]] {
        rawMeters(account: account, rows: rows).mapValues { thin(dedupedInOrder($0)) }
    }

    /// Event order, one row per instant (the first, which `merged` made the
    /// live copy).
    static func dedupedInOrder(_ rows: [ArenaReading]) -> [ArenaReading] {
        var seen = Set<Millis>()
        return rows.filter { seen.insert($0.tEvent).inserted }.sorted { $0.tEvent < $1.tEvent }
    }

    /// One account's limit rows at or after `since`: the live tables and the
    /// archive, merged as the engine's record pass merges them (live wins).
    public static func readLimits(container: ModelContainer, account: String, since: Date) -> LimitRows {
        let context = ModelContext(container)
        let url = storeURL(container)
        let liveRate: [EngineFeatures.RateRow]
        let liveScoped: [EngineFeatures.ScopedRow]
        if let url, let r = RawLimitReader.rateRows(storeURL: url, account: account, since: since),
           let s = RawLimitReader.scopedRows(storeURL: url, account: account, since: since) {
            liveRate = r; liveScoped = s
        } else {
            var rd = FetchDescriptor<RateLimitSample>(predicate: LimitScope.rateLimitPredicate(account: account, since: since))
            rd.sortBy = [SortDescriptor(\.sampledAt)]
            liveRate = ((try? context.fetch(rd)) ?? []).map {
                .init(window: $0.window, at: $0.sampledAt, usedPercentage: $0.usedPercentage, resetsAt: $0.resetsAt)
            }
            var sd = FetchDescriptor<UsageLimitSample>(predicate: LimitScope.usageLimitPredicate(account: account, since: since))
            sd.sortBy = [SortDescriptor(\.sampledAt)]
            liveScoped = ((try? context.fetch(sd)) ?? []).map {
                .init(identity: $0.identity, group: $0.group, label: $0.label, modelId: $0.modelId,
                      modelDisplayName: $0.modelDisplayName, surface: $0.surface, at: $0.sampledAt,
                      usedPercentage: $0.percent, resetsAt: $0.resetsAt, inLatestBatch: false, isActive: $0.isActive)
            }
        }
        // The latest poll's scoped rows, as the engine stamps them: only
        // identities still reported get a window (`EngineFeatures.scopedWindows`).
        var stamped = liveScoped
        if let newest = liveScoped.map(\.at).max() {
            let cutoff = newest.addingTimeInterval(-2)
            stamped = liveScoped.map { r in
                .init(identity: r.identity, group: r.group, label: r.label, modelId: r.modelId,
                      modelDisplayName: r.modelDisplayName, surface: r.surface, at: r.at,
                      usedPercentage: r.usedPercentage, resetsAt: r.resetsAt, inLatestBatch: r.at >= cutoff,
                      isActive: r.isActive)
            }
        }
        let archived = readArchive(context: context, url: url, account: account)
        let rate = UsageIntelligenceEngine.merged(liveRate, archived.rate.filter { $0.at >= since },
                                                  key: { "\($0.window)|\($0.at.timeIntervalSince1970)" }, at: \.at)
        let scoped = UsageIntelligenceEngine.merged(stamped, archived.scoped.filter { $0.at >= since },
                                                    key: { "\($0.identity)|\($0.at.timeIntervalSince1970)" }, at: \.at)
        return LimitRows(rate: rate, scoped: scoped)
    }

    private static func readArchive(context: ModelContext, url: URL?, account: String)
        -> (rate: [EngineFeatures.RateRow], scoped: [EngineFeatures.ScopedRow]) {
        if let url, let rate = RawLimitReader.archivedRateRows(storeURL: url, account: account),
           let scoped = RawLimitReader.archivedScopedRows(storeURL: url, account: account) {
            return (rate, scoped)
        }
        let rateKind = AccountUsageArchive.kindRateLimit, scopedKind = AccountUsageArchive.kindUsageLimit
        let rows = (try? context.fetch(FetchDescriptor<AccountUsageArchive>(
            predicate: #Predicate { $0.accountId == account && ($0.kind == rateKind || $0.kind == scopedKind) },
            sortBy: [SortDescriptor(\.sampledAt)]))) ?? []
        return UsageIntelligenceEngine.archivedLimits(rows)
    }

    /// The file a container's store lives in; nil for an in-memory one, which
    /// reads through SwiftData instead (`UsageIntelligenceEngine.rawStoreURL`).
    static func storeURL(_ container: ModelContainer) -> URL? {
        guard let config = container.configurations.first, !config.isStoredInMemoryOnly else { return nil }
        return config.url
    }

    // MARK: - Spend

    /// One priced turn, before bucketing.
    public struct Turn: Sendable {
        public var at: Millis
        public var family: String
        public var costUSD: Double?
        public var tokens: Int
        public init(at: Millis, family: String, costUSD: Double?, tokens: Int) {
            self.at = at; self.family = family; self.costUSD = costUSD; self.tokens = tokens
        }
    }

    /// `cli_portfix.spend_turns`: one row per family per five-minute bucket,
    /// at the bucket's last turn, its cost the sum of its priced turns (nil
    /// when none was priced), with how many turns and tokens it summed.
    public static func spendRows(_ turns: [Turn]) -> [ArenaSpendRow] {
        struct Acc { var last: Millis; var cost: Double?; var turns: Int; var tokens: Int }
        var buckets: [Int: [String: Acc]] = [:]
        for t in turns {
            let b = Int(floorDiv(t.at, spendBucketMillis))
            var acc = buckets[b]?[t.family] ?? Acc(last: t.at, cost: nil, turns: 0, tokens: 0)
            acc.last = max(acc.last, t.at)
            if let c = t.costUSD { acc.cost = (acc.cost ?? 0) + c }
            acc.turns += 1
            acc.tokens += t.tokens
            buckets[b, default: [:]][t.family] = acc
        }
        var out: [ArenaSpendRow] = []
        out.reserveCapacity(buckets.count)
        for (_, fams) in buckets {
            for (fam, a) in fams {
                out.append(ArenaSpendRow(tEvent: a.last, tKnown: a.last, family: fam, costUSD: a.cost,
                                         turns: a.turns, tokens: a.tokens))
            }
        }
        // `_te`, then family, as the Python sorts the buckets.
        return out.sorted { ($0.tEvent, $0.family) < ($1.tEvent, $1.family) }
    }

    static func floorDiv(_ a: Millis, _ b: Millis) -> Millis {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    /// The account's turns in `(after, through]`, priced and bucketed.
    static func readSpend(container: ModelContainer, account: String, after: Date, through: Date,
                          pricing: PricingTable.Snapshot, mode: CostMode) -> [ArenaSpendRow] {
        var d = FetchDescriptor<TokenSample>(
            predicate: #Predicate { $0.accountId == account && $0.sampledAt > after && $0.sampledAt <= through },
            sortBy: [SortDescriptor(\.sampledAt)])
        d.propertiesToFetch = [\.sampledAt, \.model, \.inputTokens, \.outputTokens, \.cacheReadTokens,
                               \.cacheCreation5mTokens, \.cacheCreation1hTokens, \.sourceCostUSD,
                               \.speed, \.inferenceGeo]
        var turns: [Turn] = []
        try? ModelWalk.forEach(d, in: container) { s in
            guard s.model != "<synthetic>" else { return }
            turns.append(Turn(at: ArenaTime.millis(s.sampledAt), family: family(s.model),
                              costUSD: cost(s, pricing: pricing, mode: mode),
                              tokens: Int(s.inputTokens + s.outputTokens + s.cacheReadTokens
                                          + s.cacheCreation5mTokens + s.cacheCreation1hTokens)))
        }
        return spendRows(turns)
    }

    /// One turn's cost, or nil when nothing prices it. `.display` reads as
    /// `.auto` here: display mode zeroes a turn with no stored cost, and a
    /// model fed that zero would learn the account spent nothing.
    static func cost(_ s: TokenSample, pricing: PricingTable.Snapshot, mode: CostMode) -> Double? {
        let m: CostMode = mode == .display ? .auto : mode
        let c = CostCalculator.sampleCost(s, mode: m, snapshot: pricing)
        if s.sourceCostUSD == nil || m == .calculate,
           c.flags.contains(.unpriced) || c.flags.contains(.unpricedPremium) {
            return nil
        }
        return c.total
    }

    /// The store's ledger, as the live meter resolves it: the one the scan
    /// installed in this process, else read from the store; never the
    /// provisional stand-in.
    static func pricing(container: ModelContainer) -> PricingTable.Snapshot {
        if SampleCostCache.hasLedgerFromStore { return SampleCostCache.current() }
        let ledger = (try? PriceLedgerStore.load(context: ModelContext(container))) ?? .empty
        return PricingTable.Snapshot(pricingByModel: SampleCostCache.current().pricingByModel, ledger: ledger)
    }

    // MARK: - Building

    /// Everything the arena needs about one account up to `builtThrough`.
    public struct Built: Sendable {
        public let store: ArenaHistoryStore
        public let builtThrough: Date
        let meters: [ArenaMeterID: [ArenaReading]]
        let spend: [ArenaSpendRow]
    }

    /// `account`'s history from `now - depthDays` to `now`.
    public static func build(container: ModelContainer, account: String, now: Date,
                             depthDays: Int = depthDays, mode: CostMode? = nil,
                             pricing: PricingTable.Snapshot? = nil) -> Built {
        let since = now.addingTimeInterval(-Double(depthDays) * 86400)
        return build(container: container, account: account, now: now,
                     limits: readLimits(container: container, account: account, since: since),
                     depthDays: depthDays, mode: mode, pricing: pricing)
    }

    /// The same, from limit rows the caller already read (the scorer reads
    /// them once for both the history and the cycles it scores).
    public static func build(container: ModelContainer, account: String, now: Date, limits: LimitRows,
                             depthDays: Int = depthDays, mode: CostMode? = nil,
                             pricing: PricingTable.Snapshot? = nil) -> Built {
        let since = now.addingTimeInterval(-Double(depthDays) * 86400)
        let sinceMs = ArenaTime.millis(since)
        let meters = meters(account: account, rows: limits).mapValues { $0.filter { $0.tEvent >= sinceMs } }
        let spend = readSpend(container: container, account: account, after: since, through: now,
                              pricing: pricing ?? Self.pricing(container: container),
                              mode: mode ?? PacerPreferences.costMode())
        let store = makeStore(account: account, meters: meters, spend: spend, now: now, since: since)
        return Built(store: store, builtThrough: now, meters: meters, spend: spend)
    }

    static func makeStore(account: String, meters: [ArenaMeterID: [ArenaReading]], spend: [ArenaSpendRow],
                          now: Date, since: Date) -> ArenaHistoryStore {
        ArenaHistoryStore(meters: meters, spend: spend.isEmpty ? [:] : [account: spend],
                          tzOffsetMin: TimeZone.current.secondsFromGMT(for: now) / 60,
                          dataStart: ArenaTime.millis(since))
    }

    /// `built` moved on to `now`: new live rows appended (thinned on from the
    /// last kept row), the open spend bucket and everything after it re-read,
    /// and rows older than the depth dropped. Rows that arrive late with an
    /// old timestamp are not seen until the next full build.
    public static func extend(_ built: Built, container: ModelContainer, account: String, now: Date,
                              depthDays: Int = depthDays, mode: CostMode? = nil,
                              pricing: PricingTable.Snapshot? = nil) -> Built {
        guard now > built.builtThrough else { return built }
        let since = now.addingTimeInterval(-Double(depthDays) * 86400)
        let sinceMs = ArenaTime.millis(since)
        // Live rows from a little before the last build, so a row written in
        // the same second as the build is not missed; duplicates drop below.
        let fresh = readLiveLimits(container: container, account: account,
                                   since: built.builtThrough.addingTimeInterval(-120))
        let freshMeters = rawMeters(account: account, rows: fresh)
        var meters = built.meters
        for (id, rows) in freshMeters {
            let old = meters[id] ?? []
            let lastT = old.last?.tEvent ?? .min
            let newer = dedupedInOrder(rows).filter { $0.tEvent > lastT }
            guard !newer.isEmpty else { continue }
            var out = old
            if let prev = old.last {
                thinTail(newer[...], previous: prev, into: &out)
            } else {
                out = thin(newer)
            }
            meters[id] = out
        }
        meters = meters.mapValues { rows in rows.filter { $0.tEvent >= sinceMs } }

        let openBucket = floorDiv(ArenaTime.millis(built.builtThrough), spendBucketMillis) * spendBucketMillis
        let kept = built.spend.filter { $0.tEvent < openBucket && $0.tEvent >= sinceMs }
        let reread = readSpend(container: container, account: account,
                               after: ArenaTime.date(openBucket - 1), through: now,
                               pricing: pricing ?? Self.pricing(container: container),
                               mode: mode ?? PacerPreferences.costMode())
        let spend = kept + reread
        return Built(store: makeStore(account: account, meters: meters, spend: spend, now: now, since: since),
                     builtThrough: now, meters: meters, spend: spend)
    }

    /// The live tables only (new rows never land in the archive).
    static func readLiveLimits(container: ModelContainer, account: String, since: Date) -> LimitRows {
        if let url = storeURL(container),
           let r = RawLimitReader.rateRows(storeURL: url, account: account, since: since),
           let s = RawLimitReader.scopedRows(storeURL: url, account: account, since: since) {
            return LimitRows(rate: r, scoped: s)
        }
        let context = ModelContext(container)
        var rd = FetchDescriptor<RateLimitSample>(predicate: LimitScope.rateLimitPredicate(account: account, since: since))
        rd.sortBy = [SortDescriptor(\.sampledAt)]
        var sd = FetchDescriptor<UsageLimitSample>(predicate: LimitScope.usageLimitPredicate(account: account, since: since))
        sd.sortBy = [SortDescriptor(\.sampledAt)]
        return LimitRows(
            rate: ((try? context.fetch(rd)) ?? []).map {
                .init(window: $0.window, at: $0.sampledAt, usedPercentage: $0.usedPercentage, resetsAt: $0.resetsAt)
            },
            scoped: ((try? context.fetch(sd)) ?? []).map {
                .init(identity: $0.identity, group: $0.group, label: $0.label, modelId: $0.modelId,
                      modelDisplayName: $0.modelDisplayName, surface: $0.surface, at: $0.sampledAt,
                      usedPercentage: $0.percent, resetsAt: $0.resetsAt, inLatestBatch: false, isActive: $0.isActive)
            })
    }

    /// `meters` without the thinning, for appending.
    static func rawMeters(account: String, rows: LimitRows) -> [ArenaMeterID: [ArenaReading]] {
        var raw: [ArenaMeterID: [ArenaReading]] = [:]
        for r in rows.rate where r.window == "five_hour" || r.window == "seven_day" {
            let t = ArenaTime.millis(r.at)
            raw[ArenaMeterID(account: account, windowKind: r.window), default: []].append(
                ArenaReading(tEvent: t, tKnown: t, utilPct: r.usedPercentage,
                             resetsAt: r.resetsAt.map(ArenaTime.millis), active: r.resetsAt != nil))
        }
        for r in rows.scoped where r.identity.hasPrefix("weekly_scoped|") {
            guard let cap = scopeModel(identity: r.identity, display: r.modelDisplayName) else { continue }
            let t = ArenaTime.millis(r.at)
            raw[ArenaMeterID(account: account, windowKind: "weekly_scoped", scopeModel: cap), default: []].append(
                ArenaReading(tEvent: t, tKnown: t, utilPct: r.usedPercentage,
                             resetsAt: r.resetsAt.map(ArenaTime.millis), active: r.resetsAt != nil))
        }
        return raw
    }
}

/// Each account's arena history, kept between uses and moved on rather than
/// rebuilt: a full build reads 120 days of limits and turns, an extension only
/// what arrived since. Rebuilt in full every `fullRebuildInterval` to pick up
/// rows that arrive late with old timestamps (a transcript scanned after the
/// fact).
public actor ArenaHistoryCache {
    public static let fullRebuildInterval: TimeInterval = 6 * 3600
    /// An extension younger than this is reused as is.
    public static let reuseInterval: TimeInterval = 30

    private let container: ModelContainer
    private var entries: [String: (built: ArenaHistoryBuilder.Built, fullAt: Date)] = [:]

    public init(container: ModelContainer) { self.container = container }

    /// `account`'s history known at `now`.
    public func built(account: String, now: Date = Date()) -> ArenaHistoryBuilder.Built {
        if let e = entries[account], now.timeIntervalSince(e.fullAt) < Self.fullRebuildInterval {
            if now.timeIntervalSince(e.built.builtThrough) < Self.reuseInterval { return e.built }
            let next = ArenaHistoryBuilder.extend(e.built, container: container, account: account, now: now)
            entries[account] = (next, e.fullAt)
            return next
        }
        let fresh = ArenaHistoryBuilder.build(container: container, account: account, now: now)
        entries[account] = (fresh, now)
        MemoryHygiene.relieve(minimumInterval: MemoryHygiene.recurringReliefInterval)
        return fresh
    }

    public func store(account: String, now: Date = Date()) -> ArenaHistoryStore {
        built(account: account, now: now).store
    }

    /// Hand the cache a history built elsewhere (the scorer's full read).
    public func install(_ built: ArenaHistoryBuilder.Built, account: String) {
        entries[account] = (built, built.builtThrough)
    }

    public func forget(account: String) { entries[account] = nil }
}
