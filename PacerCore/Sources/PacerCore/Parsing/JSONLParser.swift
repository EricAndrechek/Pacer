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

    /// Hoisted to avoid one `JSONDecoder()` allocation per JSONL line —
    /// on a full historical re-scan that's hundreds of thousands of
    /// fewer allocations. `JSONDecoder` is `Sendable`, so no
    /// `nonisolated(unsafe)` is needed. Settings are left at defaults;
    /// if a future change needs `dateDecodingStrategy` or
    /// `keyDecodingStrategy`, set them inside this initializer (before
    /// any decode call) — never mutate the shared instance from a parse
    /// path.
    private static let decoder = JSONDecoder()

    /// Parse one JSONL line into the billable entries it holds — one per
    /// model call (`usage.iterations`, #218), usually exactly one. Pure, no IO.
    public static func parseAll(
        line: Data,
        aliases: [String: String] = [:],
        rootPath: String? = nil,
        fixedProjectPath: String? = nil
    ) -> [ParsedUsageEntry] {
        guard !line.isEmpty,
              let raw = try? decoder.decode(RawJSONLine.self, from: line),
              let entry = entry(from: raw, aliases: aliases, rootPath: rootPath,
                                fixedProjectPath: fixedProjectPath)
        else { return [] }
        return expand(entry, iterations: raw.message?.usage?.iterations)
    }

    /// Parse one JSONL line into its final entry, or nil. Pure function — no
    /// IO. For a multi-iteration response that is the last model call; the
    /// scanner uses `parseAll` and records every one.
    ///
    /// `aliases` is the user-defined project-path remap consulted by
    /// `ProjectPathCanonicalizer.canonicalize(_:aliases:)` after the
    /// worktree-stripping pass. Pass `[:]` (the default) for "no user
    /// aliases" — the worktree-strip behaviour is still applied.
    /// `fixedProjectPath`, when set, is the project the turn is counted as
    /// instead of its `cwd` (`ResolvedRoot.fixedProjectPath`); the raw `cwd`
    /// is still kept as `originalProjectPath`.
    public static func parse(
        line: Data,
        aliases: [String: String] = [:],
        rootPath: String? = nil,
        fixedProjectPath: String? = nil
    ) -> ParsedUsageEntry? {
        parseAll(line: line, aliases: aliases, rootPath: rootPath,
                 fixedProjectPath: fixedProjectPath).last
    }

    public static func parse(
        line: String,
        aliases: [String: String] = [:],
        rootPath: String? = nil,
        fixedProjectPath: String? = nil
    ) -> ParsedUsageEntry? {
        guard let data = line.data(using: .utf8) else { return nil }
        return parse(line: data, aliases: aliases, rootPath: rootPath,
                     fixedProjectPath: fixedProjectPath)
    }

    static func entry(
        from raw: RawJSONLine,
        aliases: [String: String] = [:],
        rootPath: String? = nil,
        fixedProjectPath: String? = nil
    ) -> ParsedUsageEntry? {
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
            projectPath: (fixedProjectPath ?? raw.cwd)
                .map { ProjectPathCanonicalizer.canonicalize($0, aliases: aliases) },
            // Preserve the raw `cwd` for the sub-path drill-down. Even
            // if the canonical path collapses many subdirs into one
            // git-repo root, the original is still the source of truth
            // about WHERE inside that repo a session ran.
            originalProjectPath: raw.cwd,
            claudeCodeVersion: raw.version,
            rootPath: rootPath,
            entrypoint: raw.entrypoint,
            isApiErrorMessage: raw.isApiErrorMessage ?? false,
            // A finished message carries a stop_reason; a mid-stream
            // snapshot of it doesn't. See `ParsedUsageEntry.isComplete`.
            isComplete: raw.message?.stop_reason != nil,
            speed: usage?.speed,
            inferenceGeo: usage?.inference_geo
        )
    }

    /// One entry per iteration of a multi-iteration response (#218).
    ///
    /// A response can be more than one model call: a `message` attempt on
    /// one model that falls back to a `fallback_message` on another, say. The
    /// top-level usage describes only the final call — and on a real corpus
    /// mixed its fields, taking `cache_creation`'s split from the first call
    /// and `cache_creation_input_tokens` from the second — so the first
    /// call's tokens silently vanished, on the more expensive model. Each
    /// iteration becomes its own entry, priced on its own model with its own
    /// counts and its own cache-write split.
    ///
    /// The final iteration keeps the line's dedup key; earlier ones get
    /// `<key>#<index>`, so every iteration is unique and every streamed copy
    /// of the same response maps its iterations onto the same keys —
    /// `supersedes` (correctness rule 7) then works per iteration, unchanged.
    /// A single-iteration (or iteration-less) line is returned as is.
    static func expand(
        _ base: ParsedUsageEntry, iterations: [RawJSONLine.RawIteration]?
    ) -> [ParsedUsageEntry] {
        guard let iterations, iterations.count > 1 else { return [base] }
        var out: [ParsedUsageEntry] = []
        for (index, it) in iterations.enumerated() {
            let model = it.model.flatMap { $0.isEmpty ? nil : $0 } ?? base.model
            if model == syntheticModelSentinel { continue }
            let isLast = index == iterations.count - 1
            out.append(ParsedUsageEntry(
                timestamp: base.timestamp,
                model: model,
                breakdown: breakdown(
                    input: it.input_tokens, output: it.output_tokens,
                    cacheRead: it.cache_read_input_tokens,
                    summedCacheCreation: it.cache_creation_input_tokens,
                    split: it.cache_creation),
                // Claude Code's stored cost covers the response as a whole;
                // it stays with the final call rather than being counted twice.
                storedCostUSD: isLast ? base.storedCostUSD : nil,
                dedupKey: base.dedupKey.map { isLast ? $0 : "\($0)#\(index)" },
                sessionId: base.sessionId,
                projectPath: base.projectPath,
                originalProjectPath: base.originalProjectPath,
                claudeCodeVersion: base.claudeCodeVersion,
                rootPath: base.rootPath,
                entrypoint: base.entrypoint,
                isApiErrorMessage: base.isApiErrorMessage,
                isComplete: base.isComplete,
                speed: base.speed,
                inferenceGeo: base.inferenceGeo,
                isIterationPart: true))
        }
        return out.isEmpty ? [base] : out
    }

    /// `expand` for an importer holding the iterations as raw JSON (the
    /// DuckDB bulk path), so both ingest paths split responses identically.
    public static func expand(_ base: ParsedUsageEntry, iterationsJSON: String?) -> [ParsedUsageEntry] {
        guard let iterationsJSON, let data = iterationsJSON.data(using: .utf8),
              let list = try? decoder.decode(RawJSONLine.LenientList<RawJSONLine.RawIteration>.self,
                                             from: data)
        else { return [base] }
        return expand(base, iterations: list.items)
    }

    private static func breakdown(from usage: RawJSONLine.RawUsage?) -> TokenBreakdown {
        guard let usage else { return TokenBreakdown() }
        return breakdown(
            input: usage.input_tokens, output: usage.output_tokens,
            cacheRead: usage.cache_read_input_tokens,
            summedCacheCreation: usage.cache_creation_input_tokens,
            split: usage.cache_creation)
    }

    private static func breakdown(
        input: Int64?, output: Int64?, cacheRead: Int64?,
        summedCacheCreation summed: Int64?, split: RawJSONLine.RawCacheCreation?
    ) -> TokenBreakdown {
        // Cache-creation sub-breakdown: prefer the explicit 5m/1h fields
        // when present (Claude Code began emitting them in 2.1.x). Older
        // lines only have the summed `cache_creation_input_tokens` —
        // we treat that as the 5m (cheaper) tier so we never
        // over-estimate cost on legacy data.
        let explicit5m = split?.ephemeral_5m_input_tokens ?? 0
        let explicit1h = split?.ephemeral_1h_input_tokens ?? 0
        let summedCacheCreation = summed ?? 0

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
            inputTokens: input ?? 0,
            outputTokens: output ?? 0,
            cacheReadTokens: cacheRead ?? 0,
            cacheCreation5mTokens: cc5m,
            cacheCreation1hTokens: cc1h
        )
    }

    private static func parseTimestamp(_ string: String) -> Date? {
        if let date = timestampDecoder.date(from: string) { return date }
        return timestampDecoderNoFraction.date(from: string)
    }

    /// Same timestamp handling for the bulk importer, which gets its fields
    /// from DuckDB rather than from `JSONDecoder` but must interpret them
    /// identically — including the with/without-fractional-seconds fallback.
    /// Exposed rather than duplicated so the two ingest paths can't drift on
    /// something as easy to get subtly wrong as date parsing.
    public static func parseTimestampForImport(_ string: String) -> Date? {
        parseTimestamp(string)
    }
}
