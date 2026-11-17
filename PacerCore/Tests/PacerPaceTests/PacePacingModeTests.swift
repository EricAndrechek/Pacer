import Foundation
import PacerCore
import Testing
@testable import PacerPace

/// Gate-only and informed pacing (`PacingMode`), and what a pause says when
/// another login can end it (`PaceRotation`, `PaceSwitchOutlook`).
///
/// Agents planned with the gate's numbers: a login at 68% of its week made
/// them keep fan-outs lean and pick weaker models, with two other logins
/// idle. Inside a session the gate now says go or pause and how to wait,
/// nothing more; a person in a terminal still gets the numbers. Fictional
/// accounts.
@Suite("pace: pacing modes and switch-aware pauses")
struct PacePacingModeTests {

    static let session = "0f3c9a12-aaaa-bbbb-cccc-1234567890ab"

    static func login(_ name: String, active: Bool, five: Double? = nil, seven: Double,
                      fiveReset: Int = 6000, sevenReset: Int = 400_000) -> String {
        var text = "pacer_account_info{account=\"\(name)\",name=\"x\",active=\"\(active)\"} 1\n"
        if let five {
            text += "pacer_rate_limit_used_ratio{account=\"\(name)\",window=\"five_hour\"} \(five)\n"
            text += "pacer_rate_limit_reset_seconds{account=\"\(name)\",window=\"five_hour\"} \(fiveReset)\n"
        }
        text += "pacer_rate_limit_used_ratio{account=\"\(name)\",window=\"seven_day\"} \(seven)\n"
        text += "pacer_rate_limit_reset_seconds{account=\"\(name)\",window=\"seven_day\"} \(sevenReset)\n"
        return text
    }

    /// The active login with room: GO.
    static let roomy = login("acct-main0000", active: true, five: 0.12, seven: 0.32)
        + login("acct-other000", active: false, five: 0.1, seven: 0.1)
    /// The active login at its 5-hour limit, another with room.
    static let fiveFull = login("acct-main0000", active: true, five: 0.99, seven: 0.32)
        + login("acct-other000", active: false, five: 0.1, seven: 0.1)
    /// An Ultra-style login at its weekly limit, resetting days away, and
    /// another with room: the case `wait` used to give up on at once.
    static let weekFull = login("acct-main0000", active: true, seven: 0.99, sevenReset: 300_000)
        + login("acct-other000", active: false, seven: 0.11)
    /// The same switched: the other login is now the active one.
    static let weekSwitched = login("acct-main0000", active: false, seven: 0.99, sevenReset: 300_000)
        + login("acct-other000", active: true, seven: 0.11)
    /// Alone at its weekly limit.
    static let weekFullAlone = login("acct-main0000", active: true, seven: 0.99, sevenReset: 300_000)

    /// A session's environment with the mode left to its own default.
    static func inSession(_ more: [String: String] = [:]) -> [String: String] {
        ["CLAUDE_CODE_SESSION_ID": session, "PACER_PACING": ""].merging(more) { $1 }
    }

    static func heartbeat(_ box: PaceSandbox, holding: Bool = false, targets: [String] = ["acct-oth"],
                          age: TimeInterval = 10) throws {
        let dir = box.dir.appendingPathComponent(".claude/pace")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = PaceFormat.utcStamp(Date().addingTimeInterval(-age))
        let list = targets.map { "\"\($0)\"" }.joined(separator: ", ")
        try "{\"v\": 1, \"updatedAt\": \"\(stamp)\", \"active\": \"acct-mai\", \"holding\": \(holding), \"targets\": [\(list)]}\n"
            .write(to: dir.appendingPathComponent("rotation.json"), atomically: true, encoding: .utf8)
    }

