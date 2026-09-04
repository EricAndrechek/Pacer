import Foundation

/// Which usage an engine instance is fitted to.
///
/// The engine learns one series: hour-of-day and weekday profiles, per-cut
/// model pools, conformal bands, a self-evaluation scoreboard. With two
/// accounts on one machine that series is a blend of two habits, and every
/// number it produces silently describes both — which is fine under "all
/// accounts" and wrong under a per-account view.
///
/// So the engine takes a scope and there is one instance per scope. That is
/// affordable because a refit reads pre-aggregated rows and is closed-form:
/// ~1.1 s per scope per five-minute cycle, and only for scopes something is
/// actually looking at.
///
/// **`.allAccounts` must stay byte-identical.** It reads the same global
/// rollups it always did, writes the same unsuffixed surface ids, and keeps
/// the same snapshot key — so the golden fixtures, the accumulated
/// scoreboard and every existing persisted row carry over untouched. A
/// per-account scope is purely additive: new rows under new surface ids.
public enum EngineScope: Hashable, Sendable {
    case allAccounts
    case account(String)

    /// nil for `.allAccounts`.
    public var accountId: String? {
        if case .account(let id) = self { return id }
        return nil
    }

    public var isAllAccounts: Bool { accountId == nil }

    /// Appended to persisted surface ids and meta keys. Empty for
    /// `.allAccounts` — that is what keeps existing data valid.
    ///
    /// `#` because no surface id or scoped-window identity uses one:
    /// surfaces are `eod` / `rl-<key>` and window identities are
    /// `kind|model|surface`. Stripping matches the whole suffix rather than
    /// searching for the separator, so even a future identity containing one
    /// cannot confuse it.
    public var suffix: String {
        guard let accountId else { return "" }
        return "#\(accountId)"
    }

    /// A persisted id for this scope.
    public func qualify(_ base: String) -> String { base + suffix }

    /// The base id back, or nil when the persisted id belongs to a different
    /// scope. `.allAccounts` claims exactly the ids with no suffix, so a
    /// scoped row can never be read as a global one.
    public func unqualify(_ persisted: String) -> String? {
        guard !suffix.isEmpty else {
            return persisted.contains("#") ? nil : persisted
        }
        guard persisted.hasSuffix(suffix) else { return nil }
        return String(persisted.dropLast(suffix.count))
    }

    /// A stable key for dictionaries and log lines.
    public var key: String { accountId ?? "all" }
}
