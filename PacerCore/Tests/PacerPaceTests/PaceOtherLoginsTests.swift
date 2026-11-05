import Foundation
import PacerCore
import Testing
@testable import PacerPace

/// #293: `report` and `json` name the logins other than the one they show,
/// judged by the gate's safe limit, so one login's windows are not read as
/// the machine's capacity. #382: the note about login changes no switch
/// explains. Fictional accounts.
@Suite("pace: other logins and unexplained login changes")
struct PaceOtherLoginsTests {

    static let active = """
        pacer_account_info{account="acct-main",name="m",active="true"} 1
        pacer_rate_limit_used_ratio{account="acct-main",window="five_hour"} 0.5
        pacer_rate_limit_reset_seconds{account="acct-main",window="five_hour"} 6000
        pacer_rate_limit_used_ratio{account="acct-main",window="seven_day"} 0.54
        pacer_rate_limit_reset_seconds{account="acct-main",window="seven_day"} 300000

        """

    /// A Max login: 5-hour and weekly windows.
    static func max(_ name: String, five: Double, seven: Double, fiveReset: Int = 6000, sevenReset: Int = 400_000) -> String {
        """
        pacer_account_info{account="\(name)",name="x",active="false"} 1
        pacer_rate_limit_used_ratio{account="\(name)",window="five_hour"} \(five)
        pacer_rate_limit_reset_seconds{account="\(name)",window="five_hour"} \(fiveReset)
        pacer_rate_limit_used_ratio{account="\(name)",window="seven_day"} \(seven)
        pacer_rate_limit_reset_seconds{account="\(name)",window="seven_day"} \(sevenReset)

        """
    }

    /// An Ultra login: a weekly window and a per-model cap, no 5-hour window.
    static func ultra(_ name: String, seven: Double, model: Double = 0.1, sevenReset: Int = 400_000) -> String {
        """
        pacer_account_info{account="\(name)",name="u",active="false"} 1
        pacer_rate_limit_used_ratio{account="\(name)",window="seven_day"} \(seven)
        pacer_rate_limit_reset_seconds{account="\(name)",window="seven_day"} \(sevenReset)
        pacer_rate_limit_used_ratio{account="\(name)",window="weekly_scoped|Fable|"} \(model)
        pacer_rate_limit_reset_seconds{account="\(name)",window="weekly_scoped|Fable|"} 1000

        """
    }

    func report(_ metrics: String, _ args: [String] = ["report"]) throws -> String {
        let box = try PaceSandbox(metrics: metrics)
        let result = runPace(box, args)
        #expect(result.status == 0, "\(result.out)")
        return result.out
    }

    @Test func aSingleLoginAddsNoLine() throws {
        let out = try report(Self.active)
        #expect(!out.contains("other logins"), "\(out)")
        #expect(out.hasPrefix("5h"), "\(out)")
    }

    @Test func allOthersWithRoomNameTheBestOnesWindows() throws {
        let out = try report(Self.active + Self.max("acct-a", five: 0.18, seven: 0.40)
                             + Self.max("acct-b", five: 0.60, seven: 0.70))
        #expect(out.contains("other logins: 2 with room (5h 18%, 7d 40%)\n"), "\(out)")
        #expect(!out.contains("spent"), "\(out)")
    }

    @Test func mixedRoomAndSpent() throws {
        // Spent: 99% on a window with a one-point safe limit margin or less.
        let out = try report(Self.active + Self.ultra("acct-u", seven: 0.04)
                             + Self.max("acct-x", five: 0.1, seven: 0.99, sevenReset: 200_000)
                             + Self.max("acct-y", five: 0.99, seven: 0.2, fiveReset: 7000))
        #expect(out.contains("other logins: 1 with room (7d 4%), 2 spent until "), "\(out)")
    }

    @Test func allSpent() throws {
        let out = try report(Self.active + Self.max("acct-x", five: 0.1, seven: 0.99)
                             + Self.max("acct-y", five: 0.1, seven: 0.995))
        #expect(out.contains("other logins: 2 spent until "), "\(out)")
        #expect(!out.contains("with room"), "\(out)")
    }

    @Test func aLoginIsSpentUntilItsLastSpentWindowResets() throws {
        let pr = PaceOtherLogins(rows: [
            row("acct-x", "five_hour", 99, resets: "3600"), row("acct-x", "seven_day", 99, resets: "90000"),
            row("acct-y", "seven_day", 99, resets: "50000"),
        ])
        #expect(pr?.logins.first { $0.account == "acct-x" }?.freeIn == 90_000)
        #expect(pr?.spentUntil == 50_000)
    }

