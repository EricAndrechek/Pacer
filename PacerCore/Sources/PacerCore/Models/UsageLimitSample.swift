import Foundation
import SwiftData

/// One observation of a single `limits[]` item from `/api/oauth/usage`.
///
/// Deliberately **generic columns**, not hard-coded window names: the
/// endpoint's `limits[]` is a scoped, extensible representation whose set
/// of models / kinds / groups / surfaces changes without notice. So we
/// persist the *shape* of a limit (identity, kind, group, percent, …)
/// rather than a column per known window. When Anthropic adds a per-model
/// window, a new `kind`, or a new `group`, its rows land here with zero
/// schema change; when a limit disappears, we simply stop writing rows for
/// that identity and the dashboard's "latest batch" view drops it.
///
/// Append-only history (like `RateLimitSample`) so the curve of any limit
/// — including per-model weekly windows we never charted before — can be
/// reconstructed and data divergence debugged from raw rows. All columns
/// are either non-optional-with-a-plain-default or optional, so this is a
/// SwiftData lightweight-migration-safe additive model.
@Model
public final class UsageLimitSample {
    // The read path fetches "the most recent poll's rows" (sort by
    // sampledAt desc, then take the top batch) and occasionally "one
    // identity's history over time". Both are served by these indexes.
    #Index<UsageLimitSample>(
        [\.sampledAt],
        [\.sampledAt, \.identity],
        [\.identity, \.sampledAt]
    )

    public var sampledAt: Date

    /// STABLE composite scope key (`kind|model|surface`) — see
    /// `UsageLimit.identity`. Threads a limit's history across polls and
    /// lets the UI diff same-vs-new limits. Not `.unique`: it repeats once
    /// per poll (that's the history).
    public var identity: String

    /// Rate-limit family, raw. OPEN set — stored as a plain String (same
    /// reasoning as `RateLimitSample.window`) so a new `kind` never fails
    /// to decode an old row.
    public var kind: String

    /// Server bucketing dimension (`session`, `weekly`, …), raw / OPEN set.
    public var group: String

    /// Precomputed human row label (model name or "All models" + surface).
    /// Stored so the UI needn't re-derive it and history rows stay legible
    /// even if the labelling logic later changes.
    public var label: String

    /// 0–100 window utilization.
    public var percent: Double

    /// Window rollover time; `nil` when the server sent null/absent.
    public var resetsAt: Date?

    /// Raw severity word (OPEN set). Interpreted at render time via
    /// `UsageLimitSeverity`, never matched here — so an unrecognized future
    /// severity is preserved verbatim rather than lost.
    public var severity: String

    /// Whether this was the binding limit in its group at sample time.
    public var isActive: Bool

    // Scope pieces, kept raw and optional so a row can be re-rendered or
    // re-grouped without re-parsing `identity`. All optional ⇒ additive.
    public var modelId: String?
    public var modelDisplayName: String?
    public var surface: String?

    /// `"oauth"` — mirrors `RateLimitSample.source` so a future pushed
    /// source can be distinguished.
    public var source: String

    /// Which account (`Account.id`) this scoped sample belongs to. Optional +
    /// additive: existing rows decode as nil (they were the single account's
    /// history). The multi-account poller stamps this going forward, and the
    /// active-account timeline swap (`OAuthPoller.swapActiveTimeline`) archives/
    /// restores this table alongside `RateLimitSample`, so it holds exactly the
    /// active account's scoped rows and two accounts that share a model identity
    /// (e.g. both have a "Fable" weekly) never mix. See `Account`.
    public var accountId: String?

    public init(
        sampledAt: Date,
        identity: String,
        kind: String,
        group: String,
        label: String,
        percent: Double,
        resetsAt: Date?,
        severity: String,
        isActive: Bool,
        modelId: String? = nil,
        modelDisplayName: String? = nil,
        surface: String? = nil,
        source: String,
        accountId: String? = nil
    ) {
        self.sampledAt = sampledAt
        self.identity = identity
        self.kind = kind
        self.group = group
        self.label = label
        self.percent = percent
        self.resetsAt = resetsAt
        self.severity = severity
        self.isActive = isActive
        self.modelId = modelId
        self.modelDisplayName = modelDisplayName
        self.surface = surface
        self.source = source
        self.accountId = accountId
    }

    /// Build a persistable row from a parsed `UsageLimit`.
    public convenience init(from limit: UsageLimit, sampledAt: Date, source: String, accountId: String? = nil) {
        self.init(
            sampledAt: sampledAt,
            identity: limit.identity,
            kind: limit.kind,
            group: limit.group,
            label: limit.label,
            percent: limit.percent,
            resetsAt: limit.resetsAt,
            severity: limit.severity.raw,
            isActive: limit.isActive,
            modelId: limit.scope?.model?.id,
            modelDisplayName: limit.scope?.model?.displayName,
            surface: limit.scope?.surface,
            source: source,
            accountId: accountId
        )
    }

    /// Reconstruct the interpreted severity from the stored raw word.
    public var severityValue: UsageLimitSeverity { UsageLimitSeverity(severity) }

    /// Effective color band (percent blended with severity floor). Mirrors
    /// `UsageLimit.displayBand` so a persisted row colors identically to a
    /// live one.
    public var displayBand: UsageBand {
        let byPercent = UsageBand(percentage: percent)
        let floor = severityValue.floor
        return Self.rank(byPercent) >= Self.rank(floor) ? byPercent : floor
    }

    private static func rank(_ band: UsageBand) -> Int {
        switch band {
        case .green:  return 0
        case .yellow: return 1
        case .orange: return 2
        case .red:    return 3
        }
    }
}

public extension Sequence where Element == UsageLimitSample {
    /// The rows belonging to the most recent poll — the `limits[]` snapshot
    /// as it looked on the last OAuth round-trip. A limit that vanished
    /// from the latest response is therefore absent here, which is exactly
    /// how "removed limits disappear with zero code change" is realized.
    ///
    /// All rows from one poll share an identical `sampledAt` (the poller
    /// stamps them from a single `snapshot.sampledAt`); the small
    /// `tolerance` only guards against sub-second jitter across sources.
    /// Returned sorted binding-first, then hottest-first, for a stable
    /// default order before the view re-groups.
    func latestBatch(tolerance: TimeInterval = 2) -> [UsageLimitSample] {
        let all = Array(self)
        guard let newest = all.map(\.sampledAt).max() else { return [] }
        let cutoff = newest.addingTimeInterval(-tolerance)
        return all
            .filter { $0.sampledAt >= cutoff }
            .sorted { a, b in
                if a.isActive != b.isActive { return a.isActive && !b.isActive }
                return a.percent > b.percent
            }
    }

    /// Rows that carry a *genuine* per-model / per-surface scope — i.e. a real
    /// scoped window (a "Fable" weekly cap) rather than an account-wide
    /// `session`/`weekly_all` row that merely duplicates the fixed 5h/7d hero
    /// windows. Same predicate the dashboard's pace card and the engine's
    /// `isModelScoped` use, factored here so every surface (pace card, menu bar)
    /// filters identically. Preserves the receiver's order.
    func modelScoped() -> [UsageLimitSample] {
        filter {
            ($0.modelId?.isEmpty == false)
                || ($0.modelDisplayName?.isEmpty == false)
                || ($0.surface?.isEmpty == false)
        }
    }
}
