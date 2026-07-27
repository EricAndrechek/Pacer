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

    /// The menu-bar chip model lives in PacerCore so its pure parse/serialize
    /// round trip (including scoped-window chips) is unit-testable. Re-exported
    /// here so the long-standing `PacerSettings.MenuBarChip` /
    /// `PacerSettings.MenuBarChipItem` spellings keep resolving unchanged.
    ///
    /// - `MenuBarChip`      — a built-in chip (icon / 5h% / 7d% / cost /
    ///                        tokens / active model).
    /// - `MenuBarChipItem`  — one entry in the ordered list: `.fixed(chip)` or
    ///                        `.scoped(identity:)` for a per-model window chip.
    public typealias MenuBarChip = PacerCore.MenuBarChip
    public typealias MenuBarChipItem = PacerCore.MenuBarChipItem

    // MARK: - Storage keys
    //
    // Delegated to PacerCore.PacerPreferenceKeys so the in-process
    // scan code (which lives in PacerCore) can read these without
    // linking App-target code. Anything new should also live there
    // if a non-app surface needs to read it.

    public enum Key {
        public static let menuBarStyle           = PacerPreferenceKeys.menuBarStyle
        public static let menuBarIconStyle       = PacerPreferenceKeys.menuBarIconStyle
        public static let menuBarIconDriver      = PacerPreferenceKeys.menuBarIconDriver
        public static let menuBarRingWindows     = PacerPreferenceKeys.menuBarRingWindows
        public static let menuBarChips           = PacerPreferenceKeys.menuBarChips
        public static let notificationsEnabled   = PacerPreferenceKeys.notificationsEnabled
        public static let fiveHourThresholdPct   = PacerPreferenceKeys.fiveHourThresholdPct
        public static let sevenDayThresholdPct   = PacerPreferenceKeys.sevenDayThresholdPct
        public static let fiveHourThresholdsCSV  = PacerPreferenceKeys.fiveHourThresholdsCSV
        public static let sevenDayThresholdsCSV  = PacerPreferenceKeys.sevenDayThresholdsCSV
        public static let notifyOnDailyCost      = PacerPreferenceKeys.notifyOnDailyCost
        public static let dailyCostThresholdUSD  = PacerPreferenceKeys.dailyCostThresholdUSD
        public static let notifyOnReset          = PacerPreferenceKeys.notifyOnReset
        public static let notifyGlobalReset      = PacerPreferenceKeys.notifyGlobalReset
        public static let notifyBurnRate         = PacerPreferenceKeys.notifyBurnRate
        public static let notifyBurnRateRearm    = PacerPreferenceKeys.notifyBurnRateRearm
        public static let burnRateImminentMinutes = PacerPreferenceKeys.burnRateImminentMinutes
        public static let notifyDailySummary     = PacerPreferenceKeys.notifyDailySummary
        public static let dailySummaryHour       = PacerPreferenceKeys.dailySummaryHour
        public static let costMode               = PacerPreferenceKeys.costMode
        public static let timeRange              = PacerPreferenceKeys.timeRange
        public static let projectsSort           = PacerPreferenceKeys.projectsSort
        public static let oauthTokenOverride     = PacerPreferenceKeys.oauthTokenOverride
        public static let desktopCredentialsEnabled = PacerPreferenceKeys.desktopCredentialsEnabled
        public static let desktopOnboardingDismissed = PacerPreferenceKeys.desktopOnboardingDismissed
        public static let apiEnabled             = PacerPreferenceKeys.apiEnabled
        public static let apiPort                = PacerPreferenceKeys.apiPort
        public static let apiBindHost            = PacerPreferenceKeys.apiBindHost
        public static let apiToken               = PacerPreferenceKeys.apiToken
    }

    // MARK: - Defaults

    nonisolated(unsafe) public static let defaults: [String: Any] = [
        Key.menuBarStyle:          MenuBarStyle.iconAndPercent.rawValue,
        Key.menuBarIconStyle:      MenuBarIconStyle.gaugeNeedle.rawValue,
        // Explicit default: the 5-hour window paints the icon. (A legacy stored
        // "" — the old "Auto" — still resolves to 5-hour via resolveDriver.)
        Key.menuBarIconDriver:     MenuBarWindows.defaultDriverKey,
        // Activity-rings icon: the fixed 2-ring set (outer 5-hour, inner 7-day)
        // so an existing user's rings icon is unchanged. Configurable up to 3.
        Key.menuBarRingWindows:    MenuBarWindows.defaultRingWindowKeys.joined(separator: ","),
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
        // On by default: an off-schedule global reset is rare and
        // high-value (fires at most once per cycle), so anyone who's
        // enabled notifications at all should hear about it without
        // having to find this toggle. Still gated by notificationsEnabled.
        Key.notifyGlobalReset:     true,
        Key.notifyBurnRate:        false,
        Key.notifyBurnRateRearm:   true,
        Key.burnRateImminentMinutes: 60,
        Key.notifyDailySummary:    false,
        Key.dailySummaryHour:      21,
        Key.costMode:              "auto",
        Key.timeRange:             "90d",
        Key.projectsSort:          "cost",
        Key.oauthTokenOverride:    "",
        Key.desktopCredentialsEnabled: false,
        Key.desktopOnboardingDismissed: false,
        Key.apiEnabled:            false,
        Key.apiPort:               PacerPreferences.apiDefaultPort,
        Key.apiBindHost:           "127.0.0.1",
        Key.apiToken:              "",
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
    ///
    /// Fixed-only: a scoped-window chip already persisted in the CSV survives
    /// only through `setMenuBarChipItems`. `setMenuBarChips` exists for the
    /// legacy migration path (which only ever writes fixed chips).
    public static func setMenuBarChips(_ chips: [MenuBarChip]) {
        // De-dupe while preserving order.
        var seen = Set<MenuBarChip>()
        let unique = chips.filter { seen.insert($0).inserted }
        let csv = unique.map(\.rawValue).joined(separator: ",")
        store.set(csv, forKey: Key.menuBarChips)
    }

    /// Read the ordered chip list as `MenuBarChipItem`s — the full vocabulary,
    /// including scoped per-model window chips (`.scoped(identity:)`). Unknown /
    /// empty tokens are skipped and duplicates collapsed, order preserved. This
    /// is the accessor the live menu bar and the Settings configurator use;
    /// `menuBarChips()` is the fixed-only view kept for back-compat.
    public static func menuBarChipItems() -> [MenuBarChipItem] {
        MenuBarChipItem.parseList(store.string(forKey: Key.menuBarChips) ?? "")
    }

    /// Persist the full chip list (fixed + scoped). De-dupes by identity while
    /// preserving order. Empty array stores `""` (tear the status item down).
    public static func setMenuBarChipItems(_ items: [MenuBarChipItem]) {
        var seen = Set<String>()
        let unique = items.filter { seen.insert($0.id).inserted }
        store.set(MenuBarChipItem.serializeList(unique), forKey: Key.menuBarChips)
    }

    /// The ordered activity-ring window keys (outer → inner), deduped and capped
    /// at `MenuBarWindows.maxRingWindows` (3). An empty/absent value yields the
    /// default 2-ring set (5-hour + 7-day) so the rings icon is never blank.
    /// Resolution against the live window set — skipping vanished windows — is
    /// `MenuBarWindows.resolveRingWindows`.
    public static func menuBarRingWindowKeys() -> [String] {
        let raw = store.string(forKey: Key.menuBarRingWindows) ?? ""
        let keys = normalizedRingKeys(
            raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        return keys.isEmpty ? MenuBarWindows.defaultRingWindowKeys : keys
    }

    /// Persist the activity-ring window keys — deduped, empties dropped, capped
    /// at 3. Order is meaningful (outer → inner).
    public static func setMenuBarRingWindowKeys(_ keys: [String]) {
        store.set(normalizedRingKeys(keys).joined(separator: ","), forKey: Key.menuBarRingWindows)
    }

    /// Dedupe (preserving order), drop empties, cap at `maxRingWindows`.
    private static func normalizedRingKeys(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for key in keys where !key.isEmpty && seen.insert(key).inserted {
            out.append(key)
            if out.count == MenuBarWindows.maxRingWindows { break }
        }
        return out
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
