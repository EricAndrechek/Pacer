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
///
/// ## Tiers and variants (#297)
///
/// - **Prompt-size tiers** are sibling records with a threshold. A request's
///   prompt is all of its input — input, cache reads, and both cache writes,
///   as Anthropic defines it — and the WHOLE request is priced at the tier
///   its prompt falls in, cache hits included (Haiku 5.5 over 100k; the old
///   Sonnet 4/4.5 1M-context rate over 200k).
/// - **Fast mode** uses an explicit fast record when there is one, else the
///   standard rates times the record's fast multiplier (every category: the
///   cache multipliers stack on top). With neither, the request is "unpriced
///   premium": zero and flagged, never guessed at the standard rate.
/// - **Region and provider.** A Bedrock, Vertex or Foundry id, or a
///   first-party request with US data residency, is priced by its own
///   records when the catalogs list them, otherwise by the Claude API's
///   global records times the regional multiplier (×1 for a global
///   endpoint), flagged derived.
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
            return Plan(key: key, timeline: nil, keyTokens: none, regional: false)
        }
        // A provider or region the catalogs don't list for this model: the
        // Claude API's global price, with the regional premium when the
        // endpoint isn't global.
        let firstParty = plan(for: key.firstParty)
        guard let timeline = firstParty.timeline else {
            return Plan(key: key, timeline: nil, keyTokens: none + firstParty.keyTokens,
                        regional: false)
        }
        return Plan(key: key, timeline: timeline, keyTokens: none + firstParty.keyTokens,
                    regional: key.region != .global)
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
    /// `geo` is the request's data-residency region when the transcript says
    /// (`usage.inference_geo`); it overrides the region a plain id implies.
    public func cost(
        model: String, at t: Date, speed: PriceSpeed = .standard,
        geo: CanonicalModelID.Region? = nil, breakdown b: TokenBreakdown
    ) -> SampleCost {
        var plan = plan(for: model)
        if let geo, geo != plan.key.region, plan.key.provider == .anthropic {
            plan = self.plan(for: CanonicalModelID(model: plan.key.model, provider: .anthropic, region: geo))
        }
        guard let segment = plan.timeline?.segment(at: t), !segment.standard.isEmpty else {
            return SampleCost(components: .zero, pricedBy: plan.keyTokens, flags: .unpriced)
        }

        // Every tier and speed this request could have taken is a token: a
        // change to any of them can change what it costs.
        var tokens = plan.keyTokens.isEmpty ? segment.standardTokens
            : plan.keyTokens + segment.standardTokens
        if !segment.fastTokens.isEmpty { tokens += segment.fastTokens }

        let prompt = b.inputTokens + b.cacheReadTokens + b.cacheCreation5mTokens + b.cacheCreation1hTokens
        func tier(_ choices: [Choice]) -> Choice? {
            choices.first { $0.record.tierAbovePromptTokens == 0 || prompt > $0.record.tierAbovePromptTokens }
                ?? choices.last
        }

        var flags: PricingFlags = []
        var chosen: Choice
        var rates: PriceRates
        if speed == .fast, let explicit = tier(segment.fast) {
            chosen = explicit
            rates = explicit.record.rates
        } else {
            chosen = tier(segment.standard)!
            rates = chosen.record.rates
            if speed == .fast {
                guard let m = chosen.record.fastMultiplier else {
                    // No known fast rate: don't guess at the standard one.
                    return SampleCost(components: .zero, pricedBy: tokens,
                                      flags: chosen.outside ? [.unpricedPremium, .outsideWindow]
                                        : .unpricedPremium)
                }
                rates = rates.scaled(by: m, marking: .fast)
            }
        }
        if plan.regional {
            rates = rates.scaled(by: chosen.record.regionalMultiplier ?? 1, marking: .region)
        }
        if chosen.outside { flags.insert(.outsideWindow) }
        if !rates.derived.isEmpty { flags.insert(.derivedRate) }
        return SampleCost(components: CostComponents(breakdown: b, rates: rates),
                          pricedBy: tokens, flags: flags)
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

    /// The base record plus one sibling per prompt-size tier the row
    /// carries (above 100k, above 200k), with the row's fast and regional
    /// multipliers on each.
    static func templates(
        for id: CanonicalModelID, pricing p: LiteLLMModelPricing, source: PriceSource
    ) -> [PriceRecordValue] {
        let placeholder = Date(timeIntervalSince1970: 0)
        let fast = p.providerSpecificEntry?["fast"]
        let regional = p.providerSpecificEntry?["us"]

        /// Five rates from whatever the row publishes. Anthropic's cache
        /// writes are uniform multiples of input — 5m ×1.25, 1h ×2 — so an
        /// unpublished write rate is derived from them and flagged. (It used
        /// to reuse the 5m rate for 1h, under-pricing every 1h write on
        /// models.dev- and catwalk-sourced rows, which publish no 1h rate.)
        /// Cache reads are not uniform (×0.1, ×0.05 on Opus/Sonnet 5.5,
        /// ×0.025 on Fable 5.1), so an unpublished read stays unpublished.
        func rates(input: Double?, output: Double?, read: Double?, w5m: Double?, w1h: Double?) -> PriceRates {
            let i = input ?? 0
            var derived: PriceRates.Derived = []
            if w5m == nil { derived.insert(.cacheWrite5m) }
            if w1h == nil { derived.insert(.cacheWrite1h) }
            return PriceRates(input: i, output: output ?? 0, cacheRead: read ?? 0,
                              cacheWrite5m: w5m ?? i * 1.25, cacheWrite1h: w1h ?? i * 2,
                              derived: derived)
        }
        func record(_ tier: Int64, _ r: PriceRates) -> PriceRecordValue {
            PriceRecordValue(key: id, tierAbovePromptTokens: tier, rates: r,
                             fastMultiplier: fast, regionalMultiplier: regional,
                             effectiveFrom: placeholder, source: source)
        }

        var out = [record(0, rates(
            input: p.inputCostPerToken, output: p.outputCostPerToken,
            read: p.cacheReadInputTokenCost, w5m: p.cacheCreationInputTokenCost,
            w1h: p.cacheCreationInputTokenCostAbove1hr))]

        let tiers: [(Int64, Double?, Double?, Double?, Double?, Double?)] = [
            (100_000, p.inputCostPerTokenAbove100kTokens, p.outputCostPerTokenAbove100kTokens,
             p.cacheReadInputTokenCostAbove100kTokens, p.cacheCreationInputTokenCostAbove100kTokens, nil),
            (200_000, p.inputCostPerTokenAbove200kTokens, p.outputCostPerTokenAbove200kTokens,
             p.cacheReadInputTokenCostAbove200kTokens, p.cacheCreationInputTokenCostAbove200kTokens,
             p.cacheCreationInputTokenCostAbove1hrAbove200kTokens),
        ]
        let base = out[0].rates
        for (threshold, input, output, read, w5m, w1h) in tiers
        where [input, output, read, w5m].contains(where: { ($0 ?? 0) > 0 }) {
            // A tier row that omits a category keeps the base rate for it;
            // an omitted write rate is derived from the tier's own input.
            let tierInput = input ?? base.input
            out.append(record(threshold, rates(
                input: tierInput, output: output ?? base.output, read: read ?? base.cacheRead,
                w5m: w5m, w1h: w1h)))
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
