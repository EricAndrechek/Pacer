import Foundation
import SwiftData

/// One dated price: the rates a model cost on one provider, region, speed and
/// prompt-size tier, over one window of time. The pricing source of truth
/// (#296).
///
/// **Why dated.** Pacer used to keep one current rate vector per model and
/// overwrite it on every catalog refresh, so a price change silently re-priced
/// nothing (old buckets kept the old rate) or everything (a version bump
/// re-priced the past at today's rate). Prices do change — introductory
/// rates, cancelled rises, provider premiums — and the owner's rule is that a
/// request is priced at the rate **in effect when it was made**. So each rate
/// vector carries the window it was in effect for, and a sample is priced by
/// the record whose window contains its timestamp (`PriceLedger`).
///
/// **Where rows come from.**
/// - `curated`: the bundled `price-history.json`, refreshed from gh-pages —
///   reviewed history the catalogs can't hold (Sonnet 5's introductory
///   window, Sonnet 5.5's cache-read rate from launch). Never overwritten by
///   a catalog refresh.
/// - a catalog (`litellm`, `models.dev`, `catwalk`) or the built-in
///   `fallback` table: one open record per rate vector, opened at first
///   sighting and closed when a refresh reports different rates.
///
/// A few hundred rows. The recompute and view paths never fetch these: they
/// read the Sendable `PriceLedger` that `SampleCostCache` holds, so pricing a
/// sample stays a synchronous binary search.
@Model
public final class PriceRecord {
    #Index<PriceRecord>([\.recordId], [\.model])

    /// See `PriceRecordValue.makeId`. Stable across launches, which is what
    /// lets a rollup remember which records priced it.
    @Attribute(.unique) public var recordId: String

    /// `CanonicalModelID.model`.
    public var model: String
    /// `CanonicalModelID.Provider` raw value.
    public var provider: String
    /// `CanonicalModelID.Region` raw value.
    public var region: String
    /// `PriceSpeed` raw value.
    public var speed: String
    /// The record applies to a request whose prompt (input + cache reads +
    /// cache writes) is ABOVE this many tokens. 0 is the base tier; a higher
    /// tier is a sibling record with its own rates (#297).
    public var tierAbovePromptTokens: Int64

    // USD per token.
    public var inputPerToken: Double
    public var outputPerToken: Double
    public var cacheReadPerToken: Double
    public var cacheWrite5mPerToken: Double
    public var cacheWrite1hPerToken: Double
    /// `PriceRates.Derived` raw value: which of the rates above were
    /// derived rather than published.
    public var derivedMask: Int

    /// Fast mode's multiplier over these rates, when one is known.
    public var fastMultiplier: Double?
    /// The premium a regional endpoint or US data residency adds over these
    /// (global) rates, when one is known.
    public var regionalMultiplier: Double?

    public var effectiveFrom: Date
    /// Exclusive. nil = still in effect.
    public var effectiveTo: Date?

    /// `PriceSource` raw value.
    public var source: String
    public var curated: Bool
    /// For a curated record: the date its file was reviewed. A catalog
    /// change observed after it is information the reviewer didn't have, so
    /// it can override an open curated window — see `PriceLedger`.
    public var reviewedAt: Date?
    public var note: String?
    public var sourceURL: String?
    /// When Pacer wrote this row.
    public var recordedAt: Date

    public init(_ value: PriceRecordValue, recordedAt: Date = Date()) {
        recordId = value.id
        model = value.key.model
        provider = value.key.provider.rawValue
        region = value.key.region.rawValue
        speed = value.speed.rawValue
        tierAbovePromptTokens = value.tierAbovePromptTokens
        inputPerToken = value.rates.input
        outputPerToken = value.rates.output
        cacheReadPerToken = value.rates.cacheRead
        cacheWrite5mPerToken = value.rates.cacheWrite5m
        cacheWrite1hPerToken = value.rates.cacheWrite1h
        derivedMask = value.rates.derived.rawValue
        fastMultiplier = value.fastMultiplier
        regionalMultiplier = value.regionalMultiplier
        effectiveFrom = value.effectiveFrom
        effectiveTo = value.effectiveTo
        source = value.source.rawValue
        curated = value.source == .curated
        reviewedAt = value.reviewedAt
        note = value.note
        sourceURL = value.sourceURL
        self.recordedAt = recordedAt
    }

    /// Overwrite every field from `value` (same id).
    public func update(from value: PriceRecordValue) {
        inputPerToken = value.rates.input
        outputPerToken = value.rates.output
        cacheReadPerToken = value.rates.cacheRead
        cacheWrite5mPerToken = value.rates.cacheWrite5m
        cacheWrite1hPerToken = value.rates.cacheWrite1h
        derivedMask = value.rates.derived.rawValue
        fastMultiplier = value.fastMultiplier
        regionalMultiplier = value.regionalMultiplier
        effectiveFrom = value.effectiveFrom
        effectiveTo = value.effectiveTo
        source = value.source.rawValue
        curated = value.source == .curated
        reviewedAt = value.reviewedAt
        note = value.note
        sourceURL = value.sourceURL
    }

