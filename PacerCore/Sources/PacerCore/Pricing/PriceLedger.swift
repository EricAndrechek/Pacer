import Foundation

/// Every dated price Pacer knows, as a Sendable value, and the rule that
/// picks the one that priced a given request (#296).
///
/// Built from `PriceRecord` rows by `PriceLedgerStore` and held by
/// `SampleCostCache`, so the recomputers and views price a sample with a
/// synchronous lookup: a dictionary hit on the canonical key, then a scan of
/// that key's handful of records.
///
/// ## Which record prices a request
///
/// 1. **Key.** The request's `CanonicalModelID` (model, provider, region). A
///    Claude API id with no records of its own may use the same model's
///    global-endpoint records on a partner cloud (`PricingCatalogIndex` makes
///    the same move, for the same reason).
/// 2. **At-time.** Among that key's records, those whose window contains the
///    request's timestamp. Past usage is never re-priced at today's rate.
/// 3. **Precedence.** A curated record beats a catalog one. The exception is
///    an *open-ended* curated record: a catalog record that opened after the
///    curated file was reviewed, with different numbers, is news the reviewer
///    didn't have, and wins from its start. Otherwise an open curated record
///    would freeze its model's price forever. Ties go to the later start.
/// 4. **Outside every window** (a sample older than the first record, or in a
///    gap), the nearest record prices it and the result is flagged
///    `outsideWindow`: a flagged estimate rather than a silent one.
/// 5. **No records at all**: unpriced. Cost zero, flagged `unpriced`.
public struct PriceLedger: Sendable {

    public let records: [PriceRecordValue]
    /// Each key's records, precomputed into time segments so pricing a
    /// sample is a dictionary hit plus a binary search — no allocation. A
    /// full rebuild prices every sample several times over (daily, hourly,
    /// project, session, and the per-account split of each).
    private let timelines: [CanonicalModelID: Timeline]
    /// Raw model string → its timeline, resolved once per string (the parse
    /// and any fallback included).
    private let plans: PlanCache
    /// True for the stand-in `SampleCostCache` builds before the store's
    /// ledger has been read: catalog records there carry no real history.
    public let isProvisional: Bool

    public init(records: [PriceRecordValue], isProvisional: Bool = false) {
        let sorted = records.sorted { $0.id < $1.id }
        self.records = sorted
        var byKey: [CanonicalModelID: [PriceRecordValue]] = [:]
        for r in sorted { byKey[r.key, default: []].append(r) }
        timelines = byKey.mapValues(Timeline.init)
        plans = PlanCache()
        self.isProvisional = isProvisional
    }

    public static let empty = PriceLedger(records: [])

    public var isEmpty: Bool { records.isEmpty }

    /// A key's records, ascending by start.
    public func records(for key: CanonicalModelID) -> [PriceRecordValue] {
        timelines[key]?.records ?? []
    }

    public var keys: Set<CanonicalModelID> { Set(timelines.keys) }

    /// Content equality, for deciding whether installing this ledger changes
    /// any price.
    public func samePrices(as other: PriceLedger) -> Bool { records == other.records }

    // MARK: - Timelines

    /// One record deciding one (speed, tier) over one segment.
    struct Choice: Sendable {
        let record: PriceRecordValue
        let outside: Bool
        /// `[id]`, or `["~" + id]` when it priced outside its window.
        let token: String
    }

    /// The tiers in effect over one stretch of time, highest threshold first,
    /// with their tokens prebuilt so pricing a sample allocates nothing.
    struct Segment: Sendable {
        let start: Date
        let standard: [Choice]
        let fast: [Choice]
        let standardTokens: [String]
        let fastTokens: [String]

        init(start: Date, standard: [Choice], fast: [Choice]) {
            self.start = start
            self.standard = standard
            self.fast = fast
            // Base tier first: it is the record that "priced" the bucket.
            standardTokens = standard.reversed().map(\.token)
            fastTokens = fast.reversed().map(\.token)
        }
    }

    /// A key's records cut at every start and end, so within a segment the
    /// deciding record of every (speed, tier) is constant.
    final class Timeline: Sendable {
        let records: [PriceRecordValue]
        let segments: [Segment]

