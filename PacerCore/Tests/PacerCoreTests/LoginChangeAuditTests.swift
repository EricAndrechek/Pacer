import Foundation
import Testing
@testable import PacerCore

/// #382: explained and unexplained default-login changes are counted once
/// each, so a switcher log that stops parsing shows. Fictional accounts.
@Suite("Login change audit")
struct LoginChangeAuditTests {

    final class Counts: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [String: Int] = [:]
        func add(_ key: String, _ n: Int) { lock.withLock { map[key, default: 0] += n } }
        subscript(_ key: String) -> Int { lock.withLock { map[key] ?? 0 } }
    }

    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func change(_ minutesAgo: Double, to: String = "b") -> (change: AccountTrail.LoginChange, followed: Bool) {
        let at = now.addingTimeInterval(-minutesAgo * 60)
        return (AccountTrail.LoginChange(at: at, from: "a", fromSince: at.addingTimeInterval(-3600), to: to), false)
    }

    static func day() -> [(change: AccountTrail.LoginChange, followed: Bool)] {
        // Four switches a switcher made, one real /login.
        var list = [(change: AccountTrail.LoginChange, followed: Bool)]()
        for (i, followed) in [true, true, false, true, true].enumerated() {
            let c = change(Double(60 + i * 90))
            list.append((c.change, followed))
        }
        return list
    }

    @Test func countsExplainedAndUnexplainedOverADay() {
        let counts = Counts()
        let audit = LoginChangeAudit(url: nil, add: counts.add)
        let today = audit.observe(Self.day(), switcherPresent: true, now: Self.now)
        #expect(counts["accounts.login_change.explained"] == 4)
        #expect(counts["accounts.login_change.unexplained"] == 1)
        #expect(today == 1)
        // Seen again, nothing is counted twice.
        _ = audit.observe(Self.day(), switcherPresent: true, now: Self.now.addingTimeInterval(60))
        #expect(counts["accounts.login_change.explained"] == 4)
        #expect(counts["accounts.login_change.unexplained"] == 1)
    }

    @Test func aBrokenParseCountsEveryChangeUnexplained() {
        let counts = Counts()
        let audit = LoginChangeAudit(url: nil, add: counts.add)
        let all = Self.day().map { ($0.change, false) }
        #expect(audit.observe(all, switcherPresent: true, now: Self.now) == 5)
        #expect(counts["accounts.login_change.unexplained"] == 5)
        #expect(counts["accounts.login_change.explained"] == 0)
    }

    @Test func noSwitcherJudgesNothing() {
        let counts = Counts()
        let audit = LoginChangeAudit(url: nil, add: counts.add)
        #expect(audit.observe(Self.day(), switcherPresent: false, now: Self.now) == 0)
        #expect(counts["accounts.login_change.unexplained"] == 0)
    }

    @Test func aChangeIsJudgedOnlyAfterTheGraceAndWithinTheDay() {
        let counts = Counts()
        let audit = LoginChangeAudit(url: nil, add: counts.add)
        let fresh = Self.change(0.5)      // 30 s old: the log may not have the line yet
        let old = Self.change(25 * 60)    // 25 h old
        _ = audit.observe([fresh, old], switcherPresent: true, now: Self.now)
        #expect(counts["accounts.login_change.unexplained"] == 0)
        // Once past the grace, the fresh one is judged.
        _ = audit.observe([fresh, old], switcherPresent: true, now: Self.now.addingTimeInterval(120))
        #expect(counts["accounts.login_change.unexplained"] == 1)
    }

    @Test func aRelaunchDoesNotCountAgain() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("audit-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = Counts()
        _ = LoginChangeAudit(url: url, add: first.add).observe(Self.day(), switcherPresent: true, now: Self.now)
        #expect(first["accounts.login_change.unexplained"] == 1)
        let entries = LoginChangeAudit.read(from: url)
        #expect(entries.count == 5)
        #expect(LoginChangeAudit.unexplained(in: entries, now: Self.now) == 1)
        let second = Counts()
        _ = LoginChangeAudit(url: url, add: second.add).observe(Self.day(), switcherPresent: true, now: Self.now)
        #expect(second["accounts.login_change.unexplained"] == 0)
        #expect(second["accounts.login_change.explained"] == 0)
    }

    @Test func reportNoteStartsAtTwo() {
        #expect(LoginChangeAudit.reportNote(unexplained: 0) == nil)
        #expect(LoginChangeAudit.reportNote(unexplained: 1) == nil)
        #expect(LoginChangeAudit.reportNote(unexplained: 3)
                == "note: 3 login changes today had no switch behind them — check the switcher's log")
    }

    @Test func aRosterThatCannotBeReadIsAPresentSwitcherWithNoSwitches() {
        let bad = LoginSwitchEvidence.parse(sequence: Data("not json".utf8), logTail: nil)
        #expect(bad.switcherPresent && bad.switches.isEmpty)
        #expect(!LoginSwitchEvidence.parse(sequence: nil, logTail: nil).switcherPresent)
    }
}
