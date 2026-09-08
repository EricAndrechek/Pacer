import Foundation
import Testing
@testable import PacerCore

/// Pacer reads what `cswap` already fetched rather than asking Anthropic for
/// the same thing with the same token — see `SwitcherUsageCache` for why. The
/// file belongs to another tool, so the tests are mostly about not trusting it.
@Suite("Reading the switcher's usage cache")
struct SwitcherUsageCacheTests {

    private func write(_ json: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Shape copied from the real file, including the fractional-second
    /// timestamps and the per-model `scoped` list.
    private let real = """
    {"schemaVersion": 2, "accounts": {
      "1": {"email": "a@example.com", "organizationUuid": "org-work",
            "fetchedAt": 1788889000.5, "lastError": null,
            "lastGood": {"five_hour": {"pct": 34.0, "resets_at": "2026-09-08T20:40:00.455313+00:00"},
                         "seven_day": {"pct": 7.0, "resets_at": "2026-09-14T10:00:00.455337+00:00"},
                         "scoped": [{"name": "Fable", "pct": 26.0,
                                     "resets_at": "2026-09-09T05:00:00.108284+00:00"}]}},
      "2": {"email": "b@example.com", "organizationUuid": "org-personal",
            "fetchedAt": 1788889100.0, "lastAttemptAt": 1788889700.0,
            "lastError": "http-429",
            "lastGood": {"five_hour": {"pct": 19.0, "resets_at": null},
                         "seven_day": {"pct": 25.0, "resets_at": "2026-09-09T05:00:00.108134+00:00"},
                         "scoped": []}}}}
    """

    @Test("reads both accounts, their windows and their per-model rows")
    func readsRealShape() throws {
        let readings = SwitcherUsageCache.readings(at: try write(real))
        #expect(readings.count == 2)
        let work = try #require(readings.first { $0.organizationId == "org-work" })
        #expect(work.fiveHour?.percent == 34)
        #expect(work.sevenDay?.percent == 7)
        #expect(work.scoped.map(\.name) == ["Fable"])
        #expect(work.scoped.first?.percent == 26)
        #expect(work.fiveHour?.resetsAt != nil)
        #expect(work.fetchedAt == Date(timeIntervalSince1970: 1788889000.5))
    }

    /// A 429 leaves `lastError` set but `lastGood` intact — that reading is
    /// still the best available answer and must not be discarded. This is the
    /// exact case the integration exists for.
    @Test("a rate-limited account still yields its last good reading")
    func keepsLastGoodDespiteError() throws {
        let readings = SwitcherUsageCache.readings(at: try write(real))
        let personal = try #require(readings.first { $0.organizationId == "org-personal" })
        #expect(personal.fiveHour?.percent == 19)
        // `resets_at: null` is real server behaviour at 0% and must survive.
        #expect(personal.fiveHour?.resetsAt == nil)
        #expect(personal.sevenDay?.resetsAt != nil)
    }

    /// The file is another tool's, and every one of these is a shape it could
    /// legitimately take. None of them may throw or crash.
    @Test("anything unexpected reads as no data, never as a failure")
    func toleratesJunk() throws {
        #expect(SwitcherUsageCache.readings(
            at: URL(fileURLWithPath: "/nope/\(UUID().uuidString).json")).isEmpty)
        #expect(SwitcherUsageCache.readings(at: try write("not json at all")).isEmpty)
        #expect(SwitcherUsageCache.readings(at: try write("{}")).isEmpty)
        #expect(SwitcherUsageCache.readings(at: try write(#"{"accounts": []}"#)).isEmpty)
        // Present but never successfully fetched, and missing the org id.
        #expect(SwitcherUsageCache.readings(at: try write(
            #"{"accounts":{"1":{"organizationUuid":"o","fetchedAt":0,"lastGood":{}}}}"#)).isEmpty)
        #expect(SwitcherUsageCache.readings(at: try write(
            #"{"accounts":{"1":{"fetchedAt":123,"lastGood":{}}}}"#)).isEmpty)
    }

    /// The field the whole cooperation turns on: a 429 spends the token's
    /// budget and moves only `lastAttemptAt`. Reading `fetchedAt` alone made
    /// cswap's retries invisible, and Pacer scheduled straight into them.
    @Test("a failing account still reports when it last asked")
    func readsLastAttempt() throws {
        let readings = SwitcherUsageCache.readings(at: try write(real))
        let personal = try #require(readings.first { $0.organizationId == "org-personal" })
        #expect(personal.lastAttemptAt == Date(timeIntervalSince1970: 1788889700))
        #expect(personal.lastAttemptAt! > personal.fetchedAt)
        // An account that has never failed simply doesn't have one.
        let work = try #require(readings.first { $0.organizationId == "org-work" })
        #expect(work.lastAttemptAt == nil)
    }

    @Test("an account with no windows yet is still reported, with none")
    func emptyWindows() throws {
        let readings = SwitcherUsageCache.readings(at: try write(
            #"{"accounts":{"1":{"organizationUuid":"o","fetchedAt":123,"lastGood":{}}}}"#))
        #expect(readings.count == 1)
        #expect(readings.first?.fiveHour == nil)
        #expect(readings.first?.scoped.isEmpty == true)
    }
}

/// Whether to stand down for cswap, and how far back its last request counts.
/// The policy, without the lanes it gets written to.
@Suite("Deferring to the switcher")
struct SwitcherHoldTests {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func reading(
        fetched: TimeInterval, attempted: TimeInterval? = nil, next: TimeInterval? = nil
    ) -> SwitcherUsageCache.Reading {
        SwitcherUsageCache.Reading(
            organizationId: "org", fetchedAt: now.addingTimeInterval(fetched),
            lastAttemptAt: attempted.map { now.addingTimeInterval($0) },
            nextPollAt: next.map { now.addingTimeInterval($0) },
            pollInterval: 600, fiveHour: nil, sevenDay: nil, scoped: [])
    }

    /// The bug this exists for. cswap fetched four minutes ago and has been
    /// retrying since; the last retry is what Pacer has to schedule around,
    /// because it spent the budget just as surely as a success would have.
    @Test("a failed retry counts as budget spent")
    func failedRetryCountsAsSpent() {
        let hold = OAuthPoller.switcherHold(
            for: reading(fetched: -240, attempted: -30, next: 300), now: now)
        #expect(hold.spentAt == now.addingTimeInterval(-30))
        #expect(hold.nextPollAt == now.addingTimeInterval(300))
    }

    @Test("with no failures the successful fetch is the mark")
    func successIsTheMark() {
        #expect(OAuthPoller.switcherHold(for: reading(fetched: -120), now: now).spentAt
                == now.addingTimeInterval(-120))
    }

    /// An attempt older than the last success is stale bookkeeping, not a
    /// newer request; it must not drag the mark backwards.
    @Test("an older attempt never moves the mark back")
    func olderAttemptIgnored() {
        #expect(OAuthPoller.switcherHold(
            for: reading(fetched: -60, attempted: -600), now: now).spentAt
                == now.addingTimeInterval(-60))
    }

    /// The other half: deferring is only worth it while it produces readings.
    /// A client stuck in a retry loop it never wins would otherwise pin the
    /// lane indefinitely — both through its schedule and through its attempts —
    /// and Pacer would sit and watch its own numbers age.
    @Test("a switcher that has stopped delivering is no longer deferred to")
    func stuckSwitcherIsDropped() {
        let stale = -(OAuthPoller.switcherStaleAfter + 60)
        let hold = OAuthPoller.switcherHold(
            for: reading(fetched: stale, attempted: -10, next: 60), now: now)
        #expect(hold.nextPollAt == nil)
        #expect(hold.spentAt == now.addingTimeInterval(stale))
    }

    @Test("a delivering switcher just inside the window is still deferred to")
    func freshEnoughStillHolds() {
        let hold = OAuthPoller.switcherHold(
            for: reading(fetched: -(OAuthPoller.switcherStaleAfter - 60), next: 60), now: now)
        #expect(hold.nextPollAt == now.addingTimeInterval(60))
    }
}