        init(_ unsorted: [PriceRecordValue]) {
            let rs = unsorted.sorted {
                $0.effectiveFrom != $1.effectiveFrom ? $0.effectiveFrom < $1.effectiveFrom : $0.id < $1.id
            }
            records = rs
            var cuts = Set<Date>()
            for r in rs {
                cuts.insert(r.effectiveFrom)
                if let to = r.effectiveTo { cuts.insert(to) }
            }
            let boundaries = cuts.sorted()
            // A segment before the first boundary (prices there are
            // "outside window") unless the first record starts at the
            // beginning of time.
            var starts: [Date] = []
            if let first = boundaries.first, first > .distantPast { starts.append(.distantPast) }
            starts.append(contentsOf: boundaries)

            func choices(_ pool: [PriceRecordValue], at t: Date) -> [Choice] {
                var byTier: [Int64: [PriceRecordValue]] = [:]
                for r in pool { byTier[r.tierAbovePromptTokens, default: []].append(r) }
                return byTier.keys.sorted(by: >).map { tier in
                    let (winner, outside) = PriceLedger.pick(from: byTier[tier]!, at: t)
                    return Choice(record: winner, outside: outside,
                                  token: (outside ? "~" : "") + winner.id)
                }
            }
            let standardPool = rs.filter { $0.speed == .standard }
            let fastPool = rs.filter { $0.speed == .fast }
            segments = starts.enumerated().map { i, start in
                // A time inside the segment: its start, or just before the
                // first boundary for the leading open segment.
                let t = (i == 0 && start == .distantPast && boundaries.first != .distantPast)
                    ? boundaries.first!.addingTimeInterval(-1) : start
                return Segment(start: start,
                               standard: choices(standardPool, at: t),
                               fast: choices(fastPool, at: t))
            }
        }

