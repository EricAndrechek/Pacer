import Foundation

/// The engine's generic identity for one forecastable rate-limit window.
///
/// Historically the engine knew exactly two windows — the fixed 5-hour and
/// 7-day blocks (`RateLimitWindowKind`). Everything the rate-limit pipeline
/// does, though, is already keyed by a *string* window key and parameterised by
/// a *duration*: cycle segmentation, the burn-trajectory roster, stratified
/// conformal bands, the self-eval surface `rl-<key>`, the prediction snapshots.
/// The only things that were 5h/7d-special were (a) where the duration came
/// from (a hard switch) and (b) the enum-typed public API. `WindowSpec` closes
/// that gap: it is the one value that drives every per-window loop, so a window
/// the server invents (a per-model "Fable · weekly" scoped cap) is just another
/// spec — no new code path.
///
/// The fixed 5h/7d windows become two `WindowSpec`s (`origin == .fixed`) that
/// reproduce the old behaviour byte-for-byte; scoped per-model windows
/// (`origin == .scoped`) flow through the identical machinery.
public struct WindowSpec: Sendable, Equatable {

    /// Where a window came from — the fixed account-wide blocks the hero cards
    /// own, or a scoped `limits[]` identity (per-model / per-surface cap).
    public enum Origin: Sendable, Equatable {
        case fixed(RateLimitWindowKind)
        case scoped(identity: String, group: String,
                    modelId: String?, modelDisplayName: String?, surface: String?)
    }

    /// The window key: `"five_hour"` / `"seven_day"` for the fixed blocks, or a
    /// scoped identity `"kind|model|surface"` (see `UsageLimit.identity`). Keys
    /// every per-window dictionary, self-eval surface, and snapshot surface.
    public let key: String
    /// Window length in seconds — the cycle duration handed to
    /// `BurnTrajectory.segment` and the conformal calibrators.
    public let duration: TimeInterval
    /// Human label ("5-hour", "7-day", "Fable · weekly").
    public let displayName: String
    public let origin: Origin

    public init(key: String, duration: TimeInterval, displayName: String, origin: Origin) {
        self.key = key
        self.duration = duration
        self.displayName = displayName
        self.origin = origin
    }

    // MARK: - Cadence

    /// Windows at least a day long are treated as **weekly-cadence**; shorter
    /// ones as **session-cadence**. This single boundary replaces every 5h-vs-7d
    /// branch the rate-limit path used to make:
    ///   - the diurnal model is an *established* candidate on weekly-cadence
    ///     windows but a *promotion-gated shadow* on session-cadence ones
    ///     (`rlShadowFloors`);
    ///   - cold-start selection defaults to the diurnal shape on weekly-cadence
    ///     windows, recency-weighted on session-cadence ones (`makeFit`);
    ///   - the descriptive burn slope reads a 24 h lookback on weekly-cadence
    ///     windows, 90 min on session-cadence ones (`burnOutlook`).
    /// The fixed 5 h (session) and 7 d (weekly) windows sit cleanly on either
    /// side of this threshold, so their behaviour is provably unchanged.
    public static let weeklyScaleThreshold: TimeInterval = 24 * 3600

    public static func isWeeklyScale(duration: TimeInterval) -> Bool {
        duration >= weeklyScaleThreshold
    }

    public var isWeeklyScale: Bool { WindowSpec.isWeeklyScale(duration: duration) }

    // MARK: - Fixed windows

    /// The two fixed account-wide blocks, reproducing the exact `(key,
    /// duration)` the old `RateLimitWindowKind.allCases` path used.
    public static func fixed(_ kind: RateLimitWindowKind) -> WindowSpec {
        let duration = PaceMath.windowDuration(for: kind.rawValue)
            ?? (kind == .fiveHour ? 5 * 3600 : 7 * 24 * 3600)
        let name = kind == .fiveHour ? "5-hour" : "7-day"
        return WindowSpec(key: kind.rawValue, duration: duration, displayName: name, origin: .fixed(kind))
    }

    /// The canonical fixed window set, in the same order the engine iterated
    /// `RateLimitWindowKind.allCases` (`five_hour`, then `seven_day`).
    public static var fixedWindows: [WindowSpec] {
        RateLimitWindowKind.allCases.map { WindowSpec.fixed($0) }
    }

    // MARK: - Scoped windows

    /// Duration for a scoped window from its server `group` hint, with a
    /// reset-spacing fallback (Decision B): `session ⇒ 5 h`, `weekly ⇒ 7 d`,
    /// otherwise the median observed reset-to-reset spacing when at least one
    /// spacing (≥ 2 completed cycles) is known, else a 7 d default.
    public static func scopedDuration(group: String, resetSpacings: [TimeInterval] = []) -> TimeInterval {
        switch group.lowercased() {
        case "session": return 5 * 3600
        case "weekly":  return 7 * 24 * 3600
        default:
            let valid = resetSpacings.filter { $0 > 0 }.sorted()
            guard !valid.isEmpty else { return 7 * 24 * 3600 }
            return valid[valid.count / 2]
        }
    }

    /// A scoped window spec from a `limits[]` identity. `resetSpacings` feeds
    /// the duration fallback when the `group` isn't a known cadence word.
    public static func scoped(
        identity: String, group: String, label: String,
        modelId: String?, modelDisplayName: String?, surface: String?,
        resetSpacings: [TimeInterval] = []
    ) -> WindowSpec {
        WindowSpec(
            key: identity,
            duration: scopedDuration(group: group, resetSpacings: resetSpacings),
            displayName: label,
            origin: .scoped(identity: identity, group: group,
                            modelId: modelId, modelDisplayName: modelDisplayName, surface: surface))
    }

    /// Whether this window is a scoped per-model / per-surface cap (vs. a fixed
    /// account-wide block).
    public var isScoped: Bool {
        if case .scoped = origin { return true }
        return false
    }
}
