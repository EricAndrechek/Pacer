import Foundation
import SwiftData
import Testing
@testable import PacerCore

// The bug these pin down: `~/.claude.json`'s `oauthAccount` was the only
// source for "who is the default login", and it is rewritten by any Claude
// Code process sharing the root — including one holding an identity from
// before the last switch. The keychain credential never moved, the CLI kept
// billing it, and every turn afterwards was attributed to an account serving
// no requests. The credential now outranks the file.

private func makeContainer() throws -> ModelContainer {
    try ModelContainer(
        for: AccountActivation.self, Account.self, TokenSample.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
}

private func makeHome() throws -> URL {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

private func writeConfig(_ home: URL, org: String, modified: Date) throws {
    let url = home.appendingPathComponent(".claude.json")
    try "{\"oauthAccount\":{\"organizationUuid\":\"\(org)\"}}"
        .write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
}

private func t(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

private func reading(_ key: String?, since: TimeInterval, readAt: TimeInterval) -> SignedInCredentialReading {
    SignedInCredentialReading(accountKey: key, readAt: t(readAt), since: t(since))
}

private func spans(_ context: ModelContext) throws -> [AccountActivation] {
    try context.fetch(FetchDescriptor<AccountActivation>(sortBy: [SortDescriptor(\.startedAt)]))
}

private func makeSample(_ when: Date, account: String?) -> TokenSample {
    let s = TokenSample(
        sampledAt: when,
        date: TokenSample.formatDate(when),
        model: "claude-opus-5",
        inputTokens: 1, outputTokens: 1,
        cacheReadTokens: 0, cacheCreation5mTokens: 0, cacheCreation1hTokens: 0)
    s.accountId = account
    return s
}

@Suite("Signed-in credential outranks the config file")
@ScanActor
struct SignedInCredentialAttributionTests {

    /// A trail whose default login is `signed-in`, observed from the file.
    private func setUp() throws -> (URL, ModelContext, AccountTrailRecorder) {
        let home = try makeHome()
        let context = ModelContext(try makeContainer())
        let recorder = AccountTrailRecorder(context: context, homeDirectory: home)
        try writeConfig(home, org: "signed-in", modified: t(1_000))
        _ = recorder.poll(now: t(1_000))
        return (home, context, recorder)
    }

    @Test("a stale config write is ignored when the keychain was read after it")
    func staleWriteIsIgnored() throws {
        let (home, context, recorder) = try setUp()
        try writeConfig(home, org: "idle", modified: t(2_000))

        let key = recorder.poll(now: t(2_000),
                                credential: reading("signed-in", since: 500, readAt: 2_500))

        #expect(key == "signed-in")
        #expect(!recorder.needsCredentialCheck)
        let rows = try spans(context)
        #expect(rows.count == 1)
        #expect(rows[0].accountId == "signed-in")
        #expect(rows[0].endedAt == nil)
        #expect(recorder.drainCorrections().isEmpty)
    }

    @Test("a disagreeing config waits for a keychain read and, if real, starts at its sighting")
    func realSwitchIsHeldThenBackdated() throws {
        let (home, _, recorder) = try setUp()
        try writeConfig(home, org: "next", modified: t(2_000))

        // The last keychain read predates the write: no verdict yet.
        let held = recorder.poll(now: t(2_000),
                                 credential: reading("signed-in", since: 500, readAt: 1_500))
        #expect(held == "signed-in")
        #expect(recorder.needsCredentialCheck)

        // The re-read finds the new account's token. The file has not changed
        // again, so this is the unchanged-mtime path re-deciding the held one.
        let key = recorder.poll(now: t(2_100),
                                credential: reading("next", since: 2_050, readAt: 2_050))
        #expect(key == "next")
        #expect(!recorder.needsCredentialCheck)
        #expect(recorder.trail().accountId(at: t(2_000)) == "next")
        #expect(recorder.trail().accountId(at: t(1_999)) == "signed-in")
        // Turns parsed while it was held were stamped with the old account.
        #expect(recorder.drainCorrections() == [AccountTrailRecorder.Correction(
            from: t(2_000), to: nil, wrongAccount: "signed-in", rightAccount: "next")])
    }

    @Test("an unresolved new token cannot veto a switch")
    func unknownTokenAcceptsTheFile() throws {
        let (home, _, recorder) = try setUp()
        try writeConfig(home, org: "next", modified: t(2_000))
        let key = recorder.poll(now: t(2_000),
                                credential: reading(nil, since: 2_010, readAt: 2_010))
        #expect(key == "next")
    }

    @Test("a held observation is dropped when the re-read shows the same credential")
    func heldObservationIsRefuted() throws {
        let (home, context, recorder) = try setUp()
        try writeConfig(home, org: "idle", modified: t(2_000))
        _ = recorder.poll(now: t(2_000),
                          credential: reading("signed-in", since: 500, readAt: 1_500))
        let key = recorder.poll(now: t(2_100),
                                credential: reading("signed-in", since: 500, readAt: 2_050))
        #expect(key == "signed-in")
        #expect(try spans(context).count == 1)
        #expect(recorder.drainCorrections().isEmpty)
    }

    @Test("an unverifiable observation is accepted after the timeout, backdated")
    func timeoutAcceptsBackdated() throws {
        let (home, _, recorder) = try setUp()
        try writeConfig(home, org: "next", modified: t(2_000))
        let stale = reading("signed-in", since: 500, readAt: 1_500)
        _ = recorder.poll(now: t(2_000), credential: stale)
        let late = 2_000 + AccountTrailRecorder.credentialVerificationTimeout
        let key = recorder.poll(now: t(late), credential: stale)
        #expect(key == "next")
        #expect(recorder.trail().accountId(at: t(2_000)) == "next")
    }

    /// The machine state that surfaced the bug: a span already opened by a
    /// stale write, with the credential reading the same account across it.
    @Test("reconcile refutes a span a stale write opened, from its start")
    func reconcileRefutesStaleSpan() throws {
        let (home, context, recorder) = try setUp()
        try writeConfig(home, org: "idle", modified: t(2_000))
        _ = recorder.poll(now: t(2_000))   // no credential yet: recorded as before
        #expect(recorder.trail().accountId(at: t(2_500)) == "idle")

        recorder.reconcile(with: reading("signed-in", since: 500, readAt: 3_000))

        let trail = recorder.trail()
        #expect(trail.accountId(at: t(2_500)) == "signed-in")
        #expect(trail.accountId(at: t(9_000)) == "signed-in")
        #expect(trail.currentDefaultLogin?.accountId == "signed-in")
        #expect(recorder.drainCorrections() == [AccountTrailRecorder.Correction(
            from: t(2_000), to: nil, wrongAccount: "idle", rightAccount: "signed-in")])
        // The refuted span is kept for the record, covering nothing.
        let refuted = try spans(context).first { $0.accountId == "idle" }
        #expect(refuted?.endedAt == refuted?.startedAt)
        #expect(refuted?.evidence?.contains("refuted") == true)

        // Idempotent: a second pass finds nothing left to correct.
        recorder.reconcile(with: reading("signed-in", since: 500, readAt: 3_100))
        #expect(recorder.drainCorrections().isEmpty)
    }

    @Test("reconcile leaves a span newer than the last keychain read alone")
    func reconcileSparesUnverifiedSwitch() throws {
        let (home, _, recorder) = try setUp()
        try writeConfig(home, org: "next", modified: t(2_000))
        _ = recorder.poll(now: t(2_000))
        recorder.reconcile(with: reading("signed-in", since: 500, readAt: 1_500))
        #expect(recorder.trail().accountId(at: t(2_500)) == "next")
        #expect(recorder.drainCorrections().isEmpty)
    }

    @Test("reconcile cuts an older span off where the credential's run began")
    func reconcileTruncatesAtSince() throws {
        let (_, context, recorder) = try setUp()   // "signed-in" from 1_000
        recorder.reconcile(with: reading("other", since: 2_000, readAt: 3_000))
        #expect(recorder.trail().accountId(at: t(1_500)) == "signed-in")
        #expect(recorder.trail().accountId(at: t(2_500)) == "other")
        #expect(try spans(context).first { $0.accountId == "signed-in" }?.endedAt == t(2_000))
    }

    @Test("reconcile never overrides a range the user assigned")
    func reconcileRespectsManualRanges() throws {
        let context = ModelContext(try makeContainer())
        context.insert(AccountActivation(
            accountId: "assigned", startedAt: t(0), endedAt: nil,
            source: AccountActivation.sourceManual))
        let recorder = AccountTrailRecorder(context: context, homeDirectory: try makeHome())
        recorder.reconcile(with: reading("signed-in", since: 500, readAt: 3_000))
        #expect(recorder.trail().accountId(at: t(1_000)) == "assigned")
        #expect(recorder.drainCorrections().isEmpty)
    }

    @Test("stored turns move to the corrected account; others and pinned ones stay")
    func restampMovesOnlyRefutedTurns() throws {
        let context = ModelContext(try makeContainer())
        let before = makeSample(t(1_500), account: "idle")     // outside the range
        let wrong = makeSample(t(2_500), account: "idle")      // inside: moves
        let right = makeSample(t(2_600), account: "signed-in") // already right
        let pinned = makeSample(t(2_700), account: "pinned")   // a pinned profile's
        for s in [before, wrong, right, pinned] { context.insert(s) }
        try context.save()

        let trail = AccountTrail(spans: [
            .init(accountId: "pinned", startedAt: t(0), endedAt: nil, rootPath: "/profiles/2"),
        ])
        let moved = try AccountBackfill.restamp([
            .init(from: t(2_000), to: nil, wrongAccount: "idle", rightAccount: "signed-in"),
            .init(from: t(2_000), to: nil, wrongAccount: "pinned", rightAccount: "signed-in"),
        ], trail: trail, context: context)

        #expect(moved.count == 1)
        #expect(before.accountId == "idle")
        #expect(wrong.accountId == "signed-in")
        #expect(right.accountId == "signed-in")
        #expect(pinned.accountId == "pinned")
    }
}

