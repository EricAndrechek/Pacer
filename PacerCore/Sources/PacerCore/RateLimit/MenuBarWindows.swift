import Foundation

/// One rate-limit window as the menu bar surfaces it — the fixed 5-hour /
/// 7-day blocks plus every scoped per-model window Anthropic reports for the
/// active account (`limits[]`, e.g. a "Fable" weekly cap).
///
/// This is a plain value type (no SwiftData) on purpose: the menu bar's two
/// dynamic behaviours — listing every current window in the dropdown, and
/// letting the user pick which window's utilization drives the status-item
/// icon — reduce to pure functions over this shape (`MenuBarWindows.ordered`
/// and `MenuBarWindows.resolveDriver`). The App layer maps live
/// `RateLimitSample` / `UsageLimitSample` rows into these items; the ordering
/// and driver-selection logic stays unit-testable without rendering SwiftUI or
/// standing up a store.
public struct MenuBarWindowItem: Equatable, Sendable, Identifiable {
    /// Window key: `"five_hour"` / `"seven_day"` for the fixed blocks, or a
    /// scoped `limits[]` identity (`UsageLimit.identity`). Doubles as the
    /// icon-driver preference value and the `Identifiable` id.
    public let key: String
    /// Human label — "5-hour", "7-day", or the scoped row's model/surface label.
    public let displayName: String
    /// Latest utilization 0–100, or `nil` when no sample has landed yet
    /// (the genuine cold start — the row renders "collecting…").
    public let usedPercentage: Double?
    /// Window rollover; `nil` when idle / the server anchored no cycle.
    public let resetsAt: Date?
    /// Window length in seconds — feeds the dropdown row's pace/cycle math.
    public let duration: TimeInterval
    /// Server bucketing hint (`session` / `weekly` / …); empty for fixed blocks.
    public let group: String
    /// A scoped per-model / per-surface window (vs. a fixed account-wide block).
    public let isScoped: Bool
    /// Scoped windows only: the one currently *in effect* (binding) for the
    /// account as of the latest poll. Always `false` for fixed windows.
    public let isActive: Bool

    public var id: String { key }

    public init(
        key: String,
        displayName: String,
        usedPercentage: Double?,
        resetsAt: Date?,
        duration: TimeInterval,
        group: String,
        isScoped: Bool,
        isActive: Bool
    ) {
        self.key = key
        self.displayName = displayName
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
        self.duration = duration
        self.group = group
        self.isScoped = isScoped
        self.isActive = isActive
    }

    /// Where this window sits in the sorted run — reusing the dashboard's
    /// glued-heroes ordering so the menu bar and the pace card agree. Fixed
    /// windows anchor `.fiveHour` / `.sevenDay`; scoped windows snap to a side
    /// by their `group` hint (period fallback), so a scoped cap never lands
    /// *between* the two heroes.
    public var orderingSide: PaceColumnLayout.Side {
        if !isScoped {
            switch key {
            case RateLimitWindowName.fiveHour: return .fiveHour
            case RateLimitWindowName.sevenDay: return .sevenDay
            default: break
            }
        }
        return PaceColumnLayout.scopedSide(
            group: group, duration: duration,
            fiveHourDuration: MenuBarWindows.fiveHourDuration,
            sevenDayDuration: MenuBarWindows.sevenDayDuration)
    }
}

/// Pure logic backing the menu bar's dynamic window handling: the ordered
/// window set (dropdown listing) and the icon-driver resolution (which
/// window's % paints the status-item glyph).
public enum MenuBarWindows {
    /// Fixed-window durations — the anchors the ordering shares with the
    /// dashboard's pace card.
    public static let fiveHourDuration: TimeInterval = 5 * 3600
    public static let sevenDayDuration: TimeInterval = 7 * 86_400

    /// Legacy stored icon-driver value (empty string) that historically meant
    /// "auto / the window in effect", resolving to the 5-hour window. The driver
    /// is now chosen **explicitly** (the picker offers no "Auto" row; the default
    /// is the 5-hour window's key), but this legacy value must keep resolving to
    /// the 5-hour window so existing installs don't break — see `resolveDriver`.
    public static let autoDriverKey = ""

