import Foundation

/// Cost / token / model / path formatters. Shared across the
/// dashboard, MenuBarExtra, and widgets so the same number renders the
/// same way wherever it appears.

// MARK: - Money

/// Cost formatting used across every view that shows USD. Adaptive:
/// small values keep cents, big values drop them.
///   - `>=10000` → `"$12340"`
///   - `>=1000`  → `"$1.2k"`
///   - `>=100`   → `"$340"`
///   - `>=10`    → `"$42.5"`
///   - else      → `"$0.42"`
public func pacerCost(_ usd: Double) -> String {
    if usd >= 10_000 { return String(format: "$%.0f", usd) }
    if usd >= 1_000  { return String(format: "$%.1fk", usd / 1000) }
    if usd >= 100    { return String(format: "$%.0f", usd) }
    if usd >= 10     { return String(format: "$%.1f", usd) }
    return String(format: "$%.2f", usd)
}

// MARK: - Tokens

/// Token counts shown the same way ccusage's CLI shows them: K / M /
/// B suffixes. Keeps the dashboard readable when a big day's input
/// alone is several million tokens.
public func pacerTokens(_ count: Int64) -> String {
    let n = Double(count)
    switch n {
    case 1_000_000_000_000...: return String(format: "%.2fT", n / 1_000_000_000_000)
    case 1_000_000_000...:     return String(format: "%.2fB", n / 1_000_000_000)
    case 1_000_000...:         return String(format: "%.2fM", n / 1_000_000)
    case 10_000...:            return String(format: "%.1fK", n / 1_000)
    case 1_000...:             return String(format: "%.2fK", n / 1_000)
    default:                   return "\(count)"
    }
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