    static func hasPercent(_ text: String) -> Bool {
        text.range(of: #"\d+(\.\d+)?%"#, options: .regularExpression) != nil
    }

    // MARK: - Which mode

    @Test func theModeComesFromTheFlagThenTheSessionFileThenTheEnvironmentThenTheDefault() throws {
        let home = "/tmp/pace-home-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let file = try #require(PaceModeFile.path(home: home, sessionId: Self.session))
        let session = ["CLAUDE_CODE_SESSION_ID": Self.session]

        #expect(try PacingMode.resolve(flag: nil, environment: session, sessionFile: file) == (.gate, .sessionDefault))
        #expect(try PacingMode.resolve(flag: nil, environment: [:], sessionFile: nil) == (.informed, .terminalDefault))
        let repo = session.merging(["PACER_PACING": "informed"]) { $1 }
        #expect(try PacingMode.resolve(flag: nil, environment: repo, sessionFile: file) == (.informed, .environment))

        #expect(PaceModeFile(path: file).write(.gate, now: Date()))
        #expect(try PacingMode.resolve(flag: nil, environment: repo, sessionFile: file) == (.gate, .sessionFile))
        #expect(try PacingMode.resolve(flag: "informed", environment: repo, sessionFile: file) == (.informed, .flag))
        #expect(throws: (any Error).self) { try PacingMode.resolve(flag: "loud", environment: [:], sessionFile: nil) }
    }

    @Test func aBadPacingValueIsAnError() throws {
        let box = try PaceSandbox(metrics: Self.roomy)
        let bad = runPace(box, ["gate"], extra: ["PACER_PACING": "chatty"])
        #expect(bad.status == 1, "\(bad.out)")
        #expect(bad.out.contains("PACER_PACING 'chatty' is not a pacing mode"), "\(bad.out)")
    }

    @Test func pacerModeSetsPrintsAndClearsTheSessionsChoice() throws {
        let box = try PaceSandbox(metrics: Self.roomy)
        let shown = runPace(box, ["mode"], extra: Self.inSession())
        #expect(shown.out.hasPrefix("pacing: gate-only (the default inside a Claude Code session)"), "\(shown.out)")

        let set = runPace(box, ["mode", "informed"], extra: Self.inSession())
        #expect(set.status == 0)
        #expect(set.out.hasPrefix("pacing: informed (set for this session with `pacer mode`)"), "\(set.out)")
        let go = runPace(box, ["gate"], extra: Self.inSession())
        #expect(go.out.contains("pace: GO — 5h 12%"), "\(go.out)")
        #expect(go.out.contains("Informed pacing is on"), "\(go.out)")

        _ = runPace(box, ["mode", "clear"], extra: Self.inSession())
        #expect(runPace(box, ["gate"], extra: Self.inSession()).out.hasPrefix("pace: GO."))

        // Another session is not affected by this one's choice.
        _ = runPace(box, ["mode", "informed"], extra: Self.inSession())
        let other = runPace(box, ["gate"], extra: Self.inSession(["CLAUDE_CODE_SESSION_ID": "77aa0000-1111"]))
        #expect(other.out.hasPrefix("pace: GO."), "\(other.out)")
    }

    @Test func pacerModeOutsideASessionPointsAtTheEnvironment() throws {
        let box = try PaceSandbox(metrics: Self.roomy)
        let result = runPace(box, ["mode", "informed"])
        #expect(result.status == 1)
        #expect(result.out.contains("Set PACER_PACING=gate or informed instead"), "\(result.out)")
        #expect(runPace(box, ["mode"]).out.hasPrefix("pacing: informed (the default outside a Claude Code session)"))
    }

    // MARK: - What gate-only says

    @Test func aGateOnlyGoIsJustGo() throws {
        let box = try PaceSandbox(metrics: Self.login("acct-main0000", active: true, five: 0.12, seven: 0.32))
        let result = runPace(box, ["gate", "--model", "opus"], extra: Self.inSession())
        #expect(result.status == 0)
        #expect(result.out == "pace: GO.\n", "\(result.out)")
        // With several logins and a session Pacer cannot place, it still says
        // whose verdict this is, without a number.
        let several = runPace(try PaceSandbox(metrics: Self.roomy), ["gate", "--model", "opus"], extra: Self.inSession())
        #expect(several.out.hasPrefix("pace: GO. (2 accounts signed in and this session could not be identified — this verdict is about the active login"),
                "\(several.out)")
        #expect(!Self.hasPercent(several.out), "\(several.out)")
    }

    @Test func aTerminalStillGetsTheNumbers() throws {
        let box = try PaceSandbox(metrics: Self.roomy)
        let result = runPace(box, ["gate"])
        #expect(result.out.hasPrefix("pace: GO — 5h 12%, 7d 32%"), "\(result.out)")
        #expect(!result.out.contains("Informed pacing is on"), "\(result.out)")
    }