@Suite("Signed-in credential monitor")
struct SignedInCredentialMonitorTests {
    @Test("the run start is kept while the account holds, and restarts when it changes")
    func sinceTracksTheRun() {
        let monitor = SignedInCredentialMonitor()
        monitor.publish(accountKey: "a", readAt: t(100))
        monitor.publish(accountKey: "a", readAt: t(200))
        #expect(monitor.current == reading("a", since: 100, readAt: 200))

        monitor.publish(accountKey: nil, readAt: t(300))   // new, unresolved token
        #expect(monitor.current == reading(nil, since: 300, readAt: 300))
        monitor.publish(accountKey: "b", readAt: t(300))   // …resolved by its poll
        #expect(monitor.current == reading("b", since: 300, readAt: 300))
    }

    @Test("an older read never rewinds a newer one")
    func olderReadIsIgnored() {
        let monitor = SignedInCredentialMonitor()
        monitor.publish(accountKey: "a", readAt: t(200))
        monitor.publish(accountKey: "b", readAt: t(100))
        #expect(monitor.current == reading("a", since: 200, readAt: 200))
    }
}

@Suite("Signed-in credential at launch")
@ScanActor
struct SignedInCredentialLaunchTests {
    @Test("before the first keychain read, a disagreeing config is held, not accepted")
    func launchHoldsUntilTheCredentialArrives() throws {
        let home = try makeHome()
        let context = ModelContext(try makeContainer())
        let recorder = AccountTrailRecorder(context: context, homeDirectory: home)
        try writeConfig(home, org: "signed-in", modified: t(1_000))
        _ = recorder.poll(now: t(1_000))

        // Relaunch: the file now carries a stale identity and the poller has
        // not read the keychain yet.
        try writeConfig(home, org: "idle", modified: t(2_000))
        let held = recorder.poll(now: t(2_000), credential: nil, credentialExpected: true)
        #expect(held == "signed-in")
        #expect(recorder.needsCredentialCheck)

        let key = recorder.poll(now: t(2_010),
                                credential: reading("signed-in", since: 2_005, readAt: 2_005),
                                credentialExpected: true)
        #expect(key == "signed-in")
        #expect(try spans(context).count == 1)
    }

    @Test("with no poller at all, the file is still the only source")
    func noPollerKeepsTheOldBehaviour() throws {
        let home = try makeHome()
        let context = ModelContext(try makeContainer())
        let recorder = AccountTrailRecorder(context: context, homeDirectory: home)
        try writeConfig(home, org: "a", modified: t(1_000))
        _ = recorder.poll(now: t(1_000))
        try writeConfig(home, org: "b", modified: t(2_000))
        #expect(recorder.poll(now: t(2_000)) == "b")
    }
}
