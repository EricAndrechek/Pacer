import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// Dedup must keep the *finished* copy of a streamed assistant message.
///
/// Claude Code appends the same message to the transcript several times while
/// it streams. Every copy shares `${messageId}:${requestId}`, `input` and
/// `cache_read` are identical, and only the last copy carries the real
/// `output_tokens` and a non-null `stop_reason`:
///
///     18:31:20.543  output=1    stop_reason=null
///     18:31:22.947  output=1    stop_reason=null
///     18:31:23.564  output=289  stop_reason="tool_use"
///
/// First-wins dedup (inherited from ccusage — correct for *replayed*
/// duplicates, wrong for *streamed* ones) kept `output=1` and threw away
/// `output=289`. Measured on a frozen 1,697-file corpus of real transcripts:
/// 17,787 affected keys, 29,533,409 output tokens discarded — 63% of the
/// output total actually recorded, about $443 at Opus output rates.
@Suite struct StreamingDedupTests {

    private func line(
        messageId: String, requestId: String, output: Int64,
        stopReason: String?, input: Int64 = 2, cacheRead: Int64 = 9992,
        at timestamp: String = "2026-07-15T18:31:20.543Z"
    ) -> String {
        let stop = stopReason.map { "\"\($0)\"" } ?? "null"
        return """
        {"type":"assistant","timestamp":"\(timestamp)","requestId":"\(requestId)",
         "sessionId":"sess-1","cwd":"/Users/dev/code/acme","version":"2.1.0",
         "message":{"id":"\(messageId)","model":"claude-opus-5","stop_reason":\(stop),
          "usage":{"input_tokens":\(input),"output_tokens":\(output),
                   "cache_read_input_tokens":\(cacheRead)}}}
        """.replacingOccurrences(of: "\n", with: "")
    }

    // MARK: - Parsing

    @Test func stopReasonMarksCompleteness() {
        let partial = JSONLLineParser.parse(line: line(
            messageId: "m1", requestId: "r1", output: 1, stopReason: nil))
        let finished = JSONLLineParser.parse(line: line(
            messageId: "m1", requestId: "r1", output: 289, stopReason: "tool_use"))
        #expect(partial?.isComplete == false)
        #expect(finished?.isComplete == true)
        #expect(partial?.dedupKey == finished?.dedupKey)   // same message
    }

    // MARK: - Precedence

    @Test func finishedCopySupersedesPartial() {
        let partial = JSONLLineParser.parse(line: line(
            messageId: "m1", requestId: "r1", output: 1, stopReason: nil))!
        let finished = JSONLLineParser.parse(line: line(
            messageId: "m1", requestId: "r1", output: 289, stopReason: "tool_use"))!
        #expect(finished.supersedes(partial))
        #expect(!partial.supersedes(finished))
    }

    /// 6.3% of real keys never get a finished copy (interrupted messages), so
    /// precedence must still be decidable — the later, larger snapshot wins.
    @Test func laterPartialSupersedesEarlierPartial() {
        let early = JSONLLineParser.parse(line: line(
            messageId: "m1", requestId: "r1", output: 1, stopReason: nil))!
        let later = JSONLLineParser.parse(line: line(
            messageId: "m1", requestId: "r1", output: 42, stopReason: nil))!
        #expect(later.supersedes(early))
        #expect(!early.supersedes(later))
    }

    /// A genuine replay — same message, same finished numbers — must not
    /// count twice or churn the row.
    @Test func identicalReplayDoesNotSupersede() {
        let first = JSONLLineParser.parse(line: line(
            messageId: "m1", requestId: "r1", output: 289, stopReason: "tool_use"))!
        let replay = JSONLLineParser.parse(line: line(
            messageId: "m1", requestId: "r1", output: 289, stopReason: "tool_use"))!
        #expect(!replay.supersedes(first))
    }

    // MARK: - Persistence

    /// The production shape, end to end: three copies in arrival order must
    /// leave ONE row carrying the finished token counts.
    @ScanActor
    @Test func persisterUpgradesPartialToFinished() throws {
        let container = try ModelContainer(
            for: TokenSample.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let persister = try SamplePersister(context: context)

        let copies = [
            line(messageId: "m1", requestId: "r1", output: 1, stopReason: nil,
                 at: "2026-07-15T18:31:20.543Z"),
            line(messageId: "m1", requestId: "r1", output: 1, stopReason: nil,
                 at: "2026-07-15T18:31:22.947Z"),
            line(messageId: "m1", requestId: "r1", output: 289, stopReason: "tool_use",
                 at: "2026-07-15T18:31:23.564Z"),
        ]
        for raw in copies {
            let entry = try #require(JSONLLineParser.parse(line: raw))
            _ = try persister.insert(entry)
        }
        try context.save()

        let rows = try context.fetch(FetchDescriptor<TokenSample>())
        #expect(rows.count == 1)                      // still one message
        #expect(rows.first?.outputTokens == 289)      // …with the real count
        #expect(rows.first?.inputTokens == 2)         // unchanged fields intact
        #expect(rows.first?.cacheReadTokens == 9992)
        #expect(persister.stats.upgradedFromPartial == 1)
    }

    /// Arrival order must not change the outcome — a scan that happens to see
    /// the finished copy first must not then be downgraded by a stale partial.
    @ScanActor
    @Test func finishedFirstIsNotDowngradedByPartial() throws {
        let container = try ModelContainer(
            for: TokenSample.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let persister = try SamplePersister(context: context)

        for raw in [line(messageId: "m1", requestId: "r1", output: 289, stopReason: "tool_use"),
                    line(messageId: "m1", requestId: "r1", output: 1, stopReason: nil)] {
            let entry = try #require(JSONLLineParser.parse(line: raw))
            _ = try persister.insert(entry)
        }
        try context.save()

        let rows = try context.fetch(FetchDescriptor<TokenSample>())
        #expect(rows.count == 1)
        #expect(rows.first?.outputTokens == 289)
        #expect(persister.stats.skippedAsDuplicate == 1)
    }
}
