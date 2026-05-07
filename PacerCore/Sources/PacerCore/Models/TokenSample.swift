import Foundation
import SwiftData

/// One billable assistant turn observed in a Claude Code JSONL transcript.
/// Append-only: the scan layer enforces dedup against `dedupKey` before
/// inserting (we keep an in-memory Set populated at scan startup) so the
/// table grows by exactly one row per real turn even across re-scans of
/// the same files.
///
/// Why no `@Attribute(.unique)` on `dedupKey`: many entries lack
/// `messageId` and/or `requestId`, so the key is `nil` for them. SwiftData
/// uniqueness can't tell "many legitimate nils" apart from "duplicates,"
/// so we enforce the constraint in `SamplePersister` instead. ccusage
/// makes the same trade — its `processedHashes` Set is the only guard
/// (`apps/ccusage/src/data-loader.ts:530-540`).
@Model
public final class TokenSample {
    public var sampledAt: Date
    /// `YYYY-MM-DD` in the user's local timezone at the moment the entry
    /// was written. Pre-formatted so daily aggregation is a string-equality
    /// group-by — matches ccusage's `formatDate(..., DEFAULT_LOCALE)`
    /// at `data-loader.ts:824` (DEFAULT_LOCALE is `en-CA` precisely
    /// because it serializes as YYYY-MM-DD; see `_consts.ts:130`).
    public var date: String
    public var model: String
    public var inputTokens: Int64
    public var outputTokens: Int64
    public var cacheReadTokens: Int64
    /// 5-minute and 1-hour ephemeral cache-creation tiers, kept separate
    /// because Anthropic prices them at different rates. ccusage
    /// flattens these into a single `cache_creation_input_tokens` field
    /// (`data-loader.ts:176`); we keep the split. Older Claude Code
    /// lines that only emit the flat sum land entirely in `5m` (cheaper
    /// tier — never over-estimate).
    public var cacheCreation5mTokens: Int64
    public var cacheCreation1hTokens: Int64
    /// Claude Code's `costUSD` if the JSONL line carried one. Anthropic
    /// doesn't always populate it (older entries lack it entirely),
    /// which is why `CostMode.auto` exists as a hybrid path.
    public var sourceCostUSD: Double?
    /// `${messageId}:${requestId}` when both are present. The
    /// single-most-important correctness field: resumed sessions spawn
    /// new JSONL files that replay prior turns, and without this guard
    /// daily costs inflate 2–3× for active users.
    public var dedupKey: String?
    public var sessionId: String?
    public var projectPath: String?
    public var ccVersion: String?

    public init(
        sampledAt: Date,
        date: String,
        model: String,
        inputTokens: Int64,
        outputTokens: Int64,
        cacheReadTokens: Int64,
        cacheCreation5mTokens: Int64,
        cacheCreation1hTokens: Int64,
        sourceCostUSD: Double? = nil,
        dedupKey: String? = nil,
        sessionId: String? = nil,
        projectPath: String? = nil,
        ccVersion: String? = nil
    ) {
        self.sampledAt = sampledAt
        self.date = date
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreation5mTokens = cacheCreation5mTokens
        self.cacheCreation1hTokens = cacheCreation1hTokens
        self.sourceCostUSD = sourceCostUSD
        self.dedupKey = dedupKey
        self.sessionId = sessionId
        self.projectPath = projectPath
        self.ccVersion = ccVersion
    }
}

extension TokenSample {
    /// Shared YYYY-MM-DD formatter pinned to the user's current
    /// timezone. en_US_POSIX so output is locale-deterministic — same
    /// reason ccusage pins to en-CA at `_consts.ts:130`. Apple
    /// documents `DateFormatter.string(from:)` as thread-safe so long
    /// as the formatter isn't being mutated; we never mutate after
    /// init, so a single shared instance is fine and avoids the
    /// per-call allocation cost that matters during a 500K-row full
    /// historical scan.
    private static let sharedDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public static func formatDate(_ instant: Date) -> String {
        sharedDateFormatter.string(from: instant)
    }

    /// Override-timezone form, used by tests and the eventual
    /// `--timezone` setting. Allocates a one-shot formatter when the
    /// TZ doesn't match the cached one — acceptable, this is not the
    /// hot path.
    public static func formatDate(_ instant: Date, timeZone: TimeZone) -> String {
        if timeZone == .current {
            return sharedDateFormatter.string(from: instant)
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: instant)
    }

    /// Construct from a parsed JSONL entry. The local-date string is
    /// pre-computed here so we don't pay the formatter cost on every
    /// daily-rollup query.
    public convenience init(from entry: ParsedUsageEntry) {
        self.init(
            sampledAt: entry.timestamp,
            date: TokenSample.formatDate(entry.timestamp),
            model: entry.model,
            inputTokens: entry.breakdown.inputTokens,
            outputTokens: entry.breakdown.outputTokens,
            cacheReadTokens: entry.breakdown.cacheReadTokens,
            cacheCreation5mTokens: entry.breakdown.cacheCreation5mTokens,
            cacheCreation1hTokens: entry.breakdown.cacheCreation1hTokens,
            sourceCostUSD: entry.storedCostUSD,
            dedupKey: entry.dedupKey,
            sessionId: entry.sessionId,
            projectPath: entry.projectPath,
            ccVersion: entry.claudeCodeVersion
        )
    }
}
