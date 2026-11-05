import Foundation
import SwiftData
import Testing
@testable import PacerCore

// #357: after a `/login` in one session, the others keep the token they hold
// and go on billing the old account. A login change a switcher made is one
// running sessions follow; any other leaves the sessions already running in
// doubt, and the session lookup says which accounts they may still be on.
// Fictional org ids throughout.

private let orgA = "aaaaaaaa-1111-4111-8111-111111111111"
private let orgB = "bbbbbbbb-2222-4222-8222-222222222222"
private let orgC = "cccccccc-3333-4333-8333-333333333333"

@Suite("Login switch evidence")
struct LoginSwitchEvidenceTests {

    static let sequence = Data("""
    {"activeAccountNumber": 2, "lastUpdated": "2026-10-26T16:36:49Z", "sequence": [1, 2],
     "accounts": {"1": {"organizationUuid": "\(orgA)"}, "2": {"organizationUuid": "\(orgB)"},
                  "3": {"organizationUuid": "\(orgC)"}}}
    """.utf8)

    static let utc = TimeZone(identifier: "UTC")!

    static func at(_ stamp: String) -> Date { ISO8601DateFormatter().date(from: stamp)! }

    @Test func readsEverySwitchTheLogRecordsAndNothingElse() {
        let log = """
        2026-10-26 16:36:49,513 - INFO - Switched from account 1 to 2
        2026-10-26 16:40:12,000 - INFO - usage someone: 5h 66%
        2026-10-26 16:48:22,782 - INFO - Updated credentials for account 1: someone
        2026-10-26 17:48:33,363 - INFO - Switched from account 1 to 3
        not a log line at all
        """
        let evidence = LoginSwitchEvidence.parse(sequence: Self.sequence, logTail: log, timeZone: Self.utc)
        #expect(evidence.switches.map(\.accountId) == [orgB, orgC])
        // To the millisecond the log gives.
        let ms = evidence.switches.map { ($0.at.timeIntervalSince1970 * 1_000).rounded() }
        #expect(ms == [(Self.at("2026-10-26T16:36:49Z").timeIntervalSince1970 + 0.513) * 1_000,
                       (Self.at("2026-10-26T17:48:33Z").timeIntervalSince1970 + 0.363) * 1_000].map { $0.rounded() })
    }

    @Test func theLogIsLocalTime() {
        let log = "2026-10-26 12:36:49,000 - INFO - Switched from account 1 to 2\n"
        let eastern = TimeZone(secondsFromGMT: -4 * 3_600)!
        let evidence = LoginSwitchEvidence.parse(sequence: Self.sequence, logTail: log, timeZone: eastern)
        #expect(evidence.switches.first?.at == Self.at("2026-10-26T16:36:49Z"))
    }

    @Test func withoutSwitchLinesTheRostersActiveSlotStandsIn() {
        let evidence = LoginSwitchEvidence.parse(sequence: Self.sequence, logTail: nil, timeZone: Self.utc)
        #expect(evidence.switches == [.init(at: Self.at("2026-10-26T16:36:49Z"), accountId: orgB)])
        #expect(LoginSwitchEvidence.parse(sequence: nil, logTail: "x", timeZone: Self.utc) == .none)
    }

    @Test func aSwitchExplainsTheChangeItMadeEvenWhenPacerSawItLate() {
        let evidence = LoginSwitchEvidence(switches: [.init(at: Self.at("2026-10-26T16:36:49Z"), accountId: orgB)])
        func change(at: String, from since: String, to: String) -> AccountTrail.LoginChange {
            .init(at: Self.at(at), from: orgA, fromSince: Self.at(since), to: to)
        }
        // Seen within a second.
        #expect(evidence.explains(change(at: "2026-10-26T16:36:50Z", from: "2026-10-26T12:00:00Z", to: orgB)))
        // Seen twenty minutes late (Pacer was relaunching): still that switch.
        #expect(evidence.explains(change(at: "2026-10-26T16:57:00Z", from: "2026-10-26T12:00:00Z", to: orgB)))
        // Another account, or a switch from before the old login began.
        #expect(!evidence.explains(change(at: "2026-10-26T16:36:50Z", from: "2026-10-26T12:00:00Z", to: orgC)))
        #expect(!evidence.explains(change(at: "2026-10-26T18:00:00Z", from: "2026-10-26T17:00:00Z", to: orgB)))
    }

    @Test func aReaderKeepsItsAnswerUntilTheFilesChange() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pacer-swap-\(UUID().uuidString)")
        let dir = home.appendingPathComponent(".claude-swap-backup")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let reader = LoginSwitchEvidenceReader(homeDirectory: home)
        #expect(reader.current() == .none)
        try Self.sequence.write(to: dir.appendingPathComponent("sequence.json"))
        let log = dir.appendingPathComponent("claude-swap.log")
        try "2026-10-26 16:36:49,000 - INFO - Switched from account 1 to 2\n".write(to: log, atomically: true, encoding: .utf8)
        #expect(reader.current().switches.map(\.accountId) == [orgB])
        try "2026-10-26 16:36:49,000 - INFO - Switched from account 1 to 2\n2026-10-26 17:00:00,000 - INFO - Switched from account 2 to 3\n"
            .write(to: log, atomically: true, encoding: .utf8)
        #expect(reader.current().switches.map(\.accountId) == [orgB, orgC])
        #expect(LoginSwitchEvidenceReader(homeDirectory: nil).current() == .none)
    }
}