    public var value: PriceRecordValue {
        PriceRecordValue(
            id: recordId,
            key: CanonicalModelID(
                model: model,
                provider: CanonicalModelID.Provider(rawValue: provider) ?? .other,
                region: CanonicalModelID.Region(rawValue: region) ?? .global),
            speed: PriceSpeed(rawValue: speed) ?? .standard,
            tierAbovePromptTokens: tierAbovePromptTokens,
            rates: PriceRates(
                input: inputPerToken, output: outputPerToken, cacheRead: cacheReadPerToken,
                cacheWrite5m: cacheWrite5mPerToken, cacheWrite1h: cacheWrite1hPerToken,
                derived: PriceRates.Derived(rawValue: derivedMask)),
            fastMultiplier: fastMultiplier,
            regionalMultiplier: regionalMultiplier,
            effectiveFrom: effectiveFrom,
            effectiveTo: effectiveTo,
            source: PriceSource(rawValue: source) ?? .litellm,
            reviewedAt: reviewedAt,
            note: note,
            sourceURL: sourceURL)
    }
}

public enum PriceSpeed: String, Sendable, Codable, CaseIterable {
    case standard, fast

    /// Claude Code's `usage.speed`. Anything but `"fast"` is standard.
    public init(usageSpeed: String?) {
        self = usageSpeed?.lowercased() == "fast" ? .fast : .standard
    }
}

public enum PriceSource: String, Sendable, Codable, CaseIterable {
    case curated
    case litellm
    case modelsDev = "models.dev"
    case catwalk
    case fallback
}

/// `PriceRecord` as a Sendable value: what the ledger, the sync and the tests
/// work with.
public struct PriceRecordValue: Sendable, Hashable, Codable {
    public var id: String
    public var key: CanonicalModelID
    public var speed: PriceSpeed
    public var tierAbovePromptTokens: Int64
    public var rates: PriceRates
    public var fastMultiplier: Double?
    public var regionalMultiplier: Double?
    public var effectiveFrom: Date
    public var effectiveTo: Date?
    public var source: PriceSource
    public var reviewedAt: Date?
    public var note: String?
    public var sourceURL: String?

    public init(
        id: String? = nil,
        key: CanonicalModelID,
        speed: PriceSpeed = .standard,
        tierAbovePromptTokens: Int64 = 0,
        rates: PriceRates,
        fastMultiplier: Double? = nil,
        regionalMultiplier: Double? = nil,
        effectiveFrom: Date,
        effectiveTo: Date? = nil,
        source: PriceSource,
        reviewedAt: Date? = nil,
        note: String? = nil,
        sourceURL: String? = nil
    ) {
        self.key = key
        self.speed = speed
        self.tierAbovePromptTokens = tierAbovePromptTokens
        self.rates = rates
        self.fastMultiplier = fastMultiplier
        self.regionalMultiplier = regionalMultiplier
        self.effectiveFrom = effectiveFrom
        self.effectiveTo = effectiveTo
        self.source = source
        self.reviewedAt = reviewedAt
        self.note = note
        self.sourceURL = sourceURL
        self.id = id ?? Self.makeId(
            curated: source == .curated, key: key, speed: speed,
            tier: tierAbovePromptTokens, from: effectiveFrom)
    }

    public var curated: Bool { source == .curated }

    /// `curated|claude-sonnet-5|anthropic|global|standard|0|1782864000`, or
    /// `catalog|…` for a catalog record. The key is recoverable from the id
    /// (`PriceLedger.key(ofToken:)`), which is what lets a rollup's
    /// `pricedByRecordIds` name the key it depends on without a join.
    public static func makeId(
        curated: Bool, key: CanonicalModelID, speed: PriceSpeed, tier: Int64, from: Date
    ) -> String {
        [curated ? "curated" : "catalog", key.model, key.provider.rawValue,
         key.region.rawValue, speed.rawValue, String(tier),
         String(Int64(from.timeIntervalSince1970.rounded()))].joined(separator: "|")
    }

    public func covers(_ t: Date) -> Bool {
        t >= effectiveFrom && (effectiveTo.map { t < $0 } ?? true)
    }

    /// Same price, ignoring provenance and window: what a catalog refresh
    /// compares to decide whether anything changed.
    public func samePrice(as other: PriceRecordValue) -> Bool {
        rates.sameNumbers(as: other.rates)
            && fastMultiplier == other.fastMultiplier
            && regionalMultiplier == other.regionalMultiplier
    }
}
