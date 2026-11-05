import Foundation
import PacerCore
import Testing
@testable import PacerPace

/// #343: a verdict records the account it judged and the default login it was
/// gated under, and `status` re-gates one the login has moved away from. The
/// login comes from `DefaultLoginMarker`, a file the app writes, so a `status`
/// whose verdict is still good asks Pacer nothing. Fictional accounts.
@Suite("pace: a verdict belongs to the login it was gated under")
struct PaceLoginChangeTests {

    /// `org-work` is the active login with room; `org-home` is at 99%.
    static func metrics(active: String) -> String {
        """
        pacer_rate_limit_used_ratio{account="org-work",window="five_hour"} 0.12
        pacer_rate_limit_reset_seconds{account="org-work",window="five_hour"} 6000
        pacer_rate_limit_used_ratio{account="org-home",window="five_hour"} 0.99
        pacer_rate_limit_reset_seconds{account="org-home",window="five_hour"} 900
        pacer_account_info{account="org-work",name="w",active="\(active == "org-work")"} 1
        pacer_account_info{account="org-home",name="h",active="\(active == "org-home")"} 1
        """
    }

    /// The marker as the app writes it: the login, and when it changed.
    final class Login: @unchecked Sendable {
        private let lock = NSLock()
        private var value: DefaultLoginMarker?
        init(_ account: String?, changed: TimeInterval = -3_600) { set(account, changed: changed) }
        func set(_ account: String?, changed: TimeInterval = -3_600) {
            lock.withLock {
                value = account.map {
                    DefaultLoginMarker(accountId: $0, since: Date().addingTimeInterval(changed),
                                       changedAt: Date().addingTimeInterval(changed))
                }
            }
        }
        var read: () -> DefaultLoginMarker? { { [self] in lock.withLock { value } } }
    }

    @Test func aGoGatedForTheOldLoginIsReGatedAfterASwitch() throws {
        let box = try PaceSandbox(metrics: Self.metrics(active: "org-work"))
        let login = Login("org-work")
        let gate = runPace(box, ["gate", "--model", "opus"], marker: login.read)
        #expect(gate.status == 0, "\(gate.out)")
        #expect(box.stateText.contains("\"account\": \"org-work\""))
        #expect(box.stateText.contains("\"login\": \"org-work\""))
        #expect(box.stateText.contains("\"followsLogin\": true"))

        // The login switches onto the account at 99%. Seconds later the
        // verdict is still fresh by age; it is about the wrong account.
        try box.setMetrics(Self.metrics(active: "org-home"))
        login.set("org-home")
        let log = PaceRequestLog()
        let status = runPace(box, ["status"], onGet: log.record, marker: login.read)
        #expect(status.status == 10, "\(status.out)")
        #expect(status.out.contains("the login moved to org-home — re-gated"), "\(status.out)")
        #expect(status.out.contains("paused: 5h at 99%"), "\(status.out)")
        #expect(log.count("metrics") == 1)
        #expect(box.stateText.contains("\"account\": \"org-home\""))
        #expect(box.stateText.contains("\"login\": \"org-home\""))
        // And the re-gated verdict is fresh: the next reader reads only the file.
        let next = PaceRequestLog()
        #expect(runPace(box, ["status"], onGet: next.record, marker: login.read).status == 10)
        #expect(next.all.isEmpty, "\(next.all)")
    }

    @Test func statusAsksNothingWhileTheLoginStays() throws {
        let box = try PaceSandbox(metrics: Self.metrics(active: "org-work"))
        let login = Login("org-work")
        _ = runPace(box, ["gate", "--model", "opus"], marker: login.read)
        let log = PaceRequestLog()
        let status = runPace(box, ["status"], onGet: log.record, marker: login.read)
        #expect(status.status == 0, "\(status.out)")
        #expect(log.all.isEmpty, "\(log.all)")
    }

