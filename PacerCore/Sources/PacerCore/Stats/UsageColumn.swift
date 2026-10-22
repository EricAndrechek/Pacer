import Foundation

/// The columns of every "by model / by project / by day / by session" usage
/// list (#215).
///
/// One definition of which number each column is, shared by the table that
/// draws them (`PacerUsageTable` in PacerUI) and by anything that ranks rows
/// the way that table sorts them (History's Top days, `DayRanking`). A column
/// that read the wrong `TokenBreakdown` field or cost part would be wrong on
/// every screen at once, and `UsageColumnTests` gives each field and each part
/// a distinct value so a swap fails.
///
/// Raw values are persisted as each table's sort column and as the ids of its
/// saved column layout. `name`, `tokens` and `cost` are what the per-screen
/// sort enums stored before the shared table, and `mix` is the id the Models
/// table's own Mix column had, so a sort or a layout the user picked then
/// carries over.
public enum UsageColumn: String, CaseIterable, Sendable {
    /// The row's label: a model, a project, a date, a session.
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
    /// "Out %": output's share of the row's cost. For a table too narrow for
    /// the token columns: how much of the money went on the response.
    case outputShare = "outShare"
    /// "Write %": cache writes' share of the row's cache cost (reads plus
    /// writes). It moves when caches are rebuilt — a new session, an idle
    /// gap that lets the 5-minute cache expire, a compaction — which is the
    /// cache signal worth a column. The hit rate is ~98% everywhere and says
    /// nothing row to row.
    case cacheWriteShare = "writeShare"
    case cost
    /// "Mix": the five cost parts as one 100% bar. Declared after a
    /// screen's own columns, where the Models table had its Mix.
    case mix

    /// The token count this column shows, or nil for a column that is not a
    /// count (the label, the ratios, the bar, the cost).
    public func tokenCount(of tokens: TokenBreakdown) -> Int64? {
        switch self {
        case .name, .cost, .outputShare, .cacheWriteShare, .mix: return nil
        case .input:        return tokens.inputTokens
        case .output:       return tokens.outputTokens
        case .cacheRead:    return tokens.cacheReadTokens
        case .cacheWrite:   return tokens.cacheWrite
        case .cacheWrite5m: return tokens.cacheCreation5mTokens
        case .cacheWrite1h: return tokens.cacheCreation1hTokens
        case .tokens:       return tokens.all
        }
    }

    /// The share a ratio column prints, in 0...1, or nil when the row has
    /// nothing to divide (no cost, no cache cost) or the column is not a
    /// ratio.
    public func share(of cost: CostComponents) -> Double? {
        switch self {
        case .outputShare:     return cost.outputShare
        case .cacheWriteShare: return cost.cacheWriteShare
        case .mix:             return cost.uncachedShare
        default:               return nil
        }
    }

    /// `a` against `b` by this column's value, ascending, with no tiebreak.
    /// `.orderedSame` for the label: each caller orders its labels its own
    /// way (a table by its sort label, Top days by date). A ratio with no
    /// answer sorts below every answer, so a $0 row sinks rather than
    /// scattering the rest.
    public func compare(_ a: some UsageColumnValues, _ b: some UsageColumnValues) -> ComparisonResult {
        switch self {
        case .name:
            return .orderedSame
        case .cost:
            return Self.order(a.cost, b.cost)
        case .outputShare, .cacheWriteShare, .mix:
            switch (share(of: a.costParts), share(of: b.costParts)) {
            case let (x?, y?): return Self.order(x, y)
            case (nil, nil):   return .orderedSame
            case (nil, _):     return .orderedAscending
            case (_, nil):     return .orderedDescending
            }
        default:
            let l: Int64 = tokenCount(of: a.tokens) ?? 0
            let r: Int64 = tokenCount(of: b.tokens) ?? 0
            return Self.order(l, r)
        }
    }

    static func order<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }

    /// The direction a first click sorts in: numbers largest first, the
    /// label A to Z.
    public var sortsDescendingFirst: Bool { self != .name }

    /// What a wide table shows until its user changes it: every token part
    /// (the two write tiers folded into Cache write, whose tooltip splits
    /// them), the total and the cost. Models, Projects, Top days, Day
    /// detail's projects.
    public static let wideDefaults: Set<UsageColumn> = [
        .name, .input, .output, .cacheRead, .cacheWrite, .tokens, .cost,
    ]

    /// What a table too narrow for the token columns shows: the total, the
    /// two ratios and the cost. The token columns stay one right-click away.
    /// Today by model beside its donut, Day detail's models.
    public static let narrowDefaults: Set<UsageColumn> = [
        .name, .tokens, .outputShare, .cacheWriteShare, .cost,
    ]
}

/// What a usage column reads from a row: a table row, a Top days total.
public protocol UsageColumnValues {
    var tokens: TokenBreakdown { get }
    /// The row's total cost, as the rest of the page prints it.
    var cost: Double { get }
    /// That cost by priced part. The parts sum to the total on every rollup
    /// row by construction (`RollupCostColumns`).
    var costParts: CostComponents { get }
}

public extension CostComponents {
    /// Output's share of the cost (the "Out %" column), or nil when nothing
    /// was spent. A part is never counted below zero: the only way one gets
    /// there is float residue from apportioning a stored cost.
    var outputShare: Double? {
        Self.share(output, of: Self.clamped(input, output, cacheRead, cacheWrite5m, cacheWrite1h))
    }

    /// Cache writes' share of what the cache cost: (5m + 1h writes) ÷
    /// (reads + 5m + 1h writes). The "Write %" column; nil when the row
    /// spent nothing on the cache.
    var cacheWriteShare: Double? {
        Self.share(max(0, cacheWrite5m) + max(0, cacheWrite1h),
                   of: Self.clamped(cacheRead, cacheWrite5m, cacheWrite1h))
    }

    /// Input and output's share of the cost: where a Mix bar's cache part
    /// starts, which is what the Mix column sorts by (most uncached first).
    var uncachedShare: Double? {
        Self.share(max(0, input) + max(0, output),
                   of: Self.clamped(input, output, cacheRead, cacheWrite5m, cacheWrite1h))
    }

    private static func clamped(_ parts: Double...) -> Double {
        parts.reduce(0) { $0 + max(0, $1) }
    }

    private static func share(_ part: Double, of whole: Double) -> Double? {
        whole > 0 ? max(0, part) / whole : nil
    }
}
