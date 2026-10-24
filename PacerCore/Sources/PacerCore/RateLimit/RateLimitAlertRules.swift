import Foundation

/// What the 50/75/90% rate-limit threshold alerts judge (#318), from
/// Settings → Notifications → "Alert from".
public enum RateLimitAlertSource: String, Sendable, CaseIterable {
    /// Anthropic's readings only: the default.
    case readings
    /// Readings, and the live meter's estimate between them. Warns up to one
    /// poll earlier; an estimate can cross a line and step back at the next
    /// reading (5% of busy readings on the one-login replay), so each such
    /// banner says it is an estimate.
    case readingsAndEstimates

    public static func current(from store: UserDefaults = PacerPreferences.store) -> Self {
        store.string(forKey: PacerPreferenceKeys.alertSource).flatMap(Self.init(rawValue:)) ?? .readings
    }
}

/// The decisions behind the rate-limit banners, pure so both paths (readings
/// and estimates) share them and tests can hold them to "nothing alerts
/// twice" and "only readings announce a reset".
public enum RateLimitAlertRules {

    /// The dedup keys for one threshold of one window's cycle: the one
    /// written now first, then the one written before it existed.
    ///
    /// The cycle is the reset instant to the minute. The server re-serializes
    /// `resets_at` with every response and it jitters in the milliseconds
    /// (AGENTS.md rule 9), so the old key, the instant to the second, could
    /// name one cycle two ways. Readings alone rarely met that: a threshold
    /// is crossed once a cycle. With estimates on, the estimate and the next
    /// reading each cross it, from two readings' `resets_at`, and must find
    /// one key. The old form is still checked, so a threshold notified
    /// before this shipped is not notified again in the same cycle.
    public static func thresholdKeys(windowKey: String, threshold: Int, resetsAt: Date?) -> [String] {
        let base = "notif.\(windowKey).\(threshold)."
        guard let resetsAt else { return [base + "noreset"] }
        let minute = Date(timeIntervalSince1970: (resetsAt.timeIntervalSince1970 / 60).rounded() * 60)
        let stable = base + "cycle-" + stamp(minute)
        let legacy = base + stamp(resetsAt)
        return stable == legacy ? [stable] : [stable, legacy]
    }

    /// The thresholds to post now, each with the key to mark: the ones
    /// crossed upward since `previous` that no key of theirs has notified.
    public static func toPost(windowKey: String, previous: Double?, current: Double, thresholds: [Int],
                              resetsAt: Date?, notified: (String) -> Bool) -> [(threshold: Int, key: String)] {
        RateLimitThresholdPolicy.crossedThresholds(previous: previous, current: current, thresholds: thresholds)
            .compactMap { t in
                let keys = thresholdKeys(windowKey: windowKey, threshold: t, resetsAt: resetsAt)
                return keys.contains(where: notified) ? nil : (t, keys[0])
            }
    }

    /// Previous at or above this, and…
    public static let resetPreviousHigh: Double = 50
    /// …current at or below this, with the reset instant moved on: a window
    /// rolled over. Judged on readings only; no estimate is ever passed here.
    public static let resetCurrentLow: Double = 10

    /// Whether two consecutive **readings** say the window reset.
    public static func isReset(previousPct: Double?, currentPct: Double,
                               previousResetsAt: Date?, resetsAt: Date?) -> Bool {
        guard let previousPct, previousPct >= resetPreviousHigh, currentPct <= resetCurrentLow,
              let resetsAt, let previousResetsAt, resetsAt > previousResetsAt else { return false }
        return true
    }

    /// The banner's sentence: "5-hour usage hit 75% (threshold 75%)." or,
    /// from an estimate, "5-hour usage is estimated at 75% (threshold 75%)."
    public static func thresholdBody(label: String, percent: Double, threshold: Int, estimated: Bool) -> String {
        let pct = Int(percent.rounded(.down))
        return estimated
            ? "\(label) usage is estimated at \(pct)% (threshold \(threshold)%)."
            : "\(label) usage hit \(Int(percent.rounded()))% (threshold \(threshold)%)."
    }

    nonisolated(unsafe) private static let iso = ISO8601DateFormatter()
    private static func stamp(_ date: Date) -> String { iso.string(from: date) }
}
