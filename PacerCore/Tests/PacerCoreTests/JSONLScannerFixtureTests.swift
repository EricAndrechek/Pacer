import Foundation
import Testing
@testable import PacerCore

/// Deterministic scanner ground truth.
///
/// `CCusageGroundTruthTests` compares a *live* scan of the developer's
/// real `~/.claude` against a frozen `ccusage` snapshot. That's a useful
/// parity check, but it's inherently fragile: Claude Code prunes/rewrites
/// old session files over time, so a months-old snapshot drifts away from
/// what's currently on disk and the comparison breaks even though Pacer
/// is correct (Pacer's own DB retains the original numbers; the snapshot
/// and the live files are what move). Those tests are now opt-in.
///
/// This test stands in as the *always-on* correctness gate: it writes a
/// small synthetic Claude Code `projects/` tree to a temp directory with
/// hand-computed token totals, then asserts the scanner reproduces them
/// exactly. No live data, no external tool, immune to log pruning — it
/// pins the parser's accept/drop rules, cross-file dedup, the 5m/1h
/// cache-creation split, and the legacy summed-cache fallback.
///
/// If you change `JSONLLineParser` / `JSONLScanner` and this breaks, the
/// scanner's behavior changed — update the expected numbers deliberately.

// MARK: - Fixture

/// One synthetic `assistant` line. Emits the exact JSON shape Claude Code
/// writes, with explicit 5m/1h cache fields.
private func assistantLine(
    timestamp: String,
    messageId: String,
    requestId: String,
    model: String,
    input: Int64,
    output: Int64,
    cacheRead: Int64 = 0,
    cache5m: Int64 = 0,
    cache1h: Int64 = 0
) -> String {
    """
    {"type":"assistant","timestamp":"\(timestamp)","requestId":"\(requestId)","cwd":"/tmp/pacer-fixture/proj","message":{"id":"\(messageId)","model":"\(model)","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":\(cacheRead),"cache_creation":{"ephemeral_5m_input_tokens":\(cache5m),"ephemeral_1h_input_tokens":\(cache1h)}}}}
    """
}

/// An older-format `assistant` line that only carries the summed
/// `cache_creation_input_tokens` (no 5m/1h split). The parser must treat
/// the whole sum as the 5m tier.
private func legacyCacheLine(
    timestamp: String,
    messageId: String,
    requestId: String,
    model: String,
    input: Int64,
    output: Int64,
    cacheRead: Int64,
    summedCacheCreation: Int64
) -> String {
    """
    {"type":"assistant","timestamp":"\(timestamp)","requestId":"\(requestId)","message":{"id":"\(messageId)","model":"\(model)","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":\(cacheRead),"cache_creation_input_tokens":\(summedCacheCreation)}}}
    """
}

private let opus = "claude-opus-4-20250514"
private let sonnet = "claude-sonnet-4-20250514"

