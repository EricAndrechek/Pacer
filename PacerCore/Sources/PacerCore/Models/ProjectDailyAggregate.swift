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
    @Attribute(.unique) public var projectDateKey: String
    public var projectPath: String
    public var date: String   // YYYY-MM-DD, same shape as TokenSample.date
    public var inputTokens: Int64
    public var outputTokens: Int64
    public var cacheReadTokens: Int64
    public var cacheCreation5mTokens: Int64
    public var cacheCreation1hTokens: Int64
    public var totalCostUSD: Double
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
    /// JSON `[String: Int64]` mapping model name → total tokens
    /// (input + output + cacheRead) for this bucket. Used by
    /// ProjectDetailView's per-model donut so we don't have to fetch
    /// raw samples on drill-in.
    public var modelTokensJSON: Data
    /// JSON `[String: Double]` mapping model name → totalCostUSD.
    public var modelCostJSON: Data

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
        modelTokensJSON: Data = Data(),
        modelCostJSON: Data = Data()
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
        self.modelTokensJSON = modelTokensJSON
        self.modelCostJSON = modelCostJSON
    }

    public static func makeKey(projectPath: String, date: String) -> String {
        "\(projectPath)|\(date)"
    }

    public static let unknownProjectPath = "(unknown)"
}
