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
            "fetchedAt": 1788889100.0, "lastError": "http-429",
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

    @Test("an account with no windows yet is still reported, with none")
    func emptyWindows() throws {
        let readings = SwitcherUsageCache.readings(at: try write(
            #"{"accounts":{"1":{"organizationUuid":"o","fetchedAt":123,"lastGood":{}}}}"#))
        #expect(readings.count == 1)
        #expect(readings.first?.fiveHour == nil)
        #expect(readings.first?.scoped.isEmpty == true)
    }
}

/// The scheduling half: Pacer aims for the middle of cswap's gap rather than
/// yielding to its cadence. Getting this backwards is what made an account
/// that could be read every few minutes update every eleven.
@Suite("Interleaving with the switcher's schedule")
struct SwitcherInterleaveTests {

    private func reading(next: Date?, interval: TimeInterval?) -> SwitcherUsageCache.Reading {
        SwitcherUsageCache.Reading(
            organizationId: "org", fetchedAt: Date(timeIntervalSince1970: 1000),
            nextPollAt: next, pollInterval: interval,
            fiveHour: nil, sevenDay: nil, scoped: [])
    }

    @Test("the target is halfway back from the switcher's next poll")
    func midpoint() {
        let next = Date(timeIntervalSince1970: 1600)
        let r = reading(next: next, interval: 600)
        #expect(r.interleavedPollAt == Date(timeIntervalSince1970: 1300))
    }

    /// Without a published schedule there is nothing to interleave with, and
    /// Pacer must fall back to its own cadence rather than guess one.
    @Test("no schedule means no target")
    func noSchedule() {
        #expect(reading(next: nil, interval: 600).interleavedPollAt == nil)
        #expect(reading(next: Date(), interval: nil).interleavedPollAt == nil)
        #expect(reading(next: Date(), interval: 0).interleavedPollAt == nil)
    }

    /// A long cswap interval must widen the gap Pacer aims into, not shrink it
    /// — the whole point is to sit as far from cswap's request as possible.
    @Test("a longer switcher interval puts the target further from its poll")
    func scalesWithInterval() {
        let next = Date(timeIntervalSince1970: 10_000)
        let short = reading(next: next, interval: 300).interleavedPollAt!
        let long = reading(next: next, interval: 1200).interleavedPollAt!
        #expect(next.timeIntervalSince(long) > next.timeIntervalSince(short))
        #expect(next.timeIntervalSince(long) == 600)
    }
}
