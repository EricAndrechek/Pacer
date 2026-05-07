import Foundation

/// Parses a single JSONL line into a `ParsedUsageEntry` (or nil if it
/// isn't a billable assistant turn we care about).
///
/// Defensive throughout: malformed JSON, missing fields, unknown types,
/// or `<synthetic>` model all yield nil rather than throwing. ccusage
/// uses the same pattern — a single bad line in a 10MB session
/// transcript must never break the scan, especially since the active
/// session can be mid-write when we read it.
public enum JSONLLineParser {

    /// `<synthetic>` is Claude Code's sentinel for non-billable internal
    /// messages (tool-result processing, compaction, etc). They carry a
    /// `usage` object but Anthropic doesn't bill for them, so we drop
    /// them before any aggregation. ccusage skips these in three places
    /// (data-loader.ts:381, 417, 524); we do it once at parse time.
    public static let syntheticModelSentinel = "<synthetic>"

    // ISO8601DateFormatter parsing is documented thread-safe by Apple,
    // so we mark these `nonisolated(unsafe)` rather than allocating a
    // fresh formatter per line. Hot path: ~hundreds of thousands of
    // lines on full historical scan, allocation cost matters.
    nonisolated(unsafe) private static let timestampDecoder: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let timestampDecoderNoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Parse one JSONL line into an entry or nil. Pure function — no IO.
    public static func parse(line: Data) -> ParsedUsageEntry? {
        guard !line.isEmpty,
              let raw = try? JSONDecoder().decode(RawJSONLine.self, from: line)
        else {
            return nil
        }
        return entry(from: raw)
    }

    public static func parse(line: String) -> ParsedUsageEntry? {
        guard let data = line.data(using: .utf8) else { return nil }
        return parse(line: data)
    }

    static func entry(from raw: RawJSONLine) -> ParsedUsageEntry? {
        guard raw.type == "assistant" else { return nil }
        guard let model = raw.message?.model, !model.isEmpty else { return nil }
        if model == syntheticModelSentinel { return nil }

        guard let timestampString = raw.timestamp,
              let timestamp = parseTimestamp(timestampString)
        else { return nil }

        let usage = raw.message?.usage
        let breakdown = breakdown(from: usage)

        // Per ccusage and our own correctness rule: the dedup key requires
        // BOTH messageId and requestId. If either is missing we leave it
        // nil and the dedup pass falls through, accepting the entry. This
        // matches Claude Code's older lines that may lack one or the other.
        let dedupKey: String? = {
            guard let messageId = raw.message?.id, let requestId = raw.requestId else {
                return nil
            }
            return "\(messageId):\(requestId)"
        }()

        return ParsedUsageEntry(
            timestamp: timestamp,
            model: model,
            breakdown: breakdown,
            storedCostUSD: raw.costUSD,
            dedupKey: dedupKey,
            sessionId: raw.sessionId,
            projectPath: raw.cwd.map { ProjectPathCanonicalizer.canonicalize($0) },
            claudeCodeVersion: raw.version,
            isApiErrorMessage: raw.isApiErrorMessage ?? false
        )
    }

    private static func breakdown(from usage: RawJSONLine.RawUsage?) -> TokenBreakdown {
        guard let usage else { return TokenBreakdown() }

        // Cache-creation sub-breakdown: prefer the explicit 5m/1h fields
        // when present (Claude Code began emitting them in 2.1.x). Older
        // lines only have the summed `cache_creation_input_tokens` —
        // we treat that as the 5m (cheaper) tier so we never
        // over-estimate cost on legacy data.
        let explicit5m = usage.cache_creation?.ephemeral_5m_input_tokens ?? 0
        let explicit1h = usage.cache_creation?.ephemeral_1h_input_tokens ?? 0
        let summedCacheCreation = usage.cache_creation_input_tokens ?? 0

        let cc5m: Int64
        let cc1h: Int64
        if explicit5m == 0 && explicit1h == 0 && summedCacheCreation > 0 {
            cc5m = summedCacheCreation
            cc1h = 0
        } else {
            cc5m = explicit5m
            cc1h = explicit1h
        }

        return TokenBreakdown(
            inputTokens: usage.input_tokens ?? 0,
            outputTokens: usage.output_tokens ?? 0,
            cacheReadTokens: usage.cache_read_input_tokens ?? 0,
            cacheCreation5mTokens: cc5m,
            cacheCreation1hTokens: cc1h
        )
    }

    private static func parseTimestamp(_ string: String) -> Date? {
        if let date = timestampDecoder.date(from: string) { return date }
        return timestampDecoderNoFraction.date(from: string)
    }
}