/// Write a synthetic `projects/` tree to a fresh temp dir and return a
/// `ResolvedRoot` the scanner can walk. Two session files so cross-file
/// dedup is exercised (a resumed session replays a prior turn into a new
/// file).
private func makeFixtureRoot() throws -> (root: ClaudePathResolver.ResolvedRoot, cleanup: () -> Void) {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("pacer-scanner-fixture-\(UUID().uuidString)")
    let projects = base.appendingPathComponent("projects")
    let proj = projects.appendingPathComponent("-tmp-pacer-fixture-proj")
    try fm.createDirectory(at: proj, withIntermediateDirectories: true)

    // session1: three counted turns on 2026-03-01 (two opus, one sonnet),
    // plus two lines that MUST be dropped (a <synthetic> turn and a
    // non-assistant "user" line).
    let session1 = [
        assistantLine(timestamp: "2026-03-01T12:00:00.000Z", messageId: "msg1", requestId: "req1",
                      model: opus, input: 100, output: 200, cacheRead: 1000, cache5m: 50, cache1h: 10),
        legacyCacheLine(timestamp: "2026-03-01T13:00:00.000Z", messageId: "msg2", requestId: "req2",
                        model: opus, input: 5, output: 7, cacheRead: 3, summedCacheCreation: 40),
        assistantLine(timestamp: "2026-03-01T14:00:00.000Z", messageId: "msg3", requestId: "req3",
                      model: sonnet, input: 20, output: 30),
        // Dropped: <synthetic> sentinel model.
        assistantLine(timestamp: "2026-03-01T15:00:00.000Z", messageId: "msgS", requestId: "reqS",
                      model: JSONLLineParser.syntheticModelSentinel, input: 9999, output: 9999),
        // Dropped: not an assistant turn.
        #"{"type":"user","timestamp":"2026-03-01T16:00:00.000Z","message":{"role":"user"}}"#,
    ].joined(separator: "\n") + "\n"

    // session2: a replay of msg1:req1 (MUST be deduped away) plus one new
    // turn on 2026-03-02.
    let session2 = [
        assistantLine(timestamp: "2026-03-01T12:00:00.000Z", messageId: "msg1", requestId: "req1",
                      model: opus, input: 100, output: 200, cacheRead: 1000, cache5m: 50, cache1h: 10),
        assistantLine(timestamp: "2026-03-02T12:00:00.000Z", messageId: "msg4", requestId: "req4",
                      model: opus, input: 1, output: 2, cacheRead: 3, cache5m: 4, cache1h: 5),
    ].joined(separator: "\n") + "\n"

    try session1.write(to: proj.appendingPathComponent("session1.jsonl"), atomically: true, encoding: .utf8)
    try session2.write(to: proj.appendingPathComponent("session2.jsonl"), atomically: true, encoding: .utf8)

    let root = ClaudePathResolver.ResolvedRoot(root: base, projectsDirectory: projects)
    return (root, { try? fm.removeItem(at: base) })
}

/// Per-(date, model) accumulator. Buckets by UTC day so the assertions
/// don't depend on the CI machine's timezone (production `formatDate(_:)`
/// uses local time; the fixture uses UTC-noon timestamps + UTC bucketing
/// for determinism).
private actor FixtureCollector {
    private static let utc = TimeZone(identifier: "UTC")!
    private var byDate: [String: TokenBreakdown] = [:]
    private var byDateModel: [String: [String: TokenBreakdown]] = [:]

    func add(_ entry: ParsedUsageEntry) {
        let date = TokenSample.formatDate(entry.timestamp, timeZone: Self.utc)
        byDate[date, default: TokenBreakdown()].add(entry.breakdown)
        byDateModel[date, default: [:]][entry.model, default: TokenBreakdown()].add(entry.breakdown)
    }

    func date(_ d: String) -> TokenBreakdown { byDate[d] ?? TokenBreakdown() }
    func model(_ d: String, _ m: String) -> TokenBreakdown { byDateModel[d]?[m] ?? TokenBreakdown() }
    func models(on d: String) -> Set<String> { Set((byDateModel[d] ?? [:]).keys) }
    func dates() -> Set<String> { Set(byDate.keys) }
}

// MARK: - Tests

@Test func scannerProducesExactTotalsForSyntheticFixture() async throws {
    let (root, cleanup) = try makeFixtureRoot()
    defer { cleanup() }

    let collector = FixtureCollector()
    _ = try await JSONLScanner().scan(roots: [root]) { entry in
        await collector.add(entry)
    }

    // Exactly two days seen; the <synthetic> and "user" lines are dropped,
    // so no stray dates appear.
    #expect(await collector.dates() == ["2026-03-01", "2026-03-02"])

    // --- 2026-03-01 day totals (opus turns A+B, sonnet turn C) ---
    let d1 = await collector.date("2026-03-01")
    #expect(d1.inputTokens == 125)            // 100 + 5 + 20
    #expect(d1.outputTokens == 237)           // 200 + 7 + 30
    #expect(d1.cacheReadTokens == 1003)       // 1000 + 3 + 0
    #expect(d1.cacheCreation5mTokens == 90)   // 50 + 40 (legacy summed → 5m)
    #expect(d1.cacheCreation1hTokens == 10)   // 10 + 0
    // ccusage flattens cache-creation; our 5m+1h sum must equal it.
    #expect(d1.cacheCreation5mTokens + d1.cacheCreation1hTokens == 100)

    // --- 2026-03-01 per model ---
    #expect(await collector.models(on: "2026-03-01") == [opus, sonnet])
    let d1Opus = await collector.model("2026-03-01", opus)
    #expect(d1Opus.inputTokens == 105)
    #expect(d1Opus.outputTokens == 207)
    #expect(d1Opus.cacheReadTokens == 1003)
    #expect(d1Opus.cacheCreation5mTokens == 90)
    #expect(d1Opus.cacheCreation1hTokens == 10)
    let d1Sonnet = await collector.model("2026-03-01", sonnet)
    #expect(d1Sonnet.inputTokens == 20)
    #expect(d1Sonnet.outputTokens == 30)
    #expect(d1Sonnet.cacheReadTokens == 0)

    // --- 2026-03-02 (single opus turn D) ---
    let d2 = await collector.date("2026-03-02")
    #expect(d2.inputTokens == 1)
    #expect(d2.outputTokens == 2)
    #expect(d2.cacheReadTokens == 3)
    #expect(d2.cacheCreation5mTokens == 4)
    #expect(d2.cacheCreation1hTokens == 5)
}

