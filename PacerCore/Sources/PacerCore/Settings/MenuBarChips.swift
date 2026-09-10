import Foundation

/// One chip the user can place in the menu bar status item. The user picks
/// any subset and orders them via Settings → Menu bar; an empty subset hides
/// the item entirely.
///
/// Why a chip list rather than a fixed enum: the previous `MenuBarStyle`
/// (hidden / icon / percent / icon+percent) gave a 4-way choice that couldn't
/// surface today's cost, the 7-day window, or the active model — all of which
/// different users want at-a-glance. A chip list scales to any future addition
/// without bloating the picker into a 12-way enum.
///
/// Lives in PacerCore (not the App target) so the pure parse/serialize round
/// trip — including scoped-window chips, see `MenuBarChipItem` — is unit
/// testable without SwiftUI or a store. The App's `PacerSettings` re-exports
/// this as `PacerSettings.MenuBarChip` via typealias and adds the SwiftUI /
/// store-bound conveniences.
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

/// A single entry in the ordered menu-bar chip list — either a built-in
/// `MenuBarChip` or a **scoped per-model window** chip carrying that window's
/// stable `UsageLimit.identity` (e.g. `weekly_scoped|Fable|`).
///
/// ## CSV encoding & back-compat
///
/// The list persists as the `menuBarChips` CSV (unchanged String format).
/// A fixed chip is its `MenuBarChip` rawValue (`five_hour_pct`); a scoped chip
/// is `scoped_pct:<identity>` (`scoped_pct:weekly_scoped|Fable|`). So a saved
/// list reads `icon,five_hour_pct,scoped_pct:weekly_scoped|Fable|`.
///
/// The `scoped_pct:` prefix is chosen precisely so an **older** client — whose
/// parser only recognizes `MenuBarChip` rawValues and drops everything else —
/// silently skips a scoped chip it doesn't understand, rather than choking or
/// rendering a phantom. Forward-compatible for free: no new enum cases, no
/// stored-format break, no migration.
///
/// The identity is stored verbatim. Identities are `kind|model|surface`
/// (pipe-delimited) and, in every observed payload, comma-free — so they
/// coexist with the comma-separated CSV. `parseList`/`serializeList` round trip
/// exactly for any comma-free identity.
public enum MenuBarChipItem: Equatable, Hashable, Identifiable, Sendable {
    /// A built-in chip (icon / 5h% / 7d% / cost / tokens / active model).
    case fixed(MenuBarChip)
    /// A scoped per-model window chip carrying the window's stable
    /// `UsageLimit.identity`. Rendered like a fixed % chip — "<name> <pct>%" —
    /// reading the live scoped window; **dormant (skipped)** when that window
    /// isn't in the account's latest poll.
    case scoped(identity: String)
    /// One named account's window — `five_hour`, `seven_day`, or a scoped
    /// identity — regardless of which account is signed in.
    ///
    /// The menu bar is the tightest surface in the app, and with several
    /// accounts live at once there is no honest combined number: two 5-hour
    /// windows cannot be summed or averaged into a third. So rather than
    /// guessing which account to show, this lets the user say. A chip that
    /// names its account is the only version that stays true when both are
    /// burning.
    case account(accountId: String, window: String)

    /// CSV token prefix marking a scoped-window chip. See the type doc for why
    /// this exact shape keeps old clients forward-compatible.
    public static let scopedTokenPrefix = "scoped_pct:"

    /// Same forward-compat trick for account-scoped chips: an older client's
    /// parser recognizes neither prefix and skips the token rather than
    /// choking. Encoded `account_pct:<accountId>|<window>` and split at the
    /// **first** pipe only, because a scoped identity contains pipes of its
    /// own (`weekly_scoped|Fable|`) and an account id never does.
    public static let accountTokenPrefix = "account_pct:"

    /// Stable, collision-free identity (a fixed chip's rawValue can never
    /// collide with a `scoped_pct:`-prefixed token). Doubles as the CSV token.
    public var id: String { serialized }

    /// The scoped identity, or nil for a fixed chip.
    public var scopedIdentity: String? {
        if case .scoped(let identity) = self { return identity }
        return nil
    }

    /// The account this chip is pinned to, or nil when it follows the scope.
    public var pinnedAccountId: String? {
        if case .account(let id, _) = self { return id }
        return nil
    }

    /// This entry's single CSV token. Round-trips through `parse(token:)`.
    public var serialized: String {
        switch self {
        case .fixed(let chip):        return chip.rawValue
        case .scoped(let identity):   return Self.scopedTokenPrefix + identity
        case .account(let id, let w):  return "\(Self.accountTokenPrefix)\(id)|\(w)"
        }
    }

    /// Parse one CSV token into an item, or nil when it should be **skipped**:
    ///   - an empty / whitespace-only token,
    ///   - a `scoped_pct:` token with an empty identity (nothing to render),
    ///   - an unrecognized fixed id (a future build's chip, or an old default
    ///     a newer build dropped) — the forward/backward-compat skip.
    public static func parse(token raw: String) -> MenuBarChipItem? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix(accountTokenPrefix) {
            let body = trimmed.dropFirst(accountTokenPrefix.count)
            guard let pipe = body.firstIndex(of: "|") else { return nil }
            let id = String(body[body.startIndex..<pipe])
            let window = String(body[body.index(after: pipe)...])
            return id.isEmpty || window.isEmpty ? nil : .account(accountId: id, window: window)
        }
        if trimmed.hasPrefix(scopedTokenPrefix) {
            let identity = String(trimmed.dropFirst(scopedTokenPrefix.count))
            return identity.isEmpty ? nil : .scoped(identity: identity)
        }
        guard let chip = MenuBarChip(rawValue: trimmed) else { return nil }
        return .fixed(chip)
    }

    /// Parse a full `menuBarChips` CSV into an ordered, de-duplicated item
    /// list: skips unknown/empty tokens, collapses duplicates (by `id`) keeping
    /// the first occurrence, and preserves the user's order.
    public static func parseList(_ csv: String) -> [MenuBarChipItem] {
        var seen = Set<String>()
        var out: [MenuBarChipItem] = []
        for token in csv.split(separator: ",") {
            guard let item = parse(token: String(token)) else { continue }
            if seen.insert(item.id).inserted { out.append(item) }
        }
        return out
    }

    /// Serialize an ordered item list back to a `menuBarChips` CSV.
    public static func serializeList(_ items: [MenuBarChipItem]) -> String {
        items.map(\.serialized).joined(separator: ",")
    }

    /// Best-effort display name for a scoped identity when its live window
    /// isn't currently reported (so we have no `UsageLimitSample.label` to
    /// show). Recovers the model / surface component from the `kind|model|
    /// surface` identity; falls back to the raw identity if it can't. Live
    /// chips prefer the window's own `displayName` and never call this.
    public static func scopedDisplayName(fromIdentity identity: String) -> String {
        // `omittingEmptySubsequences: false` keeps positional meaning: a
        // trailing empty surface still leaves parts.count == 3.
        let parts = identity
            .split(separator: "|", omittingEmptySubsequences: false)
            .map(String.init)
        let model = parts.count > 1 ? parts[1] : ""
        let surface = parts.count > 2 ? parts[2] : ""
        switch (model.isEmpty, surface.isEmpty) {
        case (false, false): return "\(model) · \(surface)"
        case (false, true):  return model
        case (true, false):  return surface
        case (true, true):   return identity
        }
    }
}