    @Test func aGateOnlyPauseNamesTheOtherLoginWithoutAPercentage() throws {
        let box = try PaceSandbox(metrics: Self.fiveFull)
        let result = runPace(box, ["gate", "--model", "opus"], extra: Self.inSession())
        #expect(result.status == 10)
        #expect(result.out.hasPrefix("pace: PAUSE — this login is at its limit; another login has room"), "\(result.out)")
        #expect(result.out.contains("run `pacer wait` in the background"), "\(result.out)")
        #expect(!Self.hasPercent(result.out), "\(result.out)")
        #expect(box.stateText.contains("\"switch\": \"possible\""), "\(box.stateText)")
        // The full reason stays in the state file for informed readers.
        #expect(box.stateText.contains("5h at 99% >= safe limit"), "\(box.stateText)")

        let status = runPace(box, ["status", "--model", "opus", "--no-refresh"], extra: Self.inSession())
        #expect(status.status == 10)
        #expect(status.out.hasPrefix("paused: checkpoint and wait — another login has room"), "\(status.out)")
        #expect(!Self.hasPercent(status.out), "\(status.out)")
    }

    @Test func aPauseWithARunningSwitcherSaysTheSwitchIsComing() throws {
        let box = try PaceSandbox(metrics: Self.fiveFull)
        try Self.heartbeat(box)
        let result = runPace(box, ["gate", "--model", "opus"], extra: Self.inSession())
        #expect(result.status == 10, "a switch is coming, but this login is at its limit now")
        #expect(result.out.contains("the account switcher has a login with room to move to"), "\(result.out)")
        #expect(box.stateText.contains("\"switch\": \"expected\""), "\(box.stateText)")
        let status = runPace(box, ["status", "--model", "opus", "--no-refresh"], extra: Self.inSession())
        #expect(status.out.hasPrefix("paused: checkpoint and wait — the account switcher is moving"), "\(status.out)")
    }

    @Test func aHoldingSwitcherIsBelievedOverTheOtherLoginsNumbers() throws {
        let box = try PaceSandbox(metrics: Self.fiveFull)
        try Self.heartbeat(box, holding: true, targets: [])
        let result = runPace(box, ["gate", "--model", "opus"], extra: Self.inSession())
        #expect(result.out.hasPrefix("pace: PAUSE — this login is at its limit until "), "\(result.out)")
        #expect(box.stateText.contains("\"switch\": \"none\""), "\(box.stateText)")
    }

    @Test func aStaleHeartbeatIsAStoppedSwitcher() throws {
        let box = try PaceSandbox(metrics: Self.fiveFull)
        try Self.heartbeat(box, age: 600)
        let result = runPace(box, ["gate", "--model", "opus"], extra: Self.inSession())
        #expect(result.out.contains("another login has room"), "\(result.out)")
    }