    @Test func noRefreshSaysTheLoginMovedAndReadsNothing() throws {
        let box = try PaceSandbox(metrics: Self.metrics(active: "org-work"))
        let login = Login("org-work")
        _ = runPace(box, ["gate", "--model", "opus"], marker: login.read)
        login.set("org-home")
        let before = box.stateText
        let log = PaceRequestLog()
        let status = runPace(box, ["status", "--no-refresh"], onGet: log.record, marker: login.read)
        #expect(status.status == 3)
        #expect(status.out.hasPrefix("stale: the login moved to org-home since this verdict was gated (it was gated for org-work)"),
                "\(status.out)")
        #expect(log.all.isEmpty)
        #expect(box.stateText == before)
    }

    @Test func withoutAMarkerNothingChanges() throws {
        let box = try PaceSandbox(metrics: Self.metrics(active: "org-work"))
        _ = runPace(box, ["gate", "--model", "opus"])
        #expect(box.stateText.contains("\"login\": \"\""))
        try box.setMetrics(Self.metrics(active: "org-home"))
        let log = PaceRequestLog()
        // No app writing the login down: the verdict lives out its shelf life,
        // as it always did.
        #expect(runPace(box, ["status"], onGet: log.record).status == 0)
        #expect(log.all.isEmpty)
    }

    @Test func aVerdictFromBeforeTheMarkerIsReGatedOnce() throws {
        let box = try PaceSandbox(metrics: Self.metrics(active: "org-work"))
        _ = runPace(box, ["gate", "--model", "opus"])
        // A verdict written before there was a login to record (or by a
        // build that did not record one) cannot say it is still the login's.
        let text = box.stateText.split(separator: "\n")
            .filter { !$0.contains("\"login\"") && !$0.contains("\"followsLogin\"") }
            .joined(separator: "\n")
        try text.write(to: box.stateURL, atomically: true, encoding: .utf8)
        let login = Login("org-work")
        let log = PaceRequestLog()
        let first = runPace(box, ["status"], onGet: log.record, marker: login.read)
        #expect(first.status == 0, "\(first.out)")
        #expect(first.out.contains("re-gated"), "\(first.out)")
        #expect(log.count("metrics") == 1)
        #expect(runPace(box, ["status"], onGet: log.record, marker: login.read).status == 0)
        #expect(log.count("metrics") == 1, "once is enough")
    }

    @Test func aPinnedProfilesVerdictDoesNotFollowTheDefaultLogin() throws {
        let box = try PaceSandbox(metrics: Self.metrics(active: "org-work"))
        let login = Login("org-work")
        let pinned = ["CLAUDE_CONFIG_DIR": box.dir.appendingPathComponent("profile").path]
        _ = runPace(box, ["gate", "--model", "opus", "--window", "5h"], extra: pinned, marker: login.read)
        #expect(box.stateText.contains("\"followsLogin\": false"))
        login.set("org-home")
        let log = PaceRequestLog()
        _ = runPace(box, ["status"], extra: pinned, onGet: log.record, marker: login.read)
        #expect(log.all.isEmpty, "a profile's own login did not move: \(log.all)")
    }

    @Test func anExplicitAccountIsKeptByARefreshAndRefusedForAnother() throws {
        let box = try PaceSandbox(metrics: Self.metrics(active: "org-work"))
        _ = runPace(box, ["gate", "--account", "org-home", "--model", "opus"])
        #expect(box.stateText.contains("\"accountFlag\": \"org-home\""))
        #expect(box.stateText.contains("\"followsLogin\": false"))
        try age(box, by: 7200)
        // A bare reader refreshing it re-gates the account the gate was told,
        // not this session's login.
        let refreshed = runPace(box, ["status"])
        #expect(refreshed.status == 10, "\(refreshed.out)")
        #expect(box.stateText.contains("\"account\": \"org-home\""))
        // A reader asking about another account is not handed this verdict.
        let other = runPace(box, ["status", "--account", "org-work"])
        #expect(other.status == 3)
        #expect(other.out.hasPrefix("unknown: last gate was for account 'org-home', not 'org-work'"), "\(other.out)")
    }

    // MARK: - The data catching up with a switch

    @Test func aGateWaitsForPacersDataToCatchUpWithAFreshSwitch() throws {
        let box = try PaceSandbox(metrics: Self.metrics(active: "org-work"))
        // The app wrote the new login a second ago; its API snapshot still
        // names the old one for one more look.
        let login = Login("org-home", changed: -1)
        var naps = 0
        let gate = runPace(box, ["gate", "--model", "opus"], nap: { _ in
            naps += 1
            if naps == 2 { try? box.setMetrics(Self.metrics(active: "org-home")) }
        }, marker: login.read)
        #expect(gate.status == 10, "judged on the new login: \(gate.out)")
        #expect(naps == 2)
        #expect(box.stateText.contains("\"account\": \"org-home\""))
        #expect(!gate.out.contains("moments ago"), "\(gate.out)")
    }

    @Test func dataThatNeverCatchesUpGivesAShortGoThatSaysSo() throws {
        let box = try PaceSandbox(metrics: Self.metrics(active: "org-work"))
        let login = Login("org-home", changed: -1)
        var naps = 0
        let gate = runPace(box, ["gate", "--model", "opus"], nap: { _ in naps += 1 }, marker: login.read)
        #expect(gate.status == 0, "\(gate.out)")
        #expect(naps == PaceRun.loginCatchUpLooks)
        #expect(gate.out.contains("the login moved to org-home moments ago and Pacer's data still says org-work"),
                "\(gate.out)")
        let state = PaceStateFile(path: box.stateURL.path)
        let until = try #require(state.goUntil)
        #expect(until.timeIntervalSinceNow <= PaceRun.laggingGoLife + 1)
        // Recorded under the new login, so readers do not re-gate it on every
        // call while they wait out its minute.
        #expect(box.stateText.contains("\"login\": \"org-home\""))
        let log = PaceRequestLog()
        #expect(runPace(box, ["status"], onGet: log.record, marker: login.read).status == 0)
        #expect(log.all.isEmpty)
    }

    @Test func aLastingDisagreementIsNotWaitedFor() throws {
        // A pick in Settings moves the active account and not the login. A
        // gate long after the login last moved does not wait for them to agree.
        let box = try PaceSandbox(metrics: Self.metrics(active: "org-work"))
        let login = Login("org-home", changed: -600)
        var naps = 0
        let gate = runPace(box, ["gate", "--model", "opus"], nap: { _ in naps += 1 }, marker: login.read)
        #expect(gate.status == 0, "\(gate.out)")
        #expect(naps == 0)
        #expect(!gate.out.contains("moments ago"))
    }
}
