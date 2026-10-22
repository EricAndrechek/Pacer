import Foundation
import SwiftData

/// Pre-computed `(projectPath, date)` rollup of `TokenSample` rows.
/// Recomputed by `ProjectAggregateRecomputer` whenever its bucket gets
/// dirtied during a scan — never by per-row triggers, never by views.
///
/// This is the project-dimensional analogue of `DailyAggregate`. It
/// exists so `ProjectsView` and `ProjectDetailView` can render from a
/// small precomputed table (a couple thousand rows on a populated
/// install) instead of iterating every TokenSample on display.
/// Without it, the Projects tab had to group ~30k samples on the main
/// thread on every scan-meta tick — which froze the UI noticeably even
/// after we moved the iteration off the main thread (the wall-clock
/// time was just hidden, not removed).
///
/// `projectDateKey == "${projectPath}|${date}"` is the unique primary
/// key. For samples missing a `projectPath` we use the literal
/// "(unknown)" path so they still get a bucket.
@Model
public final class ProjectDailyAggregate {
    // Hot predicate: views filter on `date >= cutoff` for the
    // selected time range. Without an index, SQLite scans the full
    // table on every refetch. The compound `(date, projectPath)`
    // index also helps `(date, projectPath)` lookups during the
    // aggregate recomputer's upsert path.
    #Index<ProjectDailyAggregate>([\.date], [\.date, \.projectPath])

    @Attribute(.unique) public var projectDateKey: String
    public var projectPath: String
    public var date: String   // YYYY-MM-DD, same shape as TokenSample.date
    public var inputTokens: Int64
    public var outputTokens: Int64
    public var cacheReadTokens: Int64
    public var cacheCreation5mTokens: Int64
    public var cacheCreation1hTokens: Int64
    public var totalCostUSD: Double
    /// The price-ledger tokens that priced this bucket, newline-separated
    /// and sorted (#217): when one of their keys changes price over this
    /// bucket's time, the bucket is rebuilt. See `PricedBy`.
    public var pricedByRecordIds: String = ""
    /// `totalCostUSD` split by category (#296). The total is always written
    /// as the sum of these five, so they agree by construction; see
    /// `RollupCostColumns`.
    public var costInput: Double = 0
    public var costOutput: Double = 0
    public var costCacheRead: Double = 0
    public var costCacheWrite5m: Double = 0
    public var costCacheWrite1h: Double = 0
    /// Distinct sessions that wrote into this bucket. Sessions are
    /// per-day-keyed here, so summing across days slightly overcounts a
    /// session that crossed midnight — accepted for the Projects-list
    /// "Sessions" column. ProjectDetailView consumes the JSON id list
    /// below and unions across dates to avoid the inflation.
    public var sessionCount: Int
    public var modelCount: Int
    /// Most recent sampledAt within this bucket. Reduces to "last
    /// active" with `max()` across a project's date rows.
    public var lastActive: Date
    /// JSON `[String]` of distinct session ids in this bucket. Decoded
    /// only by ProjectDetailView (small per-row cost; rows for one
    /// project ≤ ~90).
    public var sessionIdsJSON: Data
    /// The bucket split by model: every model's five token parts and the
    /// cost of each, encoded by `ProjectModelBreakdowns` and read back
    /// through `ProjectDailyReadable.modelBreakdowns`. Per model, the parts
    /// sum to this row's own columns, so a project's By model card and its
    /// header cannot disagree, and drilling in needs no raw samples.
    ///
    /// Replaced `modelTokensJSON` (input + output only) and `modelCostJSON`
    /// (a total only) under cost recompute "19". Optional so SwiftData's
    /// lightweight migration adds the column; nil reads as no models.
    public var modelBreakdownJSON: Data?

    public init(
        projectPath: String,
        date: String,
        inputTokens: Int64 = 0,
        outputTokens: Int64 = 0,
        cacheReadTokens: Int64 = 0,
        cacheCreation5mTokens: Int64 = 0,
        cacheCreation1hTokens: Int64 = 0,
        totalCostUSD: Double = 0,
        sessionCount: Int = 0,
        modelCount: Int = 0,
        lastActive: Date = .distantPast,
        sessionIdsJSON: Data = Data(),
        modelBreakdownJSON: Data? = nil
    ) {
        self.projectDateKey = Self.makeKey(projectPath: projectPath, date: date)
        self.projectPath = projectPath
        self.date = date
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreation5mTokens = cacheCreation5mTokens
        self.cacheCreation1hTokens = cacheCreation1hTokens
        self.totalCostUSD = totalCostUSD
        self.sessionCount = sessionCount
        self.modelCount = modelCount
        self.lastActive = lastActive
        self.sessionIdsJSON = sessionIdsJSON
        self.modelBreakdownJSON = modelBreakdownJSON
    }

    public static func makeKey(projectPath: String, date: String) -> String {
        "\(projectPath)|\(date)"
    }

    public static let unknownProjectPath = "(unknown)"
}
