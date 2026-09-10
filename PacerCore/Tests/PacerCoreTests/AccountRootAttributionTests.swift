import Foundation
import Testing
@testable import PacerCore

private func t(_ o: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_780_000_000 + o) }

/// Attribution when two accounts are live at the same time.
///
/// A pinned session profile writes to its own `projects/` directory, so the
/// root a turn was found under is the only thing that separates concurrent
/// accounts — the timestamp has two answers.
@Suite("Concurrent-account attribution")
struct AccountRootAttributionTests {

    private var trail: AccountTrail {
        AccountTrail(spans: [
            // Default login: work, all day.
            .init(accountId: "work", startedAt: t(0), endedAt: nil, rootPath: nil),
            // A session pinned to a second profile, running personal at the
            // same time — overlapping, not sequential.
            .init(accountId: "personal", startedAt: t(100), endedAt: t(500),
                  rootPath: "/profiles/2"),
        ])
    }

    @Test("the same instant resolves to different accounts by root")
    func rootDisambiguatesConcurrentAccounts() {
        #expect(trail.accountId(at: t(200)) == "work")
        #expect(trail.accountId(at: t(200), rootPath: "/profiles/2") == "personal")
    }

    @Test("the default root is answered from the default-login spans")
    func defaultRootNeedsNoSpecialCase() {
        // The scanner passes the real config root through rather than
        // mapping it to nil, so an unclaimed root must fall back.
        #expect(trail.accountId(at: t(200), rootPath: "/Users/x/.claude") == "work")
    }

    @Test("a pinned root outside its own span is unknown, never the default account")
    func pinnedRootDoesNotBorrowTheDefault() {
        #expect(trail.accountId(at: t(600), rootPath: "/profiles/2") == nil)
    }

    @Test("overlap is reported as concurrent so the UI can adapt")
    func overlapIsDetected() {
        #expect(trail.hasConcurrentAccounts)
    }

    @Test("a parsed entry carries the root it was read from")
    func parserStampsTheRoot() {
        let line = """
        {"type":"assistant","timestamp":"2026-09-03T10:00:00Z","requestId":"r1",
         "message":{"id":"m1","model":"claude-opus-5","stop_reason":"end_turn",
                    "usage":{"input_tokens":1,"output_tokens":2}}}
        """
        let entry = JSONLLineParser.parse(line: line, rootPath: "/profiles/2")
        #expect(entry?.rootPath == "/profiles/2")

        // Default: no root context (an explicitly listed file).
        #expect(JSONLLineParser.parse(line: line)?.rootPath == nil)
    }
}
