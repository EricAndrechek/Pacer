import Foundation

/// Canonical view of a parsed JSONL line that we care about for usage
/// tracking. Models the `assistant` message shape Claude Code writes per
/// API turn. All other line types ("user", "permission-mode",
/// "file-history-snapshot", attachments, etc.) decode to nil and are
/// dropped by the parser.
///
/// Field choices match ccusage's `usageDataSchema`
/// (apps/ccusage/src/data-loader.ts:167-193) plus the cache_creation
/// 5m/1h split that ccusage doesn't currently parse — Pacer keeps that
/// breakdown because Anthropic bills the two tiers at different rates.
public struct ParsedUsageEntry: Sendable, Equatable, Hashable {
    public let timestamp: Date
    public let model: String
    public let breakdown: TokenBreakdown

    /// Stored cost from Claude Code, when present. Anthropic doesn't
    /// always populate this — old lines often lack it. ccusage's `auto`
    /// cost mode prefers this when present, computes from tokens
    /// otherwise.
    public let storedCostUSD: Double?

    /// `${messageId}:${requestId}` when both are present, nil otherwise.
    /// **The most important field for correctness.** Sessions that get
    /// resumed cause Claude Code to write new JSONL files that replay
    /// prior turns; without dedup on this composite key, totals inflate
    /// 2-3× for active users. ccusage discovered this; we mirror.
    public let dedupKey: String?

    public let sessionId: String?
    public let projectPath: String?
    public let claudeCodeVersion: String?
    public let isApiErrorMessage: Bool
}

/// The five billable token categories Anthropic prices independently:
/// input, output, cache_read, and cache_creation split into 5m / 1h
/// ephemeral tiers. Older Claude Code lines (pre-2.1.x) only emit the
/// summed `cache_creation_input_tokens`; the parser treats that as the
/// 5m tier (cheaper) so we don't over-estimate cost on legacy data.
public struct TokenBreakdown: Sendable, Equatable, Hashable {
    public var inputTokens: Int64
    public var outputTokens: Int64
    public var cacheReadTokens: Int64
    public var cacheCreation5mTokens: Int64
    public var cacheCreation1hTokens: Int64

    public init(
        inputTokens: Int64 = 0,
        outputTokens: Int64 = 0,
        cacheReadTokens: Int64 = 0,
        cacheCreation5mTokens: Int64 = 0,
        cacheCreation1hTokens: Int64 = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreation5mTokens = cacheCreation5mTokens
        self.cacheCreation1hTokens = cacheCreation1hTokens
    }

    /// Input + output. Matches ccusage's "totalTokens" semantic (cache
    /// reads/writes excluded) — useful for at-a-glance display where
    /// caching makes the headline number jump.
    public var billableInputOutput: Int64 {
        inputTokens + outputTokens
    }

    /// Sum of all five categories. The number Anthropic actually ships
    /// across the wire.
    public var totalTokens: Int64 {
        inputTokens + outputTokens + cacheReadTokens
            + cacheCreation5mTokens + cacheCreation1hTokens
    }

    public mutating func add(_ other: TokenBreakdown) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheReadTokens += other.cacheReadTokens
        cacheCreation5mTokens += other.cacheCreation5mTokens
        cacheCreation1hTokens += other.cacheCreation1hTokens
    }
}

/// On-the-wire shape of one JSONL line, decoded with full leniency:
/// every field is optional so a malformed or new-shape line decodes to
/// "type: nil, message: nil" without throwing.
struct RawJSONLine: Decodable {
    let type: String?
    let timestamp: String?
    let sessionId: String?
    let cwd: String?
    let version: String?
    let costUSD: Double?
    let requestId: String?
    let isApiErrorMessage: Bool?
    let message: RawMessage?

    struct RawMessage: Decodable {
        let id: String?
        let model: String?
        let usage: RawUsage?
    }

    struct RawUsage: Decodable {
        let input_tokens: Int64?
        let output_tokens: Int64?
        let cache_read_input_tokens: Int64?
        let cache_creation_input_tokens: Int64?
        let cache_creation: RawCacheCreation?
    }

    struct RawCacheCreation: Decodable {
        let ephemeral_5m_input_tokens: Int64?
        let ephemeral_1h_input_tokens: Int64?
    }
}
