import Foundation

/// Cost / token / model / path formatters. Shared across the
/// dashboard, MenuBarExtra, and widgets so the same number renders the
/// same way wherever it appears.
///
/// **Compact vs exact.** Every cost/token formatter comes in two
/// flavors:
///
///   - `pacerCost(_:)` / `pacerTokens(_:)` — **compact** form ("$10.8k",
///     "1.2M"). Three significant figures, K/M/B suffixes. Used on
///     summary surfaces where space is tight: hero tiles, chart axis
///     labels, menu bar chips, widget headlines, card trailing chips.
///     Pair with `.help(pacerCostExact(v))` on hover so the exact
///     number is one tooltip away.
///   - `pacerCostExact(_:)` / `pacerTokensExact(_:)` — **exact**,
///     locale-grouped ("$10,770.42", "10,770"). Used in tables, modal
///     detail rows, hover tooltips, CSV exports — anywhere the user
///     is reading individual values rather than scanning a summary.
///
/// Pick by *role of the surface*, not by *magnitude of the value*.
/// A heatmap caption uses compact even when the day's total is $4.20;
/// a sessions table row uses exact even when the cost is $0.03. That
/// way the layout stays predictable and adding a 10× day doesn't
/// suddenly break a card.
///
/// **Currency localization.** All cost rendering routes through
/// `pacerDisplayCurrencyCode` + `pacerCurrencySymbol(for:)` so adding
/// a Settings → Display Currency picker (with FX conversion) is a
/// single thread to pull: convert USD → target currency once at the
/// top of `pacerCost` / `pacerCostExact`, and the symbol resolves
/// from the active code. Today both helpers return USD / "$" and
/// values pass through untouched.

// MARK: - Currency configuration

/// The currency Pacer renders amounts in. Single source of truth so
/// every formatter, widget, and chart axis agrees. Today this returns
/// USD; a future Settings → Display Currency picker can swap this for
/// a stored preference without rewriting every call site.
public var pacerDisplayCurrencyCode: String { "USD" }

/// Symbol for the given ISO 4217 currency code. Small hand-rolled
/// table for the codes Pacer is likely to need; falls back to "$" so
/// an unknown code never crashes the UI. When we add a real picker
/// this should defer to `Locale.current.localizedString(forCurrencyCode:)`
/// for the user's locale.
public func pacerCurrencySymbol(for code: String) -> String {
    switch code {
    case "USD": return "$"
    case "EUR": return "€"
    case "GBP": return "£"
    case "JPY": return "¥"
    case "CAD": return "CA$"
    case "AUD": return "A$"
    default:    return "$"
    }
}

// MARK: - Money

/// Compact cost for summary surfaces (hero tiles, chart axes, menu
/// bar, widgets, card chips). Three significant figures with K / M /
/// B suffixes — `$10.8k`, `$1.23M` — so the value never wraps in a
/// narrow column and reads at a glance.
///
/// The previous implementation kept full digits at $10,000+, which is
/// where the LazyVGrid hero column started to lose. Always-compact is
/// the only shape that survives Lifetime + 5-digit costs in the same
/// layout. Pair with `.help(pacerCostExact(v))` wherever the precise
/// number matters — see `MetricTile` usages in MonthOutlookCard /
/// LifetimeSummary for the canonical pattern.
public func pacerCost(_ usd: Double) -> String {
    let symbol = pacerCurrencySymbol(for: pacerDisplayCurrencyCode)
    // Future hook: convert USD → display currency here once FX rates
    // land. For now `value` is the USD value directly.
    let value = usd
    let absV = abs(value)

    // Negative-magnitude case is unusual for cost (refund / adjustment)
    // but we keep the symbol leading the minus so the formatter behaves
    // like the system currency formatter: "-$1.23".
    let sign = value < 0 ? "-" : ""
    let n = absV

    switch n {
    case ..<0.005:
        return "\(sign)\(symbol)0"
    case ..<10:
        return String(format: "\(sign)\(symbol)%.2f", n)
    case ..<100:
        return String(format: "\(sign)\(symbol)%.1f", n)
    case ..<1_000:
        return String(format: "\(sign)\(symbol)%.0f", n)
    case ..<100_000:
        return String(format: "\(sign)\(symbol)%.1fk", n / 1_000)
    case ..<1_000_000:
        return String(format: "\(sign)\(symbol)%.0fk", n / 1_000)
    case ..<100_000_000:
        return String(format: "\(sign)\(symbol)%.1fM", n / 1_000_000)
    case ..<1_000_000_000:
        return String(format: "\(sign)\(symbol)%.0fM", n / 1_000_000)
    case ..<100_000_000_000:
        return String(format: "\(sign)\(symbol)%.1fB", n / 1_000_000_000)
    default:
        return String(format: "\(sign)\(symbol)%.0fB", n / 1_000_000_000)
    }
}