        func segment(at t: Date) -> Segment? {
            guard !segments.isEmpty else { return nil }
            // Last segment whose start <= t.
            var lo = 0, hi = segments.count - 1
            if t < segments[0].start { return segments[0] }
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if segments[mid].start <= t { lo = mid } else { hi = mid - 1 }
            }
            return segments[lo]
        }
    }

    /// How one raw model string is priced: which timeline, and the tokens
    /// its own key contributes.
    struct Plan: Sendable {
        let key: CanonicalModelID
        /// nil: no records anywhere — unpriced.
        let timeline: Timeline?
        /// `[none:<key>]` when the key borrowed another key's records (so it
        /// rebuilds once it gains its own); empty otherwise.
        let keyTokens: [String]
        /// Apply the target's regional premium.
        let regional: Bool
    }

    final class PlanCache: @unchecked Sendable {
        private let lock = NSLock()
        private var plans: [String: Plan] = [:]
        func plan(_ model: String, _ make: () -> Plan) -> Plan {
            lock.lock()
            if let p = plans[model] { lock.unlock(); return p }
            lock.unlock()
            let p = make()
            lock.lock()
            plans[model] = p
            lock.unlock()
            return p
        }
    }

    func plan(for model: String) -> Plan {
        plans.plan(model) { plan(for: CanonicalModelID.parse(model)) }
    }

    func plan(for key: CanonicalModelID) -> Plan {
        if let own = timelines[key] {
            return Plan(key: key, timeline: own, keyTokens: [], regional: false)
        }
        let none = [Self.noneToken(key)]
        if key.provider == .anthropic, key.region == .global {
            // The same model on a partner cloud's global endpoint, which
            // Anthropic prices at the Claude API's rates.
            for provider in [CanonicalModelID.Provider.vertex, .foundry, .bedrock] {
                let alt = CanonicalModelID(model: key.model, provider: provider, region: .global)
                if let t = timelines[alt] {
                    return Plan(key: key, timeline: t, keyTokens: none, regional: false)
                }
            }
        }
        return Plan(key: key, timeline: nil, keyTokens: none, regional: false)
    }

    // MARK: - Resolution

    /// The token a request on `key` carries while that key has no records.
    public static func noneToken(_ key: CanonicalModelID) -> String {
        "none:\(key.model)|\(key.provider.rawValue)|\(key.region.rawValue)"
    }

    /// The deciding record among `candidates` (one key, one speed, one tier)
    /// at `t`, and whether `t` fell outside every window.
    static func pick(from candidates: [PriceRecordValue], at t: Date) -> (PriceRecordValue, Bool) {
        let active = candidates.filter { $0.covers(t) }
        if !active.isEmpty { return (precedence(active), false) }
        // Outside every window: the first record if `t` predates them all,
        // otherwise the latest one that started before `t`.
        let earliest = candidates.min {
            $0.effectiveFrom != $1.effectiveFrom ? $0.effectiveFrom < $1.effectiveFrom : $0.id < $1.id
        }!
        if t < earliest.effectiveFrom {
            let atStart = candidates.filter { $0.effectiveFrom == earliest.effectiveFrom }
            return (precedence(atStart), true)
        }
        let before = candidates.filter { $0.effectiveFrom <= t }
        let latestStart = before.map(\.effectiveFrom).max()!
        return (precedence(before.filter { $0.effectiveFrom == latestStart }), true)
    }

    /// Curated over catalog, with the review-date exception (see the type
    /// doc), then the later start, then the id.
    static func precedence(_ records: [PriceRecordValue]) -> PriceRecordValue {
        func latest(_ rs: [PriceRecordValue]) -> PriceRecordValue? {
            rs.max {
                $0.effectiveFrom != $1.effectiveFrom ? $0.effectiveFrom < $1.effectiveFrom : $0.id < $1.id
            }
        }
        let catalog = records.filter { !$0.curated }
        guard let curated = latest(records.filter(\.curated)) else { return latest(catalog)! }
        if curated.effectiveTo == nil, let reviewed = curated.reviewedAt,
           let news = latest(catalog.filter { $0.effectiveFrom > reviewed && !$0.samePrice(as: curated) }) {
            return news
        }
        return curated
    }

    // MARK: - Cost

    /// What one request costs at the price in effect at `t`.
    ///
    /// A model with an upper tier keeps the rule the flat table used: each
    /// category's tokens up to the threshold at the base rate, the rest at
    /// the upper tier's rate. #297 replaces it with Anthropic's per-request
    /// rule.
    public func cost(
        model: String, at t: Date, speed: PriceSpeed = .standard, breakdown: TokenBreakdown
    ) -> SampleCost {
        let plan = plan(for: model)
        guard let segment = plan.timeline?.segment(at: t),
              let base = segment.standard.last
        else {
            return SampleCost(components: .zero, pricedBy: plan.keyTokens, flags: .unpriced)
        }
        var flags: PricingFlags = base.outside ? .outsideWindow : []
        if !base.record.rates.derived.isEmpty { flags.insert(.derivedRate) }
        let tokens = plan.keyTokens.isEmpty
            ? segment.standardTokens : plan.keyTokens + segment.standardTokens
        let components: CostComponents
        if segment.standard.count > 1, let upper = segment.standard.first {
            let th = upper.record.tierAbovePromptTokens
            func split(_ tokens: Int64, _ base: Double, _ above: Double) -> Double {
                guard tokens > th, above > 0 else { return Double(tokens) * base }
                return Double(th) * base + Double(tokens - th) * above
            }
            let b = breakdown, lo = base.record.rates, hi = upper.record.rates
            components = CostComponents(
                input: split(b.inputTokens, lo.input, hi.input),
                output: split(b.outputTokens, lo.output, hi.output),
                cacheRead: split(b.cacheReadTokens, lo.cacheRead, hi.cacheRead),
                cacheWrite5m: split(b.cacheCreation5mTokens, lo.cacheWrite5m, hi.cacheWrite5m),
                cacheWrite1h: split(b.cacheCreation1hTokens, lo.cacheWrite1h, hi.cacheWrite1h))
        } else {
            components = CostComponents(breakdown: breakdown, rates: base.record.rates)
        }
        return SampleCost(components: components, pricedBy: tokens, flags: flags)
    }

    /// The base-tier standard rates for `model` at `t`, for display math
    /// (the cache-savings estimate) that needs a rate rather than a cost.
    public func rates(for model: String, at t: Date) -> PriceRates? {
        plan(for: model).timeline?.segment(at: t)?.standard.last?.record.rates
    }

    /// Whether `model` has any price at all.
    public func isPriced(_ model: String) -> Bool {
        plan(for: model).timeline?.segments.isEmpty == false
    }
}

// MARK: - From a catalog

extension PriceLedger {

