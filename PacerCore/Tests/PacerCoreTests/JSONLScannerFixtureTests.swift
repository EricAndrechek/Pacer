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