    @Test func aWeeklyOnlyUltraLoginIsJudgedOnItsWeekAndNotItsModelCap() throws {
        // The Fable cap is at 100% but it is not the login's capacity.
        let out = try report(Self.active + Self.ultra("acct-u", seven: 0.04, model: 1.0))
        #expect(out.contains("other logins: 1 with room (7d 4%)"), "\(out)")
        let spent = try report(Self.active + Self.ultra("acct-u", seven: 0.99))
        #expect(spent.contains("other logins: 1 spent until "), "\(spent)")
    }

    @Test func aMaxLoginNeedsBothWindowsUnderTheirLimits() throws {
        let out = try report(Self.active + Self.max("acct-m", five: 0.99, seven: 0.1))
        #expect(out.contains("1 spent"), "\(out)")
        let fine = try report(Self.active + Self.max("acct-m", five: 0.2, seven: 0.1))
        #expect(fine.contains("1 with room (5h 20%, 7d 10%)"), "\(fine)")
    }

    @Test func accountAllListsEverythingAndAddsNoLine() throws {
        let out = try report(Self.active + Self.max("acct-a", five: 0.18, seven: 0.40), ["report", "--account", "all"])
        #expect(!out.contains("other logins"), "\(out)")
    }

    @Test func aWindowDueToResetIsNotSpent() throws {
        let pr = PaceOtherLogins(rows: [row("acct-x", "five_hour", 99, resets: "0")])
        #expect(pr?.spent.isEmpty == true)
    }

    @Test func jsonCarriesTheSameThing() throws {
        let box = try PaceSandbox(metrics: Self.active + Self.max("acct-a", five: 0.18, seven: 0.40)
                                  + Self.max("acct-x", five: 0.1, seven: 0.99))
        let out = runPace(box, ["json"]).out
        let object = try #require(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        let others = try #require(object["otherAccounts"] as? [String: Any])
        #expect(others["withRoom"] as? Int == 1)
        #expect(others["spent"] as? Int == 1)
        #expect((others["logins"] as? [[String: Any]])?.count == 2)
        // One login: the field is absent, so the output is what it was.
        let single = runPace(try PaceSandbox(metrics: Self.active), ["json"]).out
        #expect(!single.contains("otherAccounts"), "\(single)")
    }

    @Test func aScopedReadStillFindsTheOtherLogins() throws {
        // A session bound to its own login asks for that login only; the
        // others come from a second, unscoped read.
        let box = try PaceSandbox(metrics: Self.active + Self.max("acct-a", five: 0.18, seven: 0.40))
        let out = runPace(box, ["report", "--account", "acct-main"]).out
        #expect(out.contains("other logins: 1 with room (5h 18%, 7d 40%)"), "\(out)")
    }

    func row(_ account: String, _ identity: String, _ percent: Double, resets: String) -> PaceRow {
        PaceRow(account: account, identity: identity, label: PaceRules.label(forIdentity: identity),
                model: PaceRules.model(forIdentity: identity), percent: percent, resetsIn: resets,
                hitEta: nil, burn: nil, willHit: "0", recentBurn: nil, sampleAge: nil)
    }

    // MARK: - #382 report note

    @Test func theNoteAppearsFromTwoUnexplainedChangesInADay() throws {
        let now = Date()
        func entries(_ n: Int, explained: Bool = false, ago: TimeInterval = 3600) -> [LoginChangeAudit.Entry] {
            (0..<n).map { LoginChangeAudit.Entry(at: now.addingTimeInterval(-ago - Double($0)), explained: explained) }
        }
        let box = try PaceSandbox(metrics: Self.active)
        func run(_ list: [LoginChangeAudit.Entry]) -> String {
            let capture = PaceCapture()
            let io = PaceIO(out: capture.append, err: capture.append, now: { now }, sleep: { _ in },
                            get: { PaceHTTP.get($0) }, gitBranch: { _ in nil },
                            loginChanges: { list })
            _ = Pace.run(["report"], environment: ["HOME": box.dir.path, "PATH": "/usr/bin:/bin",
                                                    "PACER_API": "file://\(box.dir.path)",
                                                    "PACE_STATE": box.stateURL.path], io: io)
            return capture.text
        }
        #expect(!run(entries(1)).contains("note:"))
        #expect(!run(entries(5, explained: true)).contains("note:"))
        #expect(!run(entries(3, ago: 25 * 3600)).contains("note:"))
        #expect(run(entries(2)).contains("note: 2 login changes today had no switch behind them — check the switcher's log\n"))
        #expect(run(entries(3)).contains("note: 3 login changes"))
    }
}