/// Cross-file dedup is the single most correctness-critical behavior
/// (resumed sessions replay turns; without dedup totals inflate 2-3×).
/// msg1:req1 appears in both session files — it must be counted once.
@Test func scannerDedupesReplayedTurnAcrossFiles() async throws {
    let (root, cleanup) = try makeFixtureRoot()
    defer { cleanup() }

    let result = try await JSONLScanner().scan(roots: [root]) { _ in }

    // 5 parseable assistant turns exist (the "user" line never parses),
    // but msg1:req1 is duplicated, so exactly one is dropped as a dup.
    // The <synthetic> turn parses then is dropped at parse time (it never
    // reaches the dedup set), so it isn't counted as a duplicate.
    #expect(result.progress.duplicatesDropped == 1)

    // And the surviving opus turn on 2026-03-01 reflects A counted ONCE
    // (105 input), not twice (which would be 205).
    let collector = FixtureCollector()
    _ = try await JSONLScanner().scan(roots: [root]) { entry in await collector.add(entry) }
    #expect(await collector.model("2026-03-01", opus).inputTokens == 105)
}

/// A streamed message written to the transcript three times — the shape
/// Claude Code actually produces — must land as ONE turn carrying the
/// finished token counts, not the first mid-stream snapshot.
///
/// This is the end-to-end companion to `StreamingDedupTests`: those pin the
/// parser and the persister, this pins the *scanner*, which has to keep the
/// copy that superseded the first rather than dropping it as a duplicate.
/// Getting that wrong silently under-counts output by ~63% (correctness rule
/// §7) while every row count stays right.
@Test func scannerKeepsFinishedCopyOfStreamedMessage() async throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pacer-stream-\(UUID().uuidString)", isDirectory: true)
    let projects = dir.appendingPathComponent("projects/proj", isDirectory: true)
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // Same message id + requestId; output climbs; only the last is finished.
    func line(_ ts: String, _ output: Int64, stop: String?) -> String {
        let stopJSON = stop.map { "\"\($0)\"" } ?? "null"
        return """
        {"type":"assistant","timestamp":"\(ts)","requestId":"req1","cwd":"/tmp/pacer-fixture/proj","message":{"id":"msgStream","model":"\(opus)","stop_reason":\(stopJSON),"usage":{"input_tokens":2,"output_tokens":\(output),"cache_read_input_tokens":9992}}}
        """
    }
    // Trailing newline matters: the scanner deliberately leaves an
    // unterminated final line for the next pass, since that's how a
    // mid-write live session looks.
    try ([line("2026-03-01T10:00:00.000Z", 1, stop: nil),
          line("2026-03-01T10:00:02.000Z", 1, stop: nil),
          line("2026-03-01T10:00:03.000Z", 289, stop: "tool_use")]
        .joined(separator: "\n") + "\n")
        .write(to: projects.appendingPathComponent("stream.jsonl"),
               atomically: true, encoding: .utf8)

    let root = ClaudePathResolver.ResolvedRoot(
        root: dir, projectsDirectory: dir.appendingPathComponent("projects", isDirectory: true))
    let emitted = EntryCollector()
    _ = try await JSONLScanner().scan(roots: [root]) { entry in await emitted.add(entry) }
    let entries = await emitted.all

    // One emission per key per scan: the finished copy, as itself. It used
    // to emit the first mid-stream copy and then each improvement, so the
    // persister inserted the partial copy and upgraded it in place — the
    // finished tokens on the partial's timestamp, where the bulk importer
    // inserted the finished copy (#334). Copies split across scans still
    // reach the persister one scan at a time; that is its job.
    #expect(entries.count == 1)
    #expect(entries.first?.breakdown.outputTokens == 289)
    #expect(entries.first?.isComplete == true)
    #expect(entries.first?.dedupKey == "msgStream:req1")
    #expect(entries.first?.timestamp == JSONLLineParser.parseTimestampForImport("2026-03-01T10:00:03.000Z"))
}

