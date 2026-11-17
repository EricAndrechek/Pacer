import Foundation
import Testing
@testable import PacerCore

@Suite("Update install policy")
struct UpdateInstallPolicyTests {

    private typealias P = UpdateInstallPolicy

    /// A menu-bar-only Pacer launched long ago, update just prepared, nobody
    /// touching anything of Pacer's: the user who never quits it.
    private func menuBarOnly() -> P.Signals {
        P.Signals(sinceReady: 30, sinceUsed: 3 * 86400, userIdle: 2,
                  pacerActive: false, menuOpen: false, otherWindowOpen: false,
                  dashboardOpen: false, storeOpening: false)
    }

    /// The dashboard kept open on a monitor while someone works in another app.
    private func dashboardOnAMonitor() -> P.Signals {
        var s = menuBarOnly()
        s.dashboardOpen = true
        s.sinceUsed = 45 * 60
        s.userIdle = 3
        return s
    }

    @Test("a menu-bar-only Pacer installs as soon as the update is ready")
    func menuBarOnlyInstalls() {
        #expect(P.decide(menuBarOnly()) == .install(.noWindow))
    }

    @Test("an open dashboard waits while someone is at the Mac")
    func dashboardWaits() {
        #expect(P.decide(dashboardOnAMonitor()) == .wait(.dashboardOpen))
    }

    @Test("an open dashboard installs once nobody has touched the Mac for the threshold")
    func dashboardInstallsWhenAway() {
        var s = dashboardOnAMonitor()
        s.userIdle = P.userAwayAfter - 1
        #expect(P.decide(s) == .wait(.dashboardOpen))
        s.userIdle = P.userAwayAfter
        #expect(P.decide(s) == .install(.userAway))
    }

    @Test("a dashboard open for a whole day with someone always there installs anyway")
    func overdue() {
        var s = dashboardOnAMonitor()
        s.sinceReady = P.maxWait - 1
        #expect(P.decide(s) == .wait(.dashboardOpen))
        s.sinceReady = P.maxWait
        #expect(P.decide(s) == .install(.overdue))
    }

    @Test("an open menu or a migrating store blocks even when held past the ceiling and away")
    func hardBlocks() {
        var base = dashboardOnAMonitor()
        base.sinceReady = 30 * 86400
        base.userIdle = 3600
        #expect(P.decide(base) == .install(.heldTooLong))

        var s = base; s.menuOpen = true
        #expect(P.decide(s) == .wait(.menuOpen))
        s = base; s.storeOpening = true
        #expect(P.decide(s) == .wait(.storeOpening))

        // And for the menu-bar-only case, which otherwise installs at once.
        var m = menuBarOnly(); m.menuOpen = true
        #expect(P.decide(m) == .wait(.menuOpen))
        m = menuBarOnly(); m.storeOpening = true
        #expect(P.decide(m) == .wait(.storeOpening))
    }

    @Test("Pacer in use or a second window blocks while someone is at the Mac, however long the hold")
    func presentUserIsNeverInterrupted() {
        // Someone typing a moment ago, the update held for a month: nothing
        // changes for them, before or after the ceiling.
        for sinceReady: TimeInterval in [30, P.maxWait, P.ceiling - 1, P.ceiling, 30 * 86400] {
            var s = dashboardOnAMonitor()
            s.sinceReady = sinceReady
            s.userIdle = P.userAwayAfter - 1
            s.pacerActive = true
            #expect(P.decide(s) == .wait(.inUse))
            s.pacerActive = false
            s.otherWindowOpen = true
            #expect(P.decide(s) == .wait(.windowOpen))

            var m = menuBarOnly()
            m.sinceReady = sinceReady
            m.userIdle = 0
            m.pacerActive = true
            #expect(P.decide(m) == .wait(.inUse))
        }
    }

    @Test("an active Pacer nobody has touched counts as not in use")
    func activeButAway() {
        // Left frontmost when its user walked away: before this it waited for
        // ever, ahead of the overdue rule.
        var s = dashboardOnAMonitor()
        s.pacerActive = true
        s.userIdle = P.userAwayAfter - 1
        #expect(P.decide(s) == .wait(.inUse))
        s.userIdle = P.userAwayAfter
        #expect(P.decide(s) == .install(.userAway))

        // Active with no window (after the menu-bar dropdown), nobody there.
        var m = menuBarOnly()
        m.pacerActive = true
        m.userIdle = P.userAwayAfter
        #expect(P.decide(m) == .install(.noWindow))

        // Still not inside the quiet period after real use.
        m.sinceUsed = P.quietAfterUse - 1
        #expect(P.decide(m) == .wait(.recentlyUsed))
    }

    @Test("past the ceiling, a forgotten window or the quiet period gives way once nobody is at the Mac")
    func ceiling() {
        var s = menuBarOnly()
        s.otherWindowOpen = true
        s.userIdle = P.userAwayAfter
        s.sinceReady = P.ceiling - 1
        #expect(P.decide(s) == .wait(.windowOpen))
        s.sinceReady = P.ceiling
        #expect(P.decide(s) == .install(.heldTooLong))

        var q = menuBarOnly()
        q.sinceUsed = 60
        q.userIdle = P.userAwayAfter
        q.sinceReady = P.ceiling - 1
        #expect(P.decide(q) == .wait(.recentlyUsed))
        q.sinceReady = P.ceiling
        #expect(P.decide(q) == .install(.heldTooLong))

        // The ceiling is later than every bound below it.
        #expect(P.ceiling > P.maxWait)
    }

    @Test("Pacer used or launched a moment ago waits out the quiet period, dashboard or not")
    func recentlyUsed() {
        var s = menuBarOnly()
        s.sinceUsed = P.quietAfterUse - 1
        #expect(P.decide(s) == .wait(.recentlyUsed))
        s.sinceUsed = P.quietAfterUse
        #expect(P.decide(s) == .install(.noWindow))

        // Overdue and away do not cut the quiet period short.
        var d = dashboardOnAMonitor()
        d.sinceReady = P.maxWait * 2
        d.userIdle = P.userAwayAfter * 2
        d.sinceUsed = 60
        #expect(P.decide(d) == .wait(.recentlyUsed))
    }

    @Test("a clock that went backwards reads as just used, never as a licence to install")
    func negativeDurations() {
        var s = menuBarOnly()
        s.sinceUsed = -3600
        #expect(P.decide(s) == .wait(.recentlyUsed))
        var d = dashboardOnAMonitor()
        d.sinceReady = -10
        d.userIdle = 0
        #expect(P.decide(d) == .wait(.dashboardOpen))
    }

    @Test("the hard blocks are checked in a fixed order, the store first")
    func blockOrder() {
        var s = menuBarOnly()
        s.storeOpening = true; s.menuOpen = true; s.pacerActive = true; s.otherWindowOpen = true
        #expect(P.decide(s) == .wait(.storeOpening))
        s.storeOpening = false
        #expect(P.decide(s) == .wait(.menuOpen))
        s.menuOpen = false
        #expect(P.decide(s) == .wait(.inUse))
        s.userIdle = P.userAwayAfter
        #expect(P.decide(s) == .wait(.windowOpen))
        s.userIdle = 2
        s.pacerActive = false
        #expect(P.decide(s) == .wait(.windowOpen))
    }
}