    /// The rate vectors a merged catalog states for every model the ledger
    /// tracks, as windowless record templates (`effectiveFrom` is a
    /// placeholder; `PriceLedgerStore` dates them).
    ///
    /// Tracked: every `claude-*` model on a provider Pacer models, plus any
    /// other identity in `alsoInclude` (models the store has actually seen —
    /// Claude Code can be pointed at other backends). Everything else in a
    /// 3,500-entry catalog is irrelevant to a Claude Code user, and leaving
    /// it out keeps the ledger to a few hundred rows.
    ///
    /// The built-in Anthropic fallback table contributes a template only
    /// where the catalog has nothing for that key, matching its role in the
    /// flat lookup it replaces.
    public static func catalogTemplates(
        _ catalog: [String: LiteLLMModelPricing],
        alsoInclude: Set<CanonicalModelID> = []
    ) -> [PriceRecordValue] {
        var out: [PriceRecordValue] = []
        var seen = Set<CanonicalModelID>()
        func tracked(_ id: CanonicalModelID) -> Bool {
            alsoInclude.contains(id)
                || (id.provider != .other && id.model.hasPrefix("claude-"))
        }
        for (id, key) in PricingCatalogIndex(catalog).entries where tracked(id) {
            guard let p = catalog[key] else { continue }
            out.append(contentsOf: templates(for: id, pricing: p, source: p.pacerSource ?? .litellm))
            seen.insert(id)
        }
        for (id, key) in PricingCatalogIndex(AnthropicFallbackPricing.table).entries
        where !seen.contains(id) {
            guard let p = AnthropicFallbackPricing.table[key] else { continue }
            out.append(contentsOf: templates(for: id, pricing: p, source: .fallback))
        }
        return out.sorted { $0.id < $1.id }
    }

    /// Base record plus the above-200k sibling, when the row carries one.
    static func templates(
        for id: CanonicalModelID, pricing p: LiteLLMModelPricing, source: PriceSource
    ) -> [PriceRecordValue] {
        let placeholder = Date(timeIntervalSince1970: 0)
        let w5m = p.cacheCreationInputTokenCost ?? 0
        // An unpublished 1h rate reuses the 5m rate, as the flat table did.
        // (#297 derives it as 2x input instead.)
        let w1h = p.cacheCreationInputTokenCostAbove1hr ?? w5m
        var derived: PriceRates.Derived = []
        if p.cacheCreationInputTokenCostAbove1hr == nil { derived.insert(.cacheWrite1h) }
        let base = PriceRates(
            input: p.inputCostPerToken ?? 0, output: p.outputCostPerToken ?? 0,
            cacheRead: p.cacheReadInputTokenCost ?? 0,
            cacheWrite5m: w5m, cacheWrite1h: w1h, derived: derived)
        var out = [PriceRecordValue(key: id, rates: base, effectiveFrom: placeholder, source: source)]

        let anyAbove = [p.inputCostPerTokenAbove200kTokens, p.outputCostPerTokenAbove200kTokens,
                        p.cacheReadInputTokenCostAbove200kTokens,
                        p.cacheCreationInputTokenCostAbove200kTokens].contains { ($0 ?? 0) > 0 }
        if anyAbove {
            let a5m = p.cacheCreationInputTokenCostAbove200kTokens ?? base.cacheWrite5m
            let upper = PriceRates(
                input: p.inputCostPerTokenAbove200kTokens ?? base.input,
                output: p.outputCostPerTokenAbove200kTokens ?? base.output,
                cacheRead: p.cacheReadInputTokenCostAbove200kTokens ?? base.cacheRead,
                cacheWrite5m: a5m,
                cacheWrite1h: p.cacheCreationInputTokenCostAbove1hrAbove200kTokens ?? a5m)
            out.append(PriceRecordValue(
                key: id, tierAbovePromptTokens: 200_000, rates: upper,
                effectiveFrom: placeholder, source: source))
        }
        return out
    }

    /// The stand-in ledger `SampleCostCache` uses before the store's has been
    /// read: curated history plus the catalog's current rates, open from the
    /// beginning of time. Only views can see it, briefly at launch — the scan
    /// installs the store's ledger before any rollup is recomputed — and
    /// tests that never run a scan price against it.
    public static func provisional(
        catalog: [String: LiteLLMModelPricing], curated: [PriceRecordValue]
    ) -> PriceLedger {
        let open = catalogTemplates(catalog).map { t -> PriceRecordValue in
            var r = t
            r.effectiveFrom = .distantPast
            r.id = PriceRecordValue.makeId(
                curated: false, key: r.key, speed: r.speed,
                tier: r.tierAbovePromptTokens, from: .distantPast)
            return r
        }
        return PriceLedger(records: curated + open, isProvisional: true)
    }
}