    /// The explicit default icon-driver: the 5-hour window. New installs store
    /// this; a legacy `autoDriverKey` ("") resolves to the same window.
    public static let defaultDriverKey = RateLimitWindowName.fiveHour

    /// Hard cap on the number of concentric activity rings the menu-bar icon
    /// draws (Apple-Watch style). Three is the most that stays legible at
    /// menu-bar size.
    public static let maxRingWindows = 3

    /// Default activity-ring window set: outer 5-hour, inner 7-day — the two
    /// rings the `.activityRings` icon drew before the set became configurable,
    /// so existing users' 2-ring icon is unchanged.
    public static let defaultRingWindowKeys = [RateLimitWindowName.fiveHour, RateLimitWindowName.sevenDay]

    /// Order like the dashboard: scoped **session**-side windows, then **5h**,
    /// then **7d**, then scoped **weekly**-side windows, then any longer/other
    /// scoped window — sorting on `(side, duration, displayName, key)`. With
    /// only the two fixed windows this yields exactly `[5h, 7d]`.
    public static func ordered(_ items: [MenuBarWindowItem]) -> [MenuBarWindowItem] {
        items.sorted { lhs, rhs in
            if lhs.orderingSide != rhs.orderingSide {
                return lhs.orderingSide < rhs.orderingSide
            }
            if lhs.duration != rhs.duration { return lhs.duration < rhs.duration }
            if lhs.displayName != rhs.displayName {
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            return lhs.key < rhs.key
        }
    }

    /// The window whose utilization should drive the status-item icon.
    ///
    /// - A specific `key` that is present in the current window set wins.
    /// - A legacy `autoDriverKey` ("") — or a specific key whose window has
    ///   *disappeared* since it was chosen — both fall back to the default
    ///   anchor: the 5-hour block, else the 7-day block, else the first window.
    ///
    /// Returns `nil` only when there are no windows at all — the icon then keeps
    /// its neutral no-data appearance, exactly as before this feature.
    public static func resolveDriver(key: String, windows: [MenuBarWindowItem]) -> MenuBarWindowItem? {
        if !key.isEmpty, let match = windows.first(where: { $0.key == key }) {
            return match
        }
        return windows.first(where: { $0.key == RateLimitWindowName.fiveHour })
            ?? windows.first(where: { $0.key == RateLimitWindowName.sevenDay })
            ?? windows.first
    }

    /// Whether a stored driver `key` names a real, currently-available window
    /// (i.e. the user's explicit pick is live, not silently falling back). The
    /// settings picker uses this to flag a chosen-but-vanished window.
    public static func driverIsResolvable(key: String, windows: [MenuBarWindowItem]) -> Bool {
        key.isEmpty || windows.contains { $0.key == key }
    }

    /// The ordered set of windows the `.activityRings` icon draws — one ring per
    /// key, **outer → inner** in the stored order.
    ///
    /// - Each key maps to its live window; a key whose window has **disappeared**
    ///   from the latest poll is skipped (that ring drops out), and duplicate
    ///   keys are collapsed.
    /// - The result is capped at `maxRingWindows` (3); extra keys are ignored.
    /// - If nothing resolves (every configured window vanished, or the list was
    ///   empty), it falls back to the single default anchor — the 5-hour block,
    ///   else 7-day, else the first window — so the icon is never empty.
    ///
    /// Returns `[]` only when there are no windows at all (the genuine cold
    /// start, before any sample or fixed block exists).
    public static func resolveRingWindows(keys: [String], windows: [MenuBarWindowItem]) -> [MenuBarWindowItem] {
        var seen = Set<String>()
        var resolved: [MenuBarWindowItem] = []
        for key in keys where !key.isEmpty {
            guard seen.insert(key).inserted,
                  let match = windows.first(where: { $0.key == key }) else { continue }
            resolved.append(match)
            if resolved.count == maxRingWindows { break }
        }
        if resolved.isEmpty,
           let anchor = windows.first(where: { $0.key == RateLimitWindowName.fiveHour })
               ?? windows.first(where: { $0.key == RateLimitWindowName.sevenDay })
               ?? windows.first {
            resolved.append(anchor)
        }
        return resolved
    }
}
