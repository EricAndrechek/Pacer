import Foundation

/// One item from the `limits[]` array returned by `GET /api/oauth/usage`.
///
/// `limits[]` is Anthropic's newer, **scoped, extensible** representation
/// of rate-limit windows — a strict superset of the ad-hoc top-level
/// `five_hour` / `seven_day` / `seven_day_opus` fields Pacer historically
/// parsed. A single item looks like:
///
/// ```json
/// { "kind": "weekly_scoped", "group": "weekly", "percent": 49,
///   "severity": "normal", "resets_at": "2026-07-13T09:59:59+00:00",
///   "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null },
///   "is_active": false }
/// ```
///
/// **Design contract — fully adaptive.** Everything here treats the
/// server's vocabulary as OPEN sets: `kind`, `group`, `severity`, and
/// `scope.surface` are stored as raw strings and never matched against a
/// hard-coded allow-list. A brand-new model window, a new `kind`, a new
/// `group`, a renamed `severity`, or a removed limit must all render and
/// persist correctly with zero code changes. The only thing we *interpret*
/// is `severity`, and unknown values fall through to a safe default (they
/// still color by `percent`), so a new severity tier can never break the
/// UI — at worst it under-escalates until we teach it the new word.
public struct UsageLimit: Sendable, Equatable, Hashable {

    /// Rate-limit family, e.g. `session`, `weekly_all`, `weekly_scoped`.
    /// Raw string — an OPEN set. New kinds appear here verbatim.
    public let kind: String

    /// Bucketing dimension the server groups limits under, e.g. `session`,
    /// `weekly`. Raw string — also an OPEN set. Falls back to `kind` when
    /// the server omits it so an item is never orphaned from a group.
    public let group: String

    /// 0–100 window utilization (same scale as `five_hour.utilization`).
    public let percent: Double

    /// Server-supplied urgency hint. Interpreted leniently — unknown
    /// values are kept raw and treated as `.normal` for escalation.
    public let severity: UsageLimitSeverity

    /// When this window rolls over. `nil` when the server sent
    /// `resets_at: null`/absent (matches how Pacer tolerates it elsewhere).
    public let resetsAt: Date?

    /// The scope this limit applies to. `nil` = account-wide (all models,
    /// all surfaces). Non-nil carries a model and/or a product surface.
    public let scope: UsageLimitScope?

    /// The currently-binding limit within its group — the one actually
    /// gating the user right now. Highlighted in the UI.
    public let isActive: Bool

    public init(
        kind: String,
        group: String,
        percent: Double,
        severity: UsageLimitSeverity,
        resetsAt: Date?,
        scope: UsageLimitScope?,
        isActive: Bool
    ) {
        self.kind = kind
        self.group = group
        self.percent = percent
        self.severity = severity
        self.resetsAt = resetsAt
        self.scope = scope
        self.isActive = isActive
    }

    // MARK: - Stable identity

    /// A STABLE composite identity that survives across polls so a limit's
    /// history threads together and the UI can diff "same limit" vs. "new
    /// limit". Built from the three scoping axes the server keys a window
    /// on — `kind`, model, and surface — none of which is enumerated, so a
    /// new model or surface simply produces a new identity. Model id is
    /// preferred over display name (ids are opaque-but-stable; display
    /// names can be rebranded), with display name as the fallback since the
    /// live payload often has `id: null`.
    public var identity: String {
        let modelKey = scope?.model?.id ?? scope?.model?.displayName ?? ""
        let surfaceKey = scope?.surface ?? ""
        return "\(kind)|\(modelKey)|\(surfaceKey)"
    }

    /// Human row label. A scoped limit reads as its model ("Fable"); an
    /// account-wide one reads "All models". A non-nil surface is appended
    /// so a future per-surface split stays legible without a code change.
    public var label: String {
        let base = scope?.model?.displayName
            ?? scope?.model?.id
            ?? "All models"
        if let surface = scope?.surface, !surface.isEmpty {
            return "\(base) · \(surface)"
        }
        return base
    }

    /// Effective color band, blending the objective `percent` band with a
    /// severity floor: severity can only ever *escalate* the band, never
    /// mask a genuinely-hot percentage. So even if the server's severity
    /// vocabulary changes out from under us, a 95%-used window still shows
    /// red. Unknown severity contributes no floor (safe default).
    public var displayBand: UsageBand {
        UsageLimit.moreSevere(UsageBand(percentage: percent), severity.floor)
    }

    private static func moreSevere(_ a: UsageBand, _ b: UsageBand) -> UsageBand {
        rank(a) >= rank(b) ? a : b
    }

    private static func rank(_ band: UsageBand) -> Int {
        switch band {
        case .green:  return 0
        case .yellow: return 1
        case .orange: return 2
        case .red:    return 3
        }
    }

    // MARK: - Parsing

