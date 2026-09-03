import Foundation
import SwiftData
import Testing
@testable import PacerCore

private func t(_ offset: TimeInterval) -> Date {
    Date(timeIntervalSince1970: 1_780_000_000 + offset)
}

@Suite("Account trail")
struct AccountTrailTests {

    @Test("an empty trail attributes nothing rather than guessing")
    func emptyTrailAttributesNothing() {
        #expect(AccountTrail.empty.accountId(at: t(0)) == nil)
        #expect(AccountTrail.empty.isEmpty)
    }

    @Test("a sample is attributed to whoever was active when it happened")
    func attributesByTimestampNotByLatest() {
        let trail = AccountTrail(spans: [
            .init(accountId: "work", startedAt: t(0), endedAt: t(100), rootPath: nil),
            .init(accountId: "personal", startedAt: t(100), endedAt: nil, rootPath: nil),
        ])
        // The boundary belongs to the incoming account: spans are
        // half-open, so no instant is claimed by two of them.
        #expect(trail.accountId(at: t(50)) == "work")
        #expect(trail.accountId(at: t(99)) == "work")
        #expect(trail.accountId(at: t(100)) == "personal")
        #expect(trail.accountId(at: t(10_000)) == "personal")
    }

    @Test("time before the trail starts stays unattributed")
    func beforeTheTrailIsUnknown() {
        let trail = AccountTrail(spans: [
            .init(accountId: "work", startedAt: t(500), endedAt: nil, rootPath: nil)
        ])
        #expect(trail.accountId(at: t(499)) == nil)
        #expect(trail.accountId(at: t(500)) == "work")
    }

    @Test("a gap between spans is unattributed, not filled in")
    func gapsAreNotBridged() {
        let trail = AccountTrail(spans: [
            .init(accountId: "work", startedAt: t(0), endedAt: t(100), rootPath: nil),
            .init(accountId: "personal", startedAt: t(200), endedAt: nil, rootPath: nil),
        ])
        #expect(trail.accountId(at: t(150)) == nil)
    }

    @Test("a pinned root is answered from its own spans")
    func pinnedRootWins() {
        let trail = AccountTrail(spans: [
            .init(accountId: "default-acct", startedAt: t(0), endedAt: nil, rootPath: nil),
            .init(accountId: "session-acct", startedAt: t(0), endedAt: nil,
                  rootPath: "/profiles/2"),
        ])
        #expect(trail.accountId(at: t(50)) == "default-acct")
        #expect(trail.accountId(at: t(50), rootPath: "/profiles/2") == "session-acct")
    }

    @Test("a pinned root does not fall back to the default login")
    func pinnedRootDoesNotBorrowTheDefaultAccount() {
        // The transcripts under a pinned profile are known NOT to be the
        // default account's. Answering with the default id would be a
        // confident wrong attribution; nil is the honest answer.
        let trail = AccountTrail(spans: [
            .init(accountId: "default-acct", startedAt: t(0), endedAt: nil, rootPath: nil),
            .init(accountId: "session-acct", startedAt: t(900), endedAt: nil,
                  rootPath: "/profiles/2"),
        ])
        #expect(trail.accountId(at: t(50), rootPath: "/profiles/2") == nil)
    }

    @Test("an unknown root is treated as the default login")
    func unknownRootUsesDefaultSpans() {
        let trail = AccountTrail(spans: [
            .init(accountId: "default-acct", startedAt: t(0), endedAt: nil, rootPath: nil)
        ])
        #expect(trail.accountId(at: t(50), rootPath: "/never/claimed") == "default-acct")
    }

    @Test("sequential switching is not reported as concurrency")
    func switchingIsNotConcurrency() {
        let trail = AccountTrail(spans: [
            .init(accountId: "work", startedAt: t(0), endedAt: t(100), rootPath: nil),
            .init(accountId: "personal", startedAt: t(100), endedAt: t(200), rootPath: nil),
            .init(accountId: "work", startedAt: t(200), endedAt: nil, rootPath: nil),
        ])
        #expect(trail.hasConcurrentAccounts == false)
        #expect(trail.accountIds == ["work", "personal"])
    }

    @Test("two accounts live at once is reported as concurrency")
    func overlappingAccountsAreConcurrent() {
        let trail = AccountTrail(spans: [
            .init(accountId: "work", startedAt: t(0), endedAt: t(300), rootPath: nil),
            .init(accountId: "personal", startedAt: t(100), endedAt: t(200),
                  rootPath: "/profiles/2"),
        ])
        #expect(trail.hasConcurrentAccounts)
    }

    @Test("an open span overlapping a later account counts as concurrent")
    func openSpanOverlapCounts() {
        let trail = AccountTrail(spans: [
            .init(accountId: "work", startedAt: t(0), endedAt: nil, rootPath: nil),
            .init(accountId: "personal", startedAt: t(100), endedAt: nil,
                  rootPath: "/profiles/2"),
        ])
        #expect(trail.hasConcurrentAccounts)
    }

    @Test("one account across many spans is not concurrency")
    func sameAccountOverlapIsNotConcurrency() {
        let trail = AccountTrail(spans: [
            .init(accountId: "solo", startedAt: t(0), endedAt: t(300), rootPath: nil),
            .init(accountId: "solo", startedAt: t(100), endedAt: nil, rootPath: "/profiles/1"),
        ])
        #expect(trail.hasConcurrentAccounts == false)
    }

    @Test("lookup is correct across many spans")
    func binarySearchAcrossManySpans() {
        let spans = (0..<200).map { i in
            AccountTrail.Span(
                accountId: i % 2 == 0 ? "a" : "b",
                startedAt: t(Double(i) * 10),
                endedAt: t(Double(i) * 10 + 10),
                rootPath: nil
            )
        }
        let trail = AccountTrail(spans: spans.shuffled())
        for i in 0..<200 {
            let expected = i % 2 == 0 ? "a" : "b"
            #expect(trail.accountId(at: t(Double(i) * 10 + 5)) == expected)
        }
        #expect(trail.accountId(at: t(2000)) == nil)
    }
}