@Suite("Sessions in doubt after a login change")
struct SessionLoginDoubtTests {

    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    static func span(_ account: String, _ from: TimeInterval, _ to: TimeInterval?) -> AccountTrail.Span {
        .init(accountId: account, startedAt: ago(from), endedAt: to.map { ago($0) }, rootPath: nil)
    }

    @Test func changesLeaveOutBlipsAndRepeats() {
        let trail = AccountTrail(spans: [
            Self.span(orgA, 7_200, 3_600),
            // A stale write accepted and refuted within seconds, and a
            // refuted span kept at zero length.
            Self.span(orgB, 3_600, 3_590),
            Self.span(orgA, 3_590, 1_800),
            Self.span(orgC, 1_800, 1_800),
            Self.span(orgB, 1_800, nil),
        ])
        #expect(trail.defaultLoginChanges() == [
            .init(at: Self.ago(1_800), from: orgA, fromSince: Self.ago(7_200), to: orgB),
        ])
    }

    @Test func aSwitchAwayAndBackIsNotABlip() throws {
        // B renewed by /login an hour ago, while the sessions stayed on A;
        // then a switcher went to C and back to B within a minute and a half,
        // which moves every running session onto B.
        let trail = AccountTrail(spans: [
            Self.span(orgA, 20_000, 3_600), Self.span(orgB, 3_600, 600),
            Self.span(orgC, 600, 510), Self.span(orgB, 510, nil),
        ])
        let roundTrip = LoginSwitchEvidence(switches: [
            .init(at: Self.ago(20_000), accountId: orgA),
            .init(at: Self.ago(601), accountId: orgC), .init(at: Self.ago(511), accountId: orgB),
        ])
        let binding = PacerSessionBinding(trail: trail, desktopAccounts: [:], switches: roundTrip)
        #expect(binding.changes.map(\.change.to) == [orgB, orgC, orgB])
        #expect(binding.mayStillBill(startedAt: nil, current: orgB, now: Self.now) == nil)
        // Before the round trip, the /login had them in doubt.
        let before = Self.now.addingTimeInterval(-900)
        #expect(binding.mayStillBill(startedAt: nil, current: orgB, now: before)?.accounts == [orgA])
        // Without the switcher's record, the short span is a blip and the
        // doubt stays.
        let blind = PacerSessionBinding(trail: trail, desktopAccounts: [:])
        #expect(blind.changes.map(\.change.to) == [orgB])
        #expect(blind.mayStillBill(startedAt: nil, current: orgB, now: Self.now)?.accounts == [orgA])
    }

    /// A → B by a switcher two hours ago, B → C by `/login` ten minutes ago.
    static let trail = AccountTrail(spans: [
        span(orgA, 20_000, 7_200), span(orgB, 7_200, 600), span(orgC, 600, nil),
    ])
    static let switched = LoginSwitchEvidence(switches: [.init(at: ago(7_200), accountId: orgB)])

    @Test func aSessionRunningAcrossAnUnexplainedChangeMayStillBillTheOldLogin() throws {
        let binding = PacerSessionBinding(trail: Self.trail, desktopAccounts: [:], switches: Self.switched)
        #expect(binding.hasUnfollowedChange(now: Self.now))
        // Started an hour ago: it followed the switch to B, not the /login.
        let doubt = try #require(binding.mayStillBill(startedAt: Self.ago(3_600), current: orgC, now: Self.now))
        #expect(doubt.accounts == [orgB])
        #expect(doubt.since == Self.ago(600))
        // Started before both: still only B. The switch to B is one it followed.
        #expect(binding.mayStillBill(startedAt: nil, current: orgC, now: Self.now)?.accounts == [orgB])
        // Started after the /login: it read the new login when it began.
        #expect(binding.mayStillBill(startedAt: Self.ago(300), current: orgC, now: Self.now) == nil)
    }

    @Test func aChangeASwitcherMadeLeavesNoDoubt() {
        let both = LoginSwitchEvidence(switches: Self.switched.switches + [.init(at: Self.ago(599), accountId: orgC)])
        let binding = PacerSessionBinding(trail: Self.trail, desktopAccounts: [:], switches: both)
        #expect(!binding.hasUnfollowedChange(now: Self.now))
        #expect(binding.mayStillBill(startedAt: nil, current: orgC, now: Self.now) == nil)
    }

    @Test func withoutAnySwitcherEveryChangeSinceTheSessionBeganCounts() {
        // Someone who only ever uses /login: A → B → C, a session from before both.
        let binding = PacerSessionBinding(trail: Self.trail, desktopAccounts: [:])
        #expect(binding.mayStillBill(startedAt: Self.ago(10_000), current: orgC, now: Self.now)?.accounts == [orgB, orgA])
        #expect(binding.mayStillBill(startedAt: Self.ago(3_600), current: orgC, now: Self.now)?.accounts == [orgB])
    }

    @Test func aChangeOlderThanTheHorizonIsNotAskedAbout() {
        let later = Self.now.addingTimeInterval(PacerSessionBinding.loginChangeHorizon)
        let binding = PacerSessionBinding(trail: Self.trail, desktopAccounts: [:], switches: Self.switched)
        #expect(!binding.hasUnfollowedChange(now: later))
        #expect(binding.mayStillBill(startedAt: nil, current: orgC, now: later) == nil)
    }

    // MARK: - Through the session lookup

    static func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Account.self, AccountSessionInfo.self, ProjectMeta.self,
            AccountActivation.self, AccountDailyAggregate.self, DailyAggregate.self,
            SessionInfo.self, TokenSample.self, ClaudeCodeMeta.self,
            RateLimitSample.self, UsageLimitSample.self, ExtraUsageSample.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    /// B until ten minutes ago, C since. `before` wrote twenty minutes ago and
    /// again a minute ago; `after` began five minutes ago.
    @MainActor
    static func seed(_ context: ModelContext, withSessionRows: Bool = true) {
        context.insert(AccountActivation(accountId: orgB, startedAt: ago(86_400), endedAt: ago(600),
                                         source: AccountActivation.sourceObserved))
        context.insert(AccountActivation(accountId: orgC, startedAt: ago(600),
                                         source: AccountActivation.sourceObserved))
        for (session, at, account) in [("before", 1_200.0, orgB), ("before", 60.0, orgC), ("after", 300.0, orgC)] {
            let when = ago(at)
            let sample = TokenSample(
                sampledAt: when, date: TokenSample.formatDate(when), model: "claude-opus-5",
                inputTokens: 10, outputTokens: 20, cacheReadTokens: 0,
                cacheCreation5mTokens: 0, cacheCreation1hTokens: 0,
                sessionId: session, projectPath: "/tmp/acme")
            sample.accountId = account
            context.insert(sample)
        }
        if withSessionRows {
            for (session, first) in [("before", 1_200.0), ("after", 300.0)] {
                context.insert(AccountSessionInfo(
                    accountId: orgC, sessionId: session, firstSeenAt: ago(first), lastSeenAt: ago(60),
                    projectPath: "/tmp/acme", ccVersion: nil, cumulativeCostUSD: 0,
                    cumulativeInputTokens: 10, cumulativeOutputTokens: 20,
                    cumulativeCacheReadTokens: 0, cumulativeCacheCreation5mTokens: 0,
                    cumulativeCacheCreation1hTokens: 0, topModel: "claude-opus-5"))
                context.insert(SessionInfo(
                    sessionId: session, firstSeenAt: ago(first), lastSeenAt: ago(60),
                    projectPath: "/tmp/acme", topModel: "claude-opus-5"))
            }
        }
        try? context.save()
    }

    @MainActor
    @Test func theLookupSaysWhichLoginsASessionMayStillBill() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        Self.seed(context)
        let binding = PacerSessionBinding(trail: AccountParallelism.trail(context: context), desktopAccounts: [:])
        func lookup(_ id: String) -> PacerSessionLookup? {
            PacerSessionLookupBuilder.lookup(context: context, sessionId: id, binding: binding, now: Self.now)
        }
        let before = try #require(lookup("before"))
        // Where it bills if it followed is unchanged; the doubt is beside it.
        #expect(before.currentAccountId == orgC)
        #expect(before.mayStillBillAccountIds == [orgB])
        #expect(before.mayStillBillSince == Self.ago(600))
        #expect(try before.encodedJSON().contains("\"mayStillBillAccountIds\" : ["))
        let after = try #require(lookup("after"))
        #expect(after.mayStillBillAccountIds == nil)
        #expect(try !after.encodedJSON().contains("mayStillBill"))

        // A switcher that made the change: no doubt.
        let explained = PacerSessionBinding(
            trail: binding.trail, desktopAccounts: [:],
            switches: LoginSwitchEvidence(switches: [.init(at: Self.ago(601), accountId: orgC)]))
        #expect(PacerSessionLookupBuilder.lookup(context: context, sessionId: "before", binding: explained,
                                                 now: Self.now)?.mayStillBillAccountIds == nil)
    }

    @Test func theSnapshotsRawReadKnowsWhenASessionBegan() {
        let binding = PacerSessionBinding(trail: AccountTrail(spans: [
            Self.span(orgB, 86_400, 600), Self.span(orgC, 600, nil),
        ]), desktopAccounts: [:])
        let liveSince = Self.now.addingTimeInterval(-PacerSessionLookupBuilder.snapshotWindow)
        func turn(_ ago: TimeInterval, _ account: String) -> PacerSessionTurn {
            PacerSessionTurn(sampledAt: Self.ago(ago), model: "claude-opus-5", accountId: account, projectPath: "/tmp/acme")
        }
        // Newest first, as the read returns them. `old` has a turn in the
        // margin read before the window, so it may be older still.
        let rows: [(sessionId: String, turn: PacerSessionTurn)] = [
            ("before", turn(60, orgC)), ("after", turn(120, orgC)), ("old", turn(180, orgC)),
            ("after", turn(300, orgC)), ("before", turn(1_200, orgB)),
            ("old", turn(PacerSessionLookupBuilder.snapshotWindow + 60, orgB)),
        ]
        let answers = PacerSessionLookupBuilder.answers(rows: rows, liveSince: liveSince,
                                                        binding: binding, now: Self.now)
        #expect(answers["before"]?.mayStillBillAccountIds == [orgB])
        #expect(answers["after"]?.mayStillBillAccountIds == nil)
        #expect(answers["old"]?.mayStillBillAccountIds == [orgB])
    }

    @MainActor
    @Test func theSnapshotAnswersTheDoubtAsTheStoreDoes() throws {
        let container = try Self.makeContainer()
        Self.seed(ModelContext(container))
        let snapshot = try PacerAPISnapshot.build(container: container, activeAccountId: orgC,
                                                  desktop: nil, now: Self.now)
        for id in ["before", "after"] {
            let context = ModelContext(container)
            let stored = try #require(PacerSessionLookupBuilder.lookup(
                context: context, sessionId: id, binding: .load(context: context, desktop: nil), now: Self.now))
            let cached = try #require(snapshot.session(id: id, at: Self.now))
            #expect(try cached.encodedJSON() == stored.encodedJSON())
        }
        #expect(snapshot.session(id: "before", at: Self.now)?.mayStillBillAccountIds == [orgB])
    }

    @MainActor
    @Test func theSessionListShowsTheDoubtOnActiveSessions() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        Self.seed(context)
        let list = try PacerSessionLookupBuilder.list(container: container, withinSeconds: 3_600,
                                                      account: nil, now: Self.now, desktop: nil)
        let doubt = Dictionary(uniqueKeysWithValues: list.sessions.map { ($0.sessionId, $0.mayStillBillAccountIds) })
        #expect(doubt["before"] == .some([orgB]))
        #expect(doubt["after"] == .some(nil))
        // Asked who is drawing on the old login, the one that may be is listed.
        let onB = try PacerSessionLookupBuilder.list(container: container, withinSeconds: 3_600,
                                                     account: orgB, now: Self.now, desktop: nil)
        #expect(onB.sessions.map(\.sessionId) == ["before"])
    }
}