    /// Tolerant parse of the raw `limits[]` value (as produced by
    /// `JSONSerialization`, matching `OAuthClient`'s hand-rolled decode of
    /// the rest of the payload — deliberately NOT `Codable`, so one
    /// malformed item can never fail the whole response).
    ///
    /// Rules, all additive-safe:
    /// - Non-array input (absent field, wrong type) → `[]`.
    /// - An item missing a numeric `percent` is skipped (nothing to draw)
    ///   rather than shown as a phantom 0%.
    /// - Missing `kind` → `"unknown"`; missing `group` → falls back to
    ///   `kind` so the item still buckets somewhere.
    /// - Missing `severity` → empty raw string → treated as normal.
    /// - `scope: null`, `scope.model: null`, `resets_at: null` all tolerated.
    public static func parse(_ raw: Any?) -> [UsageLimit] {
        guard let array = raw as? [Any] else { return [] }
        return array.compactMap { element in
            guard let dict = element as? [String: Any] else { return nil }
            guard let percent = numericValue(dict["percent"]) else { return nil }

            let kind = (dict["kind"] as? String) ?? "unknown"
            let group = (dict["group"] as? String) ?? kind
            let severity = UsageLimitSeverity(dict["severity"] as? String ?? "")
            let isActive = boolValue(dict["is_active"]) ?? false

            var resetsAt: Date?
            if let s = dict["resets_at"] as? String, !s.isEmpty {
                resetsAt = parseOAuthISO8601(s)
            }

            let scope = UsageLimitScope.parse(dict["scope"])

            return UsageLimit(
                kind: kind,
                group: group,
                percent: percent,
                severity: severity,
                resetsAt: resetsAt,
                scope: scope,
                isActive: isActive
            )
        }
    }

    /// Coerce JSON numeric variants to Double. Mirrors `OAuthClient`'s
    /// numeric tolerance so an integer `percent` (the common case — the
    /// server emits integer percent) parses the same as a Double.
    static func numericValue(_ raw: Any?) -> Double? {
        if let v = raw as? Double { return v }
        if let v = raw as? Int { return Double(v) }
        if let v = raw as? NSNumber { return v.doubleValue }
        return nil
    }

    static func boolValue(_ raw: Any?) -> Bool? {
        if let v = raw as? Bool { return v }
        if let v = raw as? NSNumber { return v.boolValue }
        return nil
    }
}

/// The scope a `UsageLimit` applies to. Both fields are optional and
/// stored raw — a limit can be model-scoped, surface-scoped, both, or (with
/// an all-nil scope, or a nil scope entirely) account-wide.
public struct UsageLimitScope: Sendable, Equatable, Hashable {
    public let model: Model?
    /// A second, product-surface scoping axis (e.g. a specific product).
    /// Raw string, OPEN set — `nil` in every sample seen so far.
    public let surface: String?

    public struct Model: Sendable, Equatable, Hashable {
        /// Opaque model id. Frequently `null` in the live payload, hence
        /// optional; when present it's the most stable identity key.
        public let id: String?
        /// Human model name, e.g. "Fable". The usual identity fallback.
        public let displayName: String?

        public init(id: String?, displayName: String?) {
            self.id = id
            self.displayName = displayName
        }
    }

    public init(model: Model?, surface: String?) {
        self.model = model
        self.surface = surface
    }

    /// Parse a raw `scope` value. Returns `nil` for `null`/absent/non-dict
    /// (account-wide). A dict whose `model` and `surface` are both absent
    /// still yields a (nil-model, nil-surface) scope — harmless, and it
    /// keeps "explicitly-empty scope" distinguishable from "no scope key".
    static func parse(_ raw: Any?) -> UsageLimitScope? {
        guard let dict = raw as? [String: Any] else { return nil }
        var model: Model?
        if let modelDict = dict["model"] as? [String: Any] {
            let id = modelDict["id"] as? String
            let name = modelDict["display_name"] as? String
            // Drop a wholly-empty model object so identity/label stay clean.
            if id != nil || name != nil {
                model = Model(id: id, displayName: name)
            }
        }
        let surface = dict["surface"] as? String
        if model == nil && surface == nil { return nil }
        return UsageLimitScope(model: model, surface: surface)
    }
}

/// Server urgency hint, kept as a raw string (OPEN set) with a lenient
/// interpretation. Only `severity` needs interpreting, and unknown values
/// are safe — they contribute no escalation floor, so `percent` alone
/// drives the color. This is the "map unknown severity to a safe default"
/// rule: a severity word we've never seen degrades to "normal" rather than
/// crashing, hiding the limit, or firing a false alarm.
public struct UsageLimitSeverity: Sendable, Equatable, Hashable {
    public let raw: String

    public init(_ raw: String) {
        self.raw = raw
    }

    /// The escalation floor this severity imposes on the row's color band.
    /// Known warning-ish words push at least orange; critical-ish words
    /// push red; everything else (including the empty/normal case and any
    /// future unknown word) imposes no floor.
    public var floor: UsageBand {
        switch raw.lowercased() {
        case "warning", "warn", "elevated", "approaching", "near_limit":
            return .orange
        case "critical", "exceeded", "blocked", "hard", "over_limit", "throttled":
            return .red
        default:
            return .green   // normal / info / unknown → safe default
        }
    }

    /// Whether this is a recognized non-normal severity — used only to
    /// decide if the raw word is worth surfacing as a tag. Unknown words
    /// return false so we never print a mystery string as if it were
    /// meaningful.
    public var isElevated: Bool {
        floor != .green
    }
}
