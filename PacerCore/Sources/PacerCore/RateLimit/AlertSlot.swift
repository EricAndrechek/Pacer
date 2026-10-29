import Foundation

/// Where a window's banner lives in Notification Center: one slot per window
/// per account (owner, 2026-10-29).
///
/// Every alert about one account's window — its 50/75/90% thresholds, its
/// burn-rate warning, its reset — posts under the same request identifier, so
/// each new one *replaces* the one before instead of stacking beside it. The
/// header is explicit that a replacement alerts again
/// (`UNUserNotificationCenter.h`: "will alert for the new notification request
/// and replace the existing delivered notification"), which is what an
/// escalation from 75% to 90% should do.
///
/// The identifier is deliberately *not* the dedup key. Dedup stays per
/// threshold per cycle in `ClaudeCodeMeta` (`RateLimitAlertRules`), so what
/// fires is unchanged; only where it lands is.
public enum AlertSlot {
    /// `windowKey` is the account-scoped key (`five_hour#<account>`, or a
    /// scoped identity with the same suffix).
    public static func identifier(windowKey: String) -> String { prefix + windowKey }

    /// Every slot identifier starts with this, so a sweep can find them
    /// among Pacer's other notifications.
    public static let prefix = "pacer.window."

    /// `userInfo` keys a slot's notification carries, read back by the sweep
    /// and by the "Mute until reset" action.
    public static let windowKeyInfo = "pacer.windowKey"
    public static let windowInfo = "pacer.window"
    public static let resetsAtInfo = "pacer.resetsAt"

    /// How long past its window's reset a banner survives. `resets_at`
    /// jitters (AGENTS.md rule 9), so a banner must not be cleared on the
    /// exact instant; a minute is far beyond the jitter and far below
    /// anything a person would call "still there after the reset".
    public static let resetGrace: TimeInterval = 60

    /// Whether a delivered banner's window has reset since it was posted.
    /// No reset instant (the server sends none at 0% idle) never expires by
    /// time; the next alert for the slot replaces it, or a reset clears it.
    public static func isStale(resetsAt: Date?, now: Date) -> Bool {
        guard let resetsAt else { return false }
        return now >= resetsAt.addingTimeInterval(resetGrace)
    }

    /// The `userInfo` a slot's notification carries.
    public static func userInfo(windowKey: String, window: String, resetsAt: Date?) -> [String: Any] {
        var info: [String: Any] = [windowKeyInfo: windowKey, windowInfo: window]
        if let resetsAt { info[resetsAtInfo] = resetsAt.timeIntervalSince1970 }
        return info
    }

    public static func resetsAt(from userInfo: [AnyHashable: Any]) -> Date? {
        (userInfo[resetsAtInfo] as? Double).map(Date.init(timeIntervalSince1970:))
    }
}

/// "Mute until reset", per account per window: the warnings for a slot stay
/// quiet until its window resets.
///
/// A mute ends on its own at the reset it was set against, so nothing has to
/// remember to undo it; a reset Pacer sees early (an off-schedule global
/// reset) ends it then too.
public struct AlertMutes: Sendable, Equatable {
    public private(set) var until: [String: Date]

    public init(until: [String: Date] = [:]) { self.until = until }

    public func isMuted(_ windowKey: String, now: Date) -> Bool {
        guard let end = until[windowKey] else { return false }
        return now < end
    }

    /// Mute `windowKey` until its reset. Without a reset instant, for one
    /// window length (`fallback`), so a mute set at 0% idle still ends.
    public mutating func mute(_ windowKey: String, resetsAt: Date?, fallback: TimeInterval, now: Date) {
        until[windowKey] = resetsAt.map { $0.addingTimeInterval(AlertSlot.resetGrace) }
            ?? now.addingTimeInterval(fallback)
    }

    public mutating func unmute(_ windowKey: String) { until[windowKey] = nil }

    /// Drop mutes that have ended, so the stored map stays the size of what
    /// is muted now.
    public mutating func prune(now: Date) { until = until.filter { now < $0.value } }

    // Stored as `[String: Double]` (seconds since 1970) so it is a plain
    // property list in the App Group defaults.
    public init(plist: Any?) {
        let raw = plist as? [String: Double] ?? [:]
        until = raw.mapValues(Date.init(timeIntervalSince1970:))
    }

    public var plist: [String: Double] { until.mapValues(\.timeIntervalSince1970) }
}
