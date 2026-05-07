import Foundation
import Testing
@testable import PacerCore

@Suite("JSONLLineParser")
struct JSONLParserTests {

    @Test func skipsNonAssistantLines() {
        let userLine = #"{"type":"user","message":{"role":"user","content":"hi"}}"#
        let permLine = #"{"type":"permission-mode","permissionMode":"default"}"#
        #expect(JSONLLineParser.parse(line: userLine) == nil)
        #expect(JSONLLineParser.parse(line: permLine) == nil)
    }

    @Test func skipsSyntheticModel() {
        let line = """
            {"type":"assistant","timestamp":"2026-05-06T20:00:00.123Z","message":\
            {"id":"m1","model":"<synthetic>","usage":{"input_tokens":10,"output_tokens":5}},\
            "requestId":"r1"}
            """
        #expect(JSONLLineParser.parse(line: line) == nil)
    }

    @Test func skipsLineWithoutTimestamp() {
        let line = """
            {"type":"assistant","message":{"id":"m1","model":"claude-opus-4-7",\
            "usage":{"input_tokens":1,"output_tokens":1}}}
            """
        #expect(JSONLLineParser.parse(line: line) == nil)
    }

    @Test func parsesMinimalAssistantLine() throws {
        let line = """
            {"type":"assistant","timestamp":"2026-05-06T20:00:00.123Z","sessionId":"s1",\
            "version":"2.1.132","cwd":"/Users/eric/Code","requestId":"r1",\
            "message":{"id":"m1","model":"claude-opus-4-7",\
            "usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":1000,\
            "cache_creation":{"ephemeral_5m_input_tokens":200,"ephemeral_1h_input_tokens":300}}}}
            """
        let entry = try #require(JSONLLineParser.parse(line: line))
        #expect(entry.model == "claude-opus-4-7")
        #expect(entry.sessionId == "s1")
        #expect(entry.claudeCodeVersion == "2.1.132")
        #expect(entry.projectPath == "/Users/eric/Code")
        #expect(entry.dedupKey == "m1:r1")
        #expect(entry.breakdown.inputTokens == 100)
        #expect(entry.breakdown.outputTokens == 50)
        #expect(entry.breakdown.cacheReadTokens == 1000)
        #expect(entry.breakdown.cacheCreation5mTokens == 200)
        #expect(entry.breakdown.cacheCreation1hTokens == 300)
    }

    @Test func backfillsLegacyCacheCreationAs5mTier() throws {
        // Older Claude Code lines emit only the summed
        // `cache_creation_input_tokens` without the 5m/1h split. We
        // attribute the whole thing to 5m (cheaper tier) so cost
        // estimates never run high on legacy data.
        let line = """
            {"type":"assistant","timestamp":"2026-05-06T20:00:00.123Z","requestId":"r1",\
            "message":{"id":"m1","model":"claude-opus-4-7",\
            "usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":777}}}
            """
        let entry = try #require(JSONLLineParser.parse(line: line))
        #expect(entry.breakdown.cacheCreation5mTokens == 777)
        #expect(entry.breakdown.cacheCreation1hTokens == 0)
    }

    @Test func dedupKeyIsNilWhenEitherIdMissing() throws {
        // No requestId — dedup key must be nil so the entry isn't
        // skipped when a "duplicate" is encountered later. ccusage
        // does the same — dedup is opt-in per line.
        let noReqId = """
            {"type":"assistant","timestamp":"2026-05-06T20:00:00.123Z",\
            "message":{"id":"m1","model":"claude-opus-4-7",\
            "usage":{"input_tokens":1,"output_tokens":1}}}
            """
        let entry1 = try #require(JSONLLineParser.parse(line: noReqId))
        #expect(entry1.dedupKey == nil)

        let noMsgId = """
            {"type":"assistant","timestamp":"2026-05-06T20:00:00.123Z","requestId":"r1",\
            "message":{"model":"claude-opus-4-7",\
            "usage":{"input_tokens":1,"output_tokens":1}}}
            """
        let entry2 = try #require(JSONLLineParser.parse(line: noMsgId))
        #expect(entry2.dedupKey == nil)
    }

    @Test func returnsNilForMalformedJSON() {
        #expect(JSONLLineParser.parse(line: "{not json") == nil)
        #expect(JSONLLineParser.parse(line: "") == nil)
        #expect(JSONLLineParser.parse(line: "  ") == nil)
    }

    @Test func acceptsTimestampWithoutFractionalSeconds() throws {
        let line = """
            {"type":"assistant","timestamp":"2026-05-06T20:00:00Z","requestId":"r1",\
            "message":{"id":"m1","model":"claude-opus-4-7",\
            "usage":{"input_tokens":1,"output_tokens":1}}}
            """
        let entry = try #require(JSONLLineParser.parse(line: line))
        let comps = Calendar(identifier: .gregorian)
            .dateComponents(in: TimeZone(identifier: "UTC")!, from: entry.timestamp)
        #expect(comps.year == 2026)
        #expect(comps.month == 5)
        #expect(comps.second == 0)
    }
}
