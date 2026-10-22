import Foundation

/// The columns of every "by model / by project / by day / by session" usage
/// list (#215).
///
/// One definition of which number each column is, shared by the table that
/// draws them (`PacerUsageTable` in PacerUI), the short list beside a donut
/// (`PacerDonutListCard`) and anything that ranks rows the way a table sorts
/// them (History's Top days, `DayRanking`). A column that read the wrong
/// `TokenBreakdown` field or cost part would be wrong on every screen at once,
/// and `UsageColumnTests` gives each field and each part a distinct value so a
/// swap fails.
///
/// Raw values are persisted as each table's sort column and as the ids of its
/// saved column layout. `name`, `tokens` and `cost` are what the per-screen
/// sort enums stored before the shared table, and `mix` is the id the Models
/// table's own Mix column had, so a sort or a layout the user picked then
/// carries over. A retired id maps to its successor (`legacyIds`).
///
/// The declaration order is not the order a table shows the columns in: that
/// is `displayOrder`, which takes the token parts' order from
/// `CostComponent`.
///
/// ## Conventions: every table and every donut list
///
/// The owner found the donut cards and the tables disagreeing about what a
/// column was called, where it sat and how it printed. These hold everywhere
/// a usage number is listed, so a screen picks columns, never their names,
/// order or formats:
///
/// - **One name per number.** "Tokens" is every token, `TokenBreakdown.all`,
///   in a table header, a donut list and a donut's centre alike (never
///   "Total"); "Cost" is the row's cost; "Share" is the row's part of a whole,
///   which in a donut list is the whole the ring measures. A token part is
///   named for what it is ("Uncached", "Cache read").
/// - **One order.** A table: the label, a screen's leading columns, the token
///   parts in the parts' order, Tokens, Hit %, Out %, Cost, the screen's own
///   columns, Mix (`displayOrder`). A donut list keeps the table's order for
///   what it has: the label, Tokens, Cost, then Share
///   (`PacerShareListColumn.standard`).
/// - **One format per kind.** A cost prints compact ("$12.3k",
///   `pacerCost`), exact in its tooltip; a token count compact ("86.0M",
///   `pacerTokens`), exact in its tooltip; a share as a whole percent ("38%",
///   "<1%"), with the amounts it divides in its tooltip; Hit % at one decimal
///   (`pacerCacheHitText`), as every hit rate prints.
/// - **"Last active", never "Last seen"**, for when a row last had usage.
///   Relative to now ("2h ago"), the exact time in its tooltip; a row known
///   only to the day (a model, from the daily rollup) prints the day relative
///   to today ("yesterday").
/// - **Six columns by default, at most.** A table opens on the label,
///   Tokens, Cost and Mix (`wideDefaults`; `narrowDefaults` leaves out Mix),
///   plus at most two columns of the screen's own (`maxDefaultColumns`).
///   Everything else is one right-click on the header away.
/// - **A donut list holds only amounts that add up**, the kind a ring can be
///   made of: cost, tokens, a token part, a screen's own count
///   (`UsageAmount`). Never a ratio: Hit % and Out % are not shares of
///   anything, so they cannot make a ring or be compared as one.
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
    /// "Hit %": the share of the row's prompt tokens served from the cache,
    /// `TokenBreakdown.cacheHitRatio` (reads ÷ (reads + writes + uncached
    /// input)), the one definition every surface prints.
    ///
    /// It replaced "Write %" (raw value "writeShare"), cache writes' share of
    /// the cache *cost*. That one turned out to be the reuse figure bent by
    /// each model's read price: the same caching read differently on Opus
    /// and on Haiku. A token ratio means the same thing on every model.
    /// "writeShare" still decodes, as this column (`init(storedId:)`).
    case cacheHitRate = "hitRate"
    /// "Out %": output's share of the row's cost. For a table too narrow for
    /// the token columns: how much of the money went on the response.
    case outputShare = "outShare"
    case cost
    /// "Mix": the five cost parts as one 100% bar. Declared after a
    /// screen's own columns, where the Models table had its Mix.
    case mix

    /// The token count this column shows, or nil for a column that is not a
    /// count (the label, the ratios, the bar, the cost).
    public func tokenCount(of tokens: TokenBreakdown) -> Int64? {
        switch self {
        case .name, .cost, .cacheHitRate, .outputShare, .mix: return nil
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
    /// nothing to divide (no cost, no prompt) or the column is not a ratio.
    /// Hit % divides tokens; Out % and the Mix bar divide the cost.
    public func ratio(of row: some UsageColumnValues) -> Double? {
        switch self {
        case .cacheHitRate: return row.tokens.cacheHitRatio
        case .outputShare:  return row.costParts.outputShare
        case .mix:          return row.costParts.uncachedShare
        default:            return nil
        }
    }

    /// Whether this column prints a ratio rather than an amount: its values
    /// do not add up across rows.
    public var isRatio: Bool {
        switch self {
        case .cacheHitRate, .outputShare, .mix: return true
        default:                                return false
        }
    }

    /// Whether this column's values add up across rows to a whole a ring
    /// can be made of: cost, Tokens, a token part. Not the label, a ratio or
    /// the Mix bar. What a donut list may show (`UsageAmount`).
    public var isAdditive: Bool { UsageAmount(self) != nil }

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
        case .cacheHitRate, .outputShare, .mix:
            switch (ratio(of: a), ratio(of: b)) {
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

    /// What a table shows until its user changes it: the label, Tokens, Cost
    /// and the Mix bar. A screen adds at most two of its own (Models' Days
    /// and Last active, Projects' Sessions and Last active), which is six;
    /// the token parts, Hit % and Out % are in the header's menu.
    ///
    /// Round 4 opened every wide table on all four token parts as well, and
    /// the owner found it too many columns to read at a glance. A table that
    /// opened that way before keeps nothing of it: its saved layout is
    /// cleared once (`PacerUsageTableMetrics.layoutDefaultsVersions`).
    public static let wideDefaults: Set<UsageColumn> = [.name, .tokens, .cost, .mix]

    /// What a table in a tight space shows: the label, Tokens and Cost. The
    /// Mix bar waits in the menu with the rest. Day detail's models (whose
    /// mix the Cost breakdown card above them draws) and the sessions lists.
    public static let narrowDefaults: Set<UsageColumn> = [.name, .tokens, .cost]

    /// The most columns a table opens on, label and the screen's own
    /// columns included (`UsageTableLayoutTests` checks every screen's).
    public static let maxDefaultColumns = 6

    /// The column showing one priced part's tokens. The two write tiers
    /// have their own columns; Cache write is both of them together.
    public init(part: CostComponent) {
        switch part {
        case .input:        self = .input
        case .output:       self = .output
        case .cacheRead:    self = .cacheRead
        case .cacheWrite5m: self = .cacheWrite5m
        case .cacheWrite1h: self = .cacheWrite1h
        }
    }

    /// The token-part columns in the order every table shows them: the
    /// parts' own order (`CostComponent.allCases`, the order every bar and
    /// breakdown draws them in), with Cache write, both tiers together, just
    /// before the first tier. Read from the parts rather than written out, so
    /// a change to the parts' order moves the columns with it.
    public static var partColumns: [UsageColumn] {
        var columns: [UsageColumn] = []
        for part in CostComponent.allCases {
            let column = UsageColumn(part: part)
            if column == .cacheWrite5m || column == .cacheWrite1h, !columns.contains(.cacheWrite) {
                columns.append(.cacheWrite)
            }
            columns.append(column)
        }
        return columns
    }

    /// Every column in the order a table lays them out: the label, the token
    /// parts, the total, the ratios (Hit % with the cache parts before Out %
    /// with output, as the parts run), the cost and the Mix bar. A screen's
    /// own columns go between Cost and Mix.
    public static var displayOrder: [UsageColumn] {
        [.name] + partColumns + [.tokens, .cacheHitRate, .outputShare, .cost, .mix]
    }

    /// Ids this enum stored before, and the column each one is now. A sort or
    /// a saved table layout naming one carries over to its successor.
    public static let legacyIds: [String: UsageColumn] = [
        // Write % (cache writes' share of the cache cost) became Hit %.
        "writeShare": .cacheHitRate,
    ]

    /// `id` as it is stored now: a retired id becomes its successor's.
    public static func migratedId(_ id: String) -> String {
        legacyIds[id]?.rawValue ?? id
    }

    /// The column a stored id names, retired ids included.
    public init?(storedId id: String) {
        self.init(rawValue: Self.migratedId(id))
    }
}

/// A usage column whose values add up across rows: the only standard
/// columns a donut list takes (`PacerShareListColumn.usage`), so no screen can
/// put a ratio beside a ring. Hit %, Out % and Mix have no case here, and a
/// list that names one does not compile.
///
/// The owner's round-5 review: Hit % and Out % "don't really make sense to
/// compare or be options in the pie chart view", where only money and
/// tokens, all of them or one part's, do. A share of a ratio is not a share
/// of anything.
public enum UsageAmount: String, CaseIterable, Sendable {
    case cost
    case tokens
    case input
    case output
    case cacheRead
    case cacheWrite
    case cacheWrite5m
    case cacheWrite1h

    /// The table column this amount is, and whose title, cell text and sort
    /// it shares.
    public var column: UsageColumn {
        switch self {
        case .cost:         return .cost
        case .tokens:       return .tokens
        case .input:        return .input
        case .output:       return .output
        case .cacheRead:    return .cacheRead
        case .cacheWrite:   return .cacheWrite
        case .cacheWrite5m: return .cacheWrite5m
        case .cacheWrite1h: return .cacheWrite1h
        }
    }

    /// The amount a table column is, or nil for one that does not add up.
    public init?(_ column: UsageColumn) {
        guard let amount = UsageAmount.allCases.first(where: { $0.column == column }) else { return nil }
        self = amount
    }
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
