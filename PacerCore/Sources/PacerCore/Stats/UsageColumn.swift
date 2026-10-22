import Foundation

/// The columns of every "by model / by project / by day" usage list (#215).
///
/// One definition of which number each column is, shared by the table that
/// draws them (`PacerUsageTable` in PacerUI) and by anything that ranks rows
/// the way that table sorts them (History's Top days, `DayRanking`). A column
/// that read the wrong `TokenBreakdown` field would be wrong on every screen
/// at once, and `UsageColumnTests` gives each field a distinct value so a
/// swap fails.
///
/// Raw values are persisted as each table's sort column. `name`, `tokens` and
/// `cost` are what the per-screen sort enums stored before the shared table,
/// so a sort the user picked then carries over.
public enum UsageColumn: String, CaseIterable, Sendable {
    /// The row's label: a model, a project, a date.
    case name
    case input
    case output
    case cacheRead
    /// Both cache-write tiers. The 5m / 1h split is in its tooltip, and in
    /// the two columns below for anyone who shows them.
    case cacheWrite
    case cacheWrite5m
    case cacheWrite1h
    /// Every token, all five parts (`TokenBreakdown.all`), titled "Total".
    /// The raw value stays "tokens": it is what every older sort stored.
    case tokens
    case cost

    /// The token count this column shows, or nil for the label and cost.
    public func tokenCount(of tokens: TokenBreakdown) -> Int64? {
        switch self {
        case .name, .cost:  return nil
        case .input:        return tokens.inputTokens
        case .output:       return tokens.outputTokens
        case .cacheRead:    return tokens.cacheReadTokens
        case .cacheWrite:   return tokens.cacheWrite
        case .cacheWrite5m: return tokens.cacheCreation5mTokens
        case .cacheWrite1h: return tokens.cacheCreation1hTokens
        case .tokens:       return tokens.all
        }
    }

    /// The direction a first click sorts in: numbers largest first, the
    /// label A to Z.
    public var sortsDescendingFirst: Bool { self != .name }

    /// Shown until the user hides it. The two cache-write tiers start hidden:
    /// Cache write already counts both and its tooltip splits them.
    public var isVisibleByDefault: Bool {
        self != .cacheWrite5m && self != .cacheWrite1h
    }
}
