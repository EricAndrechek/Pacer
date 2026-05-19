import Foundation

/// "Is Claude Code generating output right now?" classification, derived
/// from `SessionInfo.lastSeenAt`. Shared between the LiveSession widget,
/// the dashboard, and the menu-bar status item so all three converge on
/// one definition of "active."
///
/// The 5-min `active` threshold matches the OAuth poll cadence — under
/// steady writing, the most-recent session row's mtime is within 5 min
/// of now. The 1-hour `recent` threshold catches a paused-but-still-
/// alive session (the user thinking between messages); anything older
/// is `idle`.
public enum LiveSessionActivity: Sendable {
    case active
    case recent
    case idle

    /// Active when the last sample is ≤ 5 minutes old.
    public static let activeThreshold: TimeInterval = 300
    /// Recent when the last sample is ≤ 1 hour old.
    public static let recentThreshold: TimeInterval = 3600

    /// Classify based on the wall-clock age of the last sample. `now`
    /// is injectable for tests; production callers should pass `Date()`
    /// or omit (defaults to `Date()`).
    public static func from(lastSeen: Date, now: Date = Date()) -> LiveSessionActivity {
        let age = now.timeIntervalSince(lastSeen)
        if age <= activeThreshold { return .active }
        if age <= recentThreshold { return .recent }
        return .idle
    }

    /// Human-readable label for UI ("active", "recent", "idle").
    public var label: String {
        switch self {
        case .active: return "active"
        case .recent: return "recent"
        case .idle:   return "idle"
        }
    }
}