/// Collects raw emissions, for tests that care about what the scanner emitted
/// rather than what the totals add up to.
private actor EntryCollector {
    private(set) var all: [ParsedUsageEntry] = []
    func add(_ entry: ParsedUsageEntry) { all.append(entry) }
}

// MARK: - Cost

/// Per-MTok rates, so the hand arithmetic below reads as dollars.
private func perMTok(_ input: Double, _ output: Double, _ read: Double,
                     _ write5m: Double, _ write1h: Double) -> PriceRates {
    PriceRates(input: input / 1e6, output: output / 1e6, cacheRead: read / 1e6,
               cacheWrite5m: write5m / 1e6, cacheWrite1h: write1h / 1e6)
}

private let fixturePriceChange = ISO8601DateFormatter().date(from: "2026-03-02T00:00:00Z")!

/// Opus drops in price at the start of 2026-03-02, between the fixture's two
/// days. Sonnet has one rate throughout. Rates are made up so no catalog
/// refresh can move them, and every category's rate differs, so a swapped
/// column changes the total. Keyed by `parse`, as the ledger looks a
/// transcript's model up: it drops the `-20250514` date suffix.
private let fixtureLedger = PriceLedger(records: [
    PriceRecordValue(key: CanonicalModelID.parse(opus), rates: perMTok(15, 75, 1.5, 18.75, 30),
                     effectiveFrom: .distantPast, effectiveTo: fixturePriceChange, source: .curated),
    PriceRecordValue(key: CanonicalModelID.parse(opus), rates: perMTok(5, 25, 0.5, 6.25, 10),
                     effectiveFrom: fixturePriceChange, source: .curated),
    PriceRecordValue(key: CanonicalModelID.parse(sonnet), rates: perMTok(3, 15, 0.3, 3.75, 6),
                     effectiveFrom: .distantPast, source: .curated),
])

private actor FixtureCostCollector {
    private static let utc = TimeZone(identifier: "UTC")!
    private var byDateModel: [String: [String: Double]] = [:]

    func add(_ entry: ParsedUsageEntry) {
        let date = TokenSample.formatDate(entry.timestamp, timeZone: Self.utc)
        let cost = CostCalculator.sampleCost(
            storedCostUSD: entry.storedCostUSD, model: entry.model, sampledAt: entry.timestamp,
            breakdown: entry.breakdown, mode: .calculate, ledger: fixtureLedger
        ).total
        byDateModel[date, default: [:]][entry.model, default: 0] += cost
    }

    func cost(_ date: String, _ model: String) -> Double { byDateModel[date]?[model] ?? 0 }
}