/// Exact cost with locale-grouped digits, two decimals, the active
/// currency code's symbol — "$10,770.42", "€1.234.567,89", etc.
/// Used in surfaces where the value IS the data: tables, modal rows,
/// hover tooltips, CSV exports.
public func pacerCostExact(_ usd: Double) -> String {
    let value = usd  // future hook: convert USD → display currency
    return Decimal(value).formatted(.currency(code: pacerDisplayCurrencyCode))
}

// MARK: - Tokens

/// Compact token count, same three-sig-fig K/M/B/T shape as
/// `pacerCost`. Kept in lockstep so a "$10.8k cost / 12.3M tokens"
/// row reads consistently.
public func pacerTokens(_ count: Int64) -> String {
    let n = Double(count)
    let absN = abs(n)
    let sign = n < 0 ? "-" : ""

    switch absN {
    case ..<1_000:
        return "\(sign)\(Int64(absN))"
    case ..<100_000:
        return String(format: "\(sign)%.1fK", absN / 1_000)
    case ..<1_000_000:
        return String(format: "\(sign)%.0fK", absN / 1_000)
    case ..<100_000_000:
        return String(format: "\(sign)%.1fM", absN / 1_000_000)
    case ..<1_000_000_000:
        return String(format: "\(sign)%.0fM", absN / 1_000_000)
    case ..<100_000_000_000:
        return String(format: "\(sign)%.1fB", absN / 1_000_000_000)
    case ..<1_000_000_000_000:
        return String(format: "\(sign)%.0fB", absN / 1_000_000_000)
    case ..<100_000_000_000_000:
        return String(format: "\(sign)%.1fT", absN / 1_000_000_000_000)
    default:
        return String(format: "\(sign)%.0fT", absN / 1_000_000_000_000)
    }
}

/// Exact token count with locale-grouped digits — "10,770",
/// "1,234,567". For tables, tooltips, CSV.
public func pacerTokensExact(_ count: Int64) -> String {
    count.formatted(.number)
}

// MARK: - Bytes

/// Human-readable on-disk size that matches what Finder shows ("97 MB",
/// "1.1 GB"). Uses `ByteCountFormatter` with the `.file` count style —
/// macOS's decimal (1000-based) convention — so Pacer's storage figures
/// line up with what the user sees in Finder rather than diverging by
/// the binary-vs-decimal factor. Negative inputs clamp to 0.
public func pacerBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: max(0, bytes))
}

// MARK: - Strings

/// Strip provider prefixes like `anthropic/` so model labels stay tight.
public func pacerShortModel(_ name: String) -> String {
    if let lastSlash = name.lastIndex(of: "/") {
        return String(name[name.index(after: lastSlash)...])
    }
    return name
}

/// Last path component for project paths. Special-cases the literal
/// `(unknown)` sentinel that `ProjectDailyAggregate.unknownProjectPath`
/// uses for samples missing a project path.
public func pacerShortPath(_ path: String) -> String {
    if path == "(unknown)" { return path }
    let last = (path as NSString).lastPathComponent
    return last.isEmpty ? path : last
}