    @Test func anInformedPauseAddsTheOtherLoginsAndWhatASwitchWouldDo() throws {
        let box = try PaceSandbox(metrics: Self.fiveFull)
        try Self.heartbeat(box)
        let result = runPace(box, ["gate", "--model", "opus"])
        #expect(result.out.contains("pace: PAUSE — 5h at 99% >= safe limit"), "\(result.out)")
        #expect(result.out.contains("other logins: 1 with room (5h 10%, 7d 10%) — the account switcher has a target with room"),
                "\(result.out)")
    }

    @Test func gateOnlyReportAndAccountsAnswerUnderAHeader() throws {
        let box = try PaceSandbox(metrics: Self.roomy)
        let report = runPace(box, ["report"], extra: Self.inSession())
        #expect(report.out.hasPrefix("pacer: gate-only pacing — these numbers answer the user's question."), "\(report.out)")
        #expect(report.out.contains("5h"), "\(report.out)")
        let accounts = runPace(box, ["accounts"], extra: Self.inSession())
        #expect(accounts.out.hasPrefix("pacer: gate-only pacing"), "\(accounts.out)")
        // json stays machine-readable.
        let json = runPace(box, ["json"], extra: Self.inSession())
        #expect(json.out.hasPrefix("{"), "\(json.out)")
        // A terminal gets no header.
        #expect(runPace(box, ["report"]).out.hasPrefix("5h"))
    }

    @Test func accountsSaysWhichLoginsHaveRoomAndWhichTheSwitcherWouldPick() throws {
        let box = try PaceSandbox(metrics: Self.weekFull + Self.login("acct-near000", active: false, seven: 0.95))
        try Self.heartbeat(box)
        let out = runPace(box, ["accounts"]).out
        #expect(out.contains("    spent until "), "\(out)")
        #expect(out.contains("    room · rotation target\n"), "\(out)")
        #expect(out.contains("    near its limit\n"), "\(out)")
        #expect(out.contains("no one login's % is the machine's capacity"), "\(out)")
    }

    @Test func aReportWithARunningSwitcherSaysRotationIsOn() throws {
        let box = try PaceSandbox(metrics: Self.fiveFull)
        try Self.heartbeat(box)
        let out = runPace(box, ["report"]).out
        #expect(out.contains("rotation: on — at this login's limit the account switcher moves sessions"), "\(out)")
    }

    // MARK: - wait and the switch

    @Test func aWaitHoldsAFarOffPauseForAnExpectedSwitchAndResumesOnIt() throws {
        let box = try PaceSandbox(metrics: Self.weekFull)
        try Self.heartbeat(box)
        let result = runPace(box, ["wait", "--model", "opus"], extra: Self.inSession(), onSleep: { n in
            if n == 2 { try? box.setMetrics(Self.weekSwitched) }
        })
        #expect(result.status == 0, "\(result.out)")
        #expect(result.out.contains("pace: paused — waiting for the account switcher to move to a login with room…"),
                "\(result.out)")
        #expect(result.out.contains("pace: room is back — switched to a login with room. Resume."), "\(result.out)")
        #expect(!Self.hasPercent(result.out), "\(result.out)")
    }

    @Test func withoutASwitcherAFarOffPauseStillChecksPointsAndStops() throws {
        let box = try PaceSandbox(metrics: Self.weekFullAlone)
        let result = runPace(box, ["wait", "--model", "opus"], extra: Self.inSession())
        #expect(result.status == 20, "\(result.out)")
        #expect(result.out.contains("beyond --max-wait. Checkpoint and stop; tell the user when it resets."), "\(result.out)")
        #expect(!Self.hasPercent(result.out), "\(result.out)")
    }

    @Test func aFarOffPauseWithNoSwitcherTellsTheUserRatherThanWaiting() throws {
        let box = try PaceSandbox(metrics: Self.weekFull)
        let result = runPace(box, ["gate", "--model", "opus"], extra: Self.inSession())
        #expect(result.out.contains("another login has room, and a switch to it ends the pause. Checkpoint, stop, and tell the user both."),
                "\(result.out)")
    }

    @Test func aWaitWithNoSwitcherButAnotherLoginWithRoomSaysSo() throws {
        let box = try PaceSandbox(metrics: Self.weekFull)
        let result = runPace(box, ["wait", "--model", "opus"], extra: Self.inSession())
        #expect(result.status == 20, "\(result.out)")
        #expect(result.out.contains("Another login has room: a switch to it would end the pause."), "\(result.out)")
    }

    @Test func theSwitchGraceRunsOut() throws {
        let box = try PaceSandbox(metrics: Self.weekFull)
        try Self.heartbeat(box)
        let result = runPace(box, ["wait", "--model", "opus", "--switch-grace", "0"], extra: Self.inSession())
        #expect(result.status == 20, "\(result.out)")
        #expect(result.out.contains("The account switcher did not switch within"), "\(result.out)")
    }

    @Test func aSwitcherThatStopsMidWaitEndsTheHold() throws {
        let box = try PaceSandbox(metrics: Self.weekFull)
        try Self.heartbeat(box)
        let result = runPace(box, ["wait", "--model", "opus"], extra: Self.inSession(), onSleep: { n in
            if n == 2 {
                try? FileManager.default.removeItem(at: box.dir.appendingPathComponent(".claude/pace/rotation.json"))
            }
        })
        #expect(result.status == 20, "\(result.out)")
    }

    @Test func anInformedWaitStillPrintsTheNumbers() throws {
        let box = try PaceSandbox(metrics: Self.weekFull)
        try Self.heartbeat(box)
        let result = runPace(box, ["wait", "--model", "opus"], onSleep: { n in
            if n == 2 { try? box.setMetrics(Self.weekSwitched) }
        })
        #expect(result.status == 0, "\(result.out)")
        #expect(result.out.contains("7d at 99% >= safe limit"), "\(result.out)")
        #expect(result.out.contains("— headroom on the new login (7d 11%). Resume."), "\(result.out)")
    }
}
