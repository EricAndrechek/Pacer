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

    @Test("Pacer in use, an open menu, a second window or a migrating store block even when overdue and away")
    func hardBlocks() {
        var base = dashboardOnAMonitor()
        base.sinceReady = 30 * 86400
        base.userIdle = 3600
        #expect(P.decide(base) == .install(.userAway))

        var s = base; s.pacerActive = true
        #expect(P.decide(s) == .wait(.inUse))
        s = base; s.menuOpen = true
        #expect(P.decide(s) == .wait(.menuOpen))
        s = base; s.otherWindowOpen = true
        #expect(P.decide(s) == .wait(.windowOpen))
        s = base; s.storeOpening = true
        #expect(P.decide(s) == .wait(.storeOpening))

        // And for the menu-bar-only case, which otherwise installs at once.
        var m = menuBarOnly(); m.menuOpen = true
        #expect(P.decide(m) == .wait(.menuOpen))
        m = menuBarOnly(); m.storeOpening = true
        #expect(P.decide(m) == .wait(.storeOpening))
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
        s.pacerActive = false
        #expect(P.decide(s) == .wait(.windowOpen))
    }
}
