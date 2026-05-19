import Foundation
import SwiftUI
import PacerCore

/// User-facing preferences. Stored in the App Group's shared
/// `UserDefaults` so the app, widget extension, and any future
/// statusline tap can all read the same values without an IPC
/// round-trip. SwiftUI views bind with
/// `@AppStorage(key, store: PacerSettings.store)`.
///
/// Additive only — never remove or rename keys. If a key needs to
/// change semantics, add a new key alongside and migrate.
public enum PacerSettings {
    /// App Group-suite UserDefaults so every Pacer surface shares one
    /// resolved suite — there's no chance of "app reads defaults from
    /// suite X, widget reads from suite Y." Delegates to
    /// `PacerCore.PacerPreferences.store`.
    public static var store: UserDefaults { PacerPreferences.store }

    /// What the menu bar item shows. Hiding it entirely is a real
    /// use case for users who want the dashboard but not the
    /// status-bar icon, so we model "hidden" as a first-class mode.
    public enum MenuBarStyle: String, CaseIterable, Identifiable, Sendable {
        case hidden            = "hidden"
        case iconOnly          = "icon"
        case percentOnly       = "percent"
        case iconAndPercent    = "icon_percent"

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .hidden:           return "Hidden"
            case .iconOnly:         return "Icon only"
            case .percentOnly:      return "Percentage only"
            case .iconAndPercent:   return "Icon + percentage"
            }
        }

        public var defaultRaw: String { Self.iconAndPercent.rawValue }
    }

    public enum MenuBarIconStyle: String, CaseIterable, Identifiable, Sendable {
        case gaugeNeedle  = "gauge_needle"
        case ringFill     = "ring_fill"
        case dot          = "dot"
        case activityRings = "activity_rings"

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .gaugeNeedle:    return "Gauge needle"
            case .ringFill:       return "Ring fill"
            case .dot:            return "Status dot"
            case .activityRings:  return "Activity rings"
            }
        }
    }

    /// One chip in the menu bar status item. The user picks any subset
    /// and orders them via Settings → Menu bar. Empty subset hides the
    /// item entirely.
    ///
    /// Why a chip list rather than a fixed enum: the previous
    /// `MenuBarStyle` (hidden / icon / percent / icon+percent) gave a
    /// 4-way choice that couldn't surface today's cost, the 7-day
    /// window, or the active model — all of which different users
    /// want at-a-glance. A chip list scales to any future additions
    /// without bloating the picker into a 12-way enum.
    public enum MenuBarChip: String, CaseIterable, Identifiable, Sendable {
        case icon          = "icon"
        case fiveHourPct   = "five_hour_pct"
        case sevenDayPct   = "seven_day_pct"
        case todayCost     = "today_cost"
        case todayTokens   = "today_tokens"
        case activeModel   = "active_model"

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .icon:          return "Icon"
            case .fiveHourPct:   return "5-hour %"
            case .sevenDayPct:   return "7-day %"
            case .todayCost:     return "Today's cost"
            case .todayTokens:   return "Today's tokens"
            case .activeModel:   return "Active model"
            }
        }

        /// Short helper text shown under each row in Settings.
        public var blurb: String {
            switch self {
            case .icon:          return "Gauge / ring / dot driven by 5-hour usage"
            case .fiveHourPct:   return "Current 5-hour rate-limit utilization"
            case .sevenDayPct:   return "Current 7-day rate-limit utilization"
            case .todayCost:     return "Today's spend in USD"
            case .todayTokens:   return "Today's token total (K / M / B)"
            case .activeModel:   return "Most recently used Claude model"
            }
        }

        public static let defaultOrder: [MenuBarChip] = [
            .icon, .fiveHourPct, .sevenDayPct,
            .todayCost, .todayTokens, .activeModel
        ]
    }

    // MARK: - Storage keys
    //
    // Delegated to PacerCore.PacerPreferenceKeys so the in-process
    // scan code (which lives in PacerCore) can read these without
    // linking App-target code. Anything new should also live there
    // if a non-app surface needs to read it.

    public enum Key {
        public static let menuBarStyle           = PacerPreferenceKeys.menuBarStyle
        public static let menuBarIconStyle       = PacerPreferenceKeys.menuBarIconStyle
        public static let menuBarChips           = PacerPreferenceKeys.menuBarChips
        public static let notificationsEnabled   = PacerPreferenceKeys.notificationsEnabled
        public static let fiveHourThresholdPct   = PacerPreferenceKeys.fiveHourThresholdPct
        public static let sevenDayThresholdPct   = PacerPreferenceKeys.sevenDayThresholdPct
        public static let fiveHourThresholdsCSV  = PacerPreferenceKeys.fiveHourThresholdsCSV
        public static let sevenDayThresholdsCSV  = PacerPreferenceKeys.sevenDayThresholdsCSV
        public static let notifyOnDailyCost      = PacerPreferenceKeys.notifyOnDailyCost
        public static let dailyCostThresholdUSD  = PacerPreferenceKeys.dailyCostThresholdUSD
        public static let notifyOnReset          = PacerPreferenceKeys.notifyOnReset
        public static let notifyDailySummary     = PacerPreferenceKeys.notifyDailySummary
        public static let dailySummaryHour       = PacerPreferenceKeys.dailySummaryHour
        public static let costMode               = PacerPreferenceKeys.costMode
        public static let timeRange              = PacerPreferenceKeys.timeRange
        public static let projectsSort           = PacerPreferenceKeys.projectsSort
    }

    // MARK: - Defaults

    nonisolated(unsafe) public static let defaults: [String: Any] = [
        Key.menuBarStyle:          MenuBarStyle.iconAndPercent.rawValue,
        Key.menuBarIconStyle:      MenuBarIconStyle.gaugeNeedle.rawValue,
        // Default: icon + 5-hour %. Matches the previous default
        // `iconAndPercent`, just expressed in the chip vocabulary so
        // a fresh-install user sees the same thing returning users do
        // after the migration in `migrateLegacyMenuBarStyle()`.
        Key.menuBarChips:          "icon,five_hour_pct",
        Key.notificationsEnabled:  false,
        Key.fiveHourThresholdPct:  75,
        Key.sevenDayThresholdPct:  75,
        Key.fiveHourThresholdsCSV: "75",
        Key.sevenDayThresholdsCSV: "75",
        Key.notifyOnDailyCost:     false,
        Key.dailyCostThresholdUSD: 50.0,
        Key.notifyOnReset:         false,
        Key.notifyDailySummary:    false,
        Key.dailySummaryHour:      21,
        Key.costMode:              "auto",
        Key.timeRange:             "90d",
        Key.projectsSort:          "cost",
    ]

    /// Register the defaults dict on first launch — `@AppStorage`'s
    /// own default-value parameter only kicks in when the key is
    /// totally absent, so we register here to make sure the suite
    /// has the right shape from launch one.
    public static func registerDefaults() {
        // Run migration BEFORE registering defaults so the "is the key
        // really absent" check works — `register(defaults:)` makes
        // every key look populated to `string(forKey:)`. We persist the
        // migrated value, then registerDefaults harmlessly leaves it
        // alone (registered defaults only fill genuinely-empty slots).
        migrateLegacyMenuBarStyle()
        store.register(defaults: defaults)
        migrateLegacyThresholds()
    }

    /// One-time migration from the legacy `menuBarStyle` enum to the
    /// `menuBarChips` CSV. Without this, a returning user who'd flipped
    /// to "Icon only" or "Percent only" would jump back to the new
    /// default ("icon,five_hour_pct") because `register(defaults:)`
    /// only kicks in when the key is totally absent. Their explicit
    /// preference should carry forward.
    ///
    /// Once a user has saved a `menuBarChips` value (any value, even
    /// an empty string for "hide everything"), we never re-run this —
    /// `object(forKey:)` returns non-nil only for persisted values
    /// because this runs before `register(defaults:)`.
    private static func migrateLegacyMenuBarStyle() {
        if let existing = store.object(forKey: Key.menuBarChips) {
            // Already migrated. Log so we can confirm in
            // ~/Library/Logs/Pacer/Pacer.err.log that on subsequent
            // launches we're reading what was previously persisted.
            let raw = (existing as? String) ?? "(non-string)"
            Log.write("Settings", "menuBarChips already persisted: '\(raw)'")
            return
        }
        let legacyRaw = store.string(forKey: Key.menuBarStyle) ?? ""
        let migrated: String
        switch MenuBarStyle(rawValue: legacyRaw) {
        case .hidden:           migrated = ""
        case .iconOnly:         migrated = "icon"
        case .percentOnly:      migrated = "five_hour_pct"
        case .iconAndPercent,
             nil:               migrated = "icon,five_hour_pct"
        }
        Log.write(
            "Settings",
            "menuBarChips migration ran: legacyStyle='\(legacyRaw)' → '\(migrated)'"
        )
        store.set(migrated, forKey: Key.menuBarChips)
    }

    /// Read the ordered chip list from the App Group store. Returns
    /// the parsed chips in the order the user persisted them. Unknown
    /// or duplicated ids are dropped silently — a future build adding
    /// chip types shouldn't break an older client that doesn't know
    /// about them.
    public static func menuBarChips() -> [MenuBarChip] {
        let raw = store.string(forKey: Key.menuBarChips) ?? ""
        var seen = Set<MenuBarChip>()
        var ordered: [MenuBarChip] = []
        for token in raw.split(separator: ",") {
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            guard let chip = MenuBarChip(rawValue: trimmed),
                  !seen.contains(chip) else { continue }
            seen.insert(chip)
            ordered.append(chip)
        }
        return ordered
    }

    /// Persist the chip list. Empty array stores `""` — read by the
    /// status item host to mean "tear down the NSStatusItem entirely."
    public static func setMenuBarChips(_ chips: [MenuBarChip]) {
        // De-dupe while preserving order.
        var seen = Set<MenuBarChip>()
        let unique = chips.filter { seen.insert($0).inserted }
        let csv = unique.map(\.rawValue).joined(separator: ",")
        store.set(csv, forKey: Key.menuBarChips)
    }

    /// One-time migration from the legacy single-Int threshold keys to
    /// the new CSV keys. We can't do this inside the defaults dict
    /// because `register(defaults:)` only kicks in when the key is
    /// completely absent — a returning user has the legacy key set
    /// and would never see the new CSV default. So: if the user
    /// already had a customized legacy threshold but no CSV yet, seed
    /// the CSV from the legacy value.
    private static func migrateLegacyThresholds() {
        for (legacy, csv, fallback) in [
            (Key.fiveHourThresholdPct, Key.fiveHourThresholdsCSV, 75),
            (Key.sevenDayThresholdPct, Key.sevenDayThresholdsCSV, 75),
        ] {
            // Persisted CSV already? Nothing to do — that's authoritative.
            if store.object(forKey: csv) is String,
               let raw = store.string(forKey: csv),
               !raw.isEmpty,
               raw != "\(fallback)" {
                continue
            }
            let legacyValue = store.integer(forKey: legacy)
            // store.integer returns 0 if absent; treat 0 as "use default"
            // so a fresh install seeds 75% rather than "no thresholds".
            let v = legacyValue > 0 ? legacyValue : fallback
            store.set("\(v)", forKey: csv)
        }
    }

    /// Read thresholds for a window. Always sorted ascending and
    /// deduped. Empty array means "user removed them all" — caller
    /// should treat that as "no notifications for this window."
    public static func thresholds(forWindow window: String) -> [Int] {
        let key: String
        switch window {
        case "five_hour": key = Key.fiveHourThresholdsCSV
        case "seven_day": key = Key.sevenDayThresholdsCSV
        default: return []
        }
        let raw = store.string(forKey: key) ?? ""
        let values = raw
            .split(separator: ",", omittingEmptySubsequences: true)
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { (1...99).contains($0) }
        return Array(Set(values)).sorted()
    }

    /// Persist thresholds for a window. Sorts ascending, dedupes,
    /// clamps to 1...99 before writing.
    public static func setThresholds(_ values: [Int], forWindow window: String) {
        let key: String
        switch window {
        case "five_hour": key = Key.fiveHourThresholdsCSV
        case "seven_day": key = Key.sevenDayThresholdsCSV
        default: return
        }
        let cleaned = Array(Set(values.filter { (1...99).contains($0) })).sorted()
        let csv = cleaned.map(String.init).joined(separator: ",")
        store.set(csv, forKey: key)
    }
}
