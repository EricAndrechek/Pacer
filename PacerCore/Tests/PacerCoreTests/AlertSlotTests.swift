import Foundation
import Testing
@testable import PacerCore

// One banner per window per account, cleared at that window's reset, and a
// mute that ends on its own at the reset it was set against.

@Suite("Alert slots and mutes")
struct AlertSlotTests {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var reset: Date { now.addingTimeInterval(3600) }

    @Test func everyAlertForOneAccountsWindowSharesASlot() {
        let a = AlertSlot.identifier(windowKey: "five_hour#acct-a")
        #expect(a == AlertSlot.identifier(windowKey: "five_hour#acct-a"))
        #expect(a != AlertSlot.identifier(windowKey: "five_hour#acct-b"))
        #expect(a != AlertSlot.identifier(windowKey: "seven_day#acct-a"))
        #expect(a.hasPrefix(AlertSlot.prefix))
    }

    @Test func aBannerIsStaleOnlyOnceItsWindowHasReset() {
        #expect(!AlertSlot.isStale(resetsAt: reset, now: now))
        // resets_at jitters, so the exact instant is not yet a reset.
        #expect(!AlertSlot.isStale(resetsAt: reset, now: reset))
        #expect(AlertSlot.isStale(resetsAt: reset, now: reset.addingTimeInterval(AlertSlot.resetGrace)))
        // No reset instant never expires by time.
        #expect(!AlertSlot.isStale(resetsAt: nil, now: now.addingTimeInterval(1e7)))
    }

    @Test func userInfoRoundTripsTheReset() {
        let info = AlertSlot.userInfo(windowKey: "five_hour#a", window: "five_hour", resetsAt: reset)
        #expect(info[AlertSlot.windowKeyInfo] as? String == "five_hour#a")
        #expect(AlertSlot.resetsAt(from: info) == reset)
        let none = AlertSlot.userInfo(windowKey: "k", window: "five_hour", resetsAt: nil)
        #expect(AlertSlot.resetsAt(from: none) == nil)
    }

    @Test func aMuteLastsUntilItsWindowResets() {
        var mutes = AlertMutes()
        mutes.mute("five_hour#a", resetsAt: reset, fallback: 5 * 3600, now: now)
        #expect(mutes.isMuted("five_hour#a", now: now))
        #expect(mutes.isMuted("five_hour#a", now: reset))
        #expect(!mutes.isMuted("five_hour#a", now: reset.addingTimeInterval(AlertSlot.resetGrace)))
        // Only that account's window.
        #expect(!mutes.isMuted("five_hour#b", now: now))
        #expect(!mutes.isMuted("seven_day#a", now: now))
    }

    @Test func aMuteWithoutAResetEndsAfterOneWindow() {
        var mutes = AlertMutes()
        mutes.mute("five_hour#a", resetsAt: nil, fallback: 5 * 3600, now: now)
        #expect(mutes.isMuted("five_hour#a", now: now.addingTimeInterval(5 * 3600 - 1)))
        #expect(!mutes.isMuted("five_hour#a", now: now.addingTimeInterval(5 * 3600)))
    }

    @Test func unmuteAndPrune() {
        var mutes = AlertMutes()
        mutes.mute("a", resetsAt: reset, fallback: 0, now: now)
        mutes.mute("b", resetsAt: now.addingTimeInterval(-3600), fallback: 0, now: now)
        mutes.prune(now: now)
        #expect(mutes.until.keys.sorted() == ["a"])
        mutes.unmute("a")
        #expect(!mutes.isMuted("a", now: now))
    }

    @Test func mutesSurviveThePlistRoundTrip() {
        var mutes = AlertMutes()
        mutes.mute("five_hour#a", resetsAt: reset, fallback: 0, now: now)
        #expect(AlertMutes(plist: mutes.plist) == mutes)
        #expect(AlertMutes(plist: nil) == AlertMutes())
        #expect(AlertMutes(plist: "garbage") == AlertMutes())
    }
}