/// Cost ground truth is Pacer's own (#299): the scanner fixture above, priced
/// by hand. It used to be ccusage's `totalCost`, which prices every day at
/// today's catalog rate and so cannot be right once a rate has changed.
///
/// This pins the whole path from a transcript line to dollars: dedup (the
/// replayed msg1 is priced once), the legacy summed cache write landing on
/// the 5m rate, the 1h tier at its own rate, and each turn priced at the
/// rate in effect on its own date, not today's.
@Test func scannerFixtureIsPricedPerTurnAtItsOwnDatesRate() async throws {
    let (root, cleanup) = try makeFixtureRoot()
    defer { cleanup() }

    let collector = FixtureCostCollector()
    _ = try await JSONLScanner().scan(roots: [root]) { entry in await collector.add(entry) }

    // 2026-03-01 opus, the old rate: 105 in, 207 out, 1,003 read, 90 5m, 10 1h.
    // 105×15 + 207×75 + 1003×1.5 + 90×18.75 + 10×30 = 20,592 → $0.020592
    let d1Opus: Double = await collector.cost("2026-03-01", opus)
    #expect(abs(d1Opus - 0.020592) < 1e-12)

    // 2026-03-01 sonnet: 20×3 + 30×15 = 510 → $0.000510
    let d1Sonnet: Double = await collector.cost("2026-03-01", sonnet)
    #expect(abs(d1Sonnet - 0.000510) < 1e-12)

    // 2026-03-02 opus, the new rate: 1 in, 2 out, 3 read, 4 5m, 5 1h.
    // 1×5 + 2×25 + 3×0.5 + 4×6.25 + 5×10 = 131.5 → $0.0001315
    // (at the old rate it would be 1×15 + 2×75 + 3×1.5 + 4×18.75 + 5×30 = 394.5)
    let d2Opus: Double = await collector.cost("2026-03-02", opus)
    #expect(abs(d2Opus - 0.0001315) < 1e-12)
}

// MARK: - Thinking tokens (#362)

/// Hand-computed: thinking is a subset of output, so adding the field must
/// leave every token total as it was and keep only the finished copy's value.
@Test func scannerKeepsTheFinishedCopysThinkingTokens() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("pacer-thinking-fixture-\(UUID().uuidString)")
    let projects = base.appendingPathComponent("projects")
    let proj = projects.appendingPathComponent("-tmp-pacer-fixture-proj")
    try fm.createDirectory(at: proj, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }

    func line(_ ts: String, _ id: String, output: Int, stop: String?, thinking: Int?) -> String {
        let stopJSON = stop.map { "\"\($0)\"" } ?? "null"
        let details = thinking.map { ",\"output_tokens_details\":{\"thinking_tokens\":\($0)}" } ?? ""
        return "{\"type\":\"assistant\",\"timestamp\":\"\(ts)\",\"requestId\":\"r-\(id)\",\"message\":{\"id\":\"m-\(id)\",\"model\":\"\(opus)\",\"stop_reason\":\(stopJSON),\"usage\":{\"input_tokens\":10,\"output_tokens\":\(output)\(details)}}}"
    }
    let lines = [
        // Streamed: the mid-stream copy has no field, the finished one 70 of 100.
        line("2026-03-01T12:00:00.000Z", "a", output: 1, stop: nil, thinking: nil),
        line("2026-03-01T12:00:02.000Z", "a", output: 100, stop: "end_turn", thinking: 70),
        // Reported as zero is not the same as not reported.
        line("2026-03-01T13:00:00.000Z", "b", output: 20, stop: "end_turn", thinking: 0),
        // A line from before the field existed.
        line("2026-03-01T14:00:00.000Z", "c", output: 30, stop: "end_turn", thinking: nil),
    ].joined(separator: "\n") + "\n"
    try lines.write(to: proj.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
    let root = ClaudePathResolver.ResolvedRoot(root: base, projectsDirectory: projects)

    let collector = ThinkingCollector()
    _ = try await JSONLScanner().scan(roots: [root]) { entry in await collector.add(entry) }
    let (thinking, output, count) = await collector.totals()
    #expect(count == 3)
    #expect(output == 150)                   // 100 + 20 + 30, unchanged by the field
    #expect(thinking["m-a:r-a"] == .some(70))
    #expect(thinking["m-b:r-b"] == .some(0))
    #expect(thinking["m-c:r-c"] == .some(nil))
    #expect(thinking.values.compactMap { $0 }.reduce(0, +) == 70)
}

private actor ThinkingCollector {
    private var thinking: [String: Int?] = [:]
    private var output: Int64 = 0
    func add(_ e: ParsedUsageEntry) {
        thinking[e.dedupKey ?? "-"] = .some(e.thinkingTokens)
        output += e.breakdown.outputTokens
    }
    func totals() -> ([String: Int?], Int64, Int) { (thinking, output, thinking.count) }
}

// MARK: - The current transcript shape (Claude Code 2.1.32x–2.1.33x)

/// Hand-computed: a session in the shape Claude Code writes since 2.1.32x,
/// whose transcript also carries lines that hold token numbers but no usage
/// of their own: `cost-state` (Claude Code's running per-model counters, which
/// include its untranscribed calls), `api-request` and `api-request-blob` (its
/// request log; the blob has a `message`), an `away_summary` recap and a
/// compaction (`compact_boundary` plus the summary as a user line), neither of
/// which writes the usage of the call that made it. Only the assistant lines
/// count, each message once, with its finished copy; the subagent's in its
/// own file. Investigated for Sentry PACER-28: Pacer matched this hand count
/// exactly; Claude Code's counters ran higher by the untranscribed calls.
@Test func scannerCountsOnlyAssistantUsageInTheCurrentTranscriptShape() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("pacer-shape-fixture-\(UUID().uuidString)")
    let projects = base.appendingPathComponent("projects")
    let proj = projects.appendingPathComponent("-Users-someone-Code-acme")
    let subagents = proj.appendingPathComponent("s-acme/subagents")
    try fm.createDirectory(at: subagents, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }

    let current = "claude-opus-5-5"
    let small = "claude-sonnet-5-5"
    /// An assistant line as 2.1.330 writes it: thinking in
    /// `output_tokens_details`, server tool counts, one iteration repeating
    /// the usage, `fallback_credit`.
    func assistant(_ ts: String, _ id: String, model: String, stop: String?, input: Int,
                   output: Int, read: Int, write5m: Int = 0, write1h: Int = 0,
                   sidechain: Bool = false) -> String {
        let stopJSON: String = stop.map { "\"\($0)\"" } ?? "null"
        let write: Int = write5m + write1h
        let split: String = "{\"ephemeral_5m_input_tokens\":\(write5m),\"ephemeral_1h_input_tokens\":\(write1h)}"
        let counts: String = "\"input_tokens\":\(input),\"output_tokens\":\(output),"
            + "\"cache_read_input_tokens\":\(read),\"cache_creation_input_tokens\":\(write)"
        // Typed pieces, joined: one long `+` chain of interpolated literals
        // times out Xcode 16's type checker (see IngestParityTests.line).
        let usage: [String] = [
            counts,
            ",\"output_tokens_details\":{\"thinking_tokens\":\(output / 10)}",
            ",\"server_tool_use\":{\"web_search_requests\":0,\"web_fetch_requests\":0}",
            ",\"service_tier\":\"standard\",\"cache_creation\":\(split),\"inference_geo\":\"global\"",
            ",\"iterations\":[{\(counts),\"cache_creation\":\(split),\"type\":\"message\"}]",
            ",\"speed\":\"standard\",\"fallback_credit\":null",
        ]
        let parts: [String] = [
            "{\"type\":\"assistant\",\"timestamp\":\"\(ts)\",\"requestId\":\"r-\(id)\",",
            "\"sessionId\":\"s-acme\",\"isSidechain\":\(sidechain),\"cwd\":\"/Users/someone/Code/acme\",",
            "\"version\":\"2.1.330\",\"message\":{\"id\":\"m-\(id)\",\"model\":\"\(model)\",",
            "\"role\":\"assistant\",\"stop_reason\":\(stopJSON),\"usage\":{\(usage.joined())}}}",
        ]
        return parts.joined()
    }
    let main = [
        "{\"type\":\"api-request\",\"sessionId\":\"s-acme\",\"id\":\"q-1\",\"timestamp\":\"2026-11-20T10:00:00.000Z\",\"version\":\"2.1.330\",\"querySource\":\"repl_main_thread\",\"params\":{\"model\":\"\(current)\",\"max_tokens\":128000}}",
        "{\"type\":\"api-request-blob\",\"sessionId\":\"s-acme\",\"hash\":\"h1\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"hello\"}]}}",
        // A: streamed, two mid-stream copies then the finished one.
        assistant("2026-11-20T10:00:01.000Z", "A", model: current, stop: nil,
                  input: 2, output: 1, read: 27_150, write1h: 38_067),
        assistant("2026-11-20T10:00:02.000Z", "A", model: current, stop: nil,
                  input: 2, output: 1, read: 27_150, write1h: 38_067),
        assistant("2026-11-20T10:00:04.000Z", "A", model: current, stop: "tool_use",
                  input: 2, output: 200, read: 27_150, write1h: 38_067),
        assistant("2026-11-20T10:01:00.000Z", "B", model: current, stop: "end_turn",
                  input: 1, output: 450, read: 65_217, write1h: 900),
        // A recap and a compaction: each was a main-model call, and neither
        // line carries its usage.
        "{\"type\":\"system\",\"subtype\":\"away_summary\",\"isMeta\":false,\"isSidechain\":false,\"timestamp\":\"2026-11-20T10:05:00.000Z\",\"version\":\"2.1.330\",\"content\":\"Recap.\"}",
        "{\"type\":\"system\",\"subtype\":\"compact_boundary\",\"level\":\"info\",\"isMeta\":false,\"isSidechain\":false,\"timestamp\":\"2026-11-20T10:06:00.000Z\",\"version\":\"2.1.330\",\"content\":\"Conversation compacted\",\"compactMetadata\":{\"trigger\":\"auto\",\"preTokens\":204577}}",
        "{\"type\":\"user\",\"isCompactSummary\":true,\"timestamp\":\"2026-11-20T10:06:00.000Z\",\"sessionId\":\"s-acme\",\"message\":{\"role\":\"user\",\"content\":\"Summary.\"}}",
        // Claude Code's counters, untranscribed calls and all: not usage.
        "{\"type\":\"cost-state\",\"sessionId\":\"s-acme\",\"totalCostUSD\":6.97,\"startTime\":1794858148280,\"totalDuration\":134483056,\"modelUsage\":{\"\(current)\":{\"inputTokens\":5632,\"outputTokens\":32851,\"thinkingTokens\":11116,\"cacheReadInputTokens\":8587862,\"cacheCreationInputTokens\":570824,\"costUSD\":6.96},\"claude-haiku-5-5\":{\"inputTokens\":10448,\"outputTokens\":2557,\"costUSD\":0.002}}}",
    ].joined(separator: "\n") + "\n"
    let subagent = [
        assistant("2026-11-20T10:02:00.000Z", "C", model: small, stop: "end_turn",
                  input: 3, output: 120, read: 5_000, write5m: 700, sidechain: true),
    ].joined(separator: "\n") + "\n"
    try main.write(to: proj.appendingPathComponent("s-acme.jsonl"), atomically: true, encoding: .utf8)
    try subagent.write(to: subagents.appendingPathComponent("agent-a1.jsonl"),
                       atomically: true, encoding: .utf8)
    let root = ClaudePathResolver.ResolvedRoot(root: base, projectsDirectory: projects)

    let totals = FixtureCollector()
    let emitted = EntryCollector()
    _ = try await JSONLScanner().scan(roots: [root]) { entry in
        await totals.add(entry)
        await emitted.add(entry)
    }

    #expect(await emitted.all.count == 3)
    #expect(Set(await emitted.all.compactMap(\.dedupKey)) == ["m-A:r-A", "m-B:r-B", "m-C:r-C"])
    #expect(await emitted.all.allSatisfy { $0.sessionId == "s-acme" && $0.isComplete })

    // Main model: A's finished copy and B.
    let opusDay = await totals.model("2026-11-20", current)
    #expect(opusDay.inputTokens == 3)                    // 2 + 1
    #expect(opusDay.outputTokens == 650)                 // 200 + 450, not A's partial 1s
    #expect(opusDay.cacheReadTokens == 92_367)           // 27,150 + 65,217
    #expect(opusDay.cacheCreation1hTokens == 38_967)     // 38,067 + 900
    #expect(opusDay.cacheCreation5mTokens == 0)
    // The subagent, in its own file.
    let subDay = await totals.model("2026-11-20", small)
    #expect(subDay.inputTokens == 3)
    #expect(subDay.outputTokens == 120)
    #expect(subDay.cacheReadTokens == 5_000)
    #expect(subDay.cacheCreation5mTokens == 700)
    // Nothing from the counters or the request log: no Haiku, no other day.
    #expect(await totals.models(on: "2026-11-20") == [current, small])
    #expect(await totals.dates() == ["2026-11-20"])
}
