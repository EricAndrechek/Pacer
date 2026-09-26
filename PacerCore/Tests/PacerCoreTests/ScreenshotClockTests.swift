import Foundation
import Testing
@testable import PacerCore

/// The README screenshots are drawn at one pinned instant and time zone, so a
/// run at any hour draws the same pictures (#154).
@Suite("Screenshot clock")
struct ScreenshotClockTests {

    private var zone: TimeZone { TimeZone(identifier: ScreenshotClock.timeZoneID)! }

    /// What the doc comment promises, and what the scenes are laid out for.
    @Test func thePinnedInstantIsAFridayAfternoonInItsZone() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: ScreenshotClock.fixedNow)
        #expect(parts.weekday == 6)
        #expect(parts.hour == 14)
        #expect(parts.minute == 30)
    }

    @Test func aRunOnThePinnedClockPasses() {
        // The check allows the hour a run could take, frozen clock or not.
        let tenMinutesIn = ScreenshotClock.fixedNow.addingTimeInterval(600)
        #expect(ScreenshotClock.problem(now: tenMinutesIn, timeZone: zone) == nil)
    }

    /// Off the pinned clock the images vary with the hour, so the run must
    /// stop rather than commit them.
    @Test func aRunOffThePinnedClockOrZoneSaysWhy() throws {
        let realNow = ScreenshotClock.fixedNow.addingTimeInterval(8 * 86_400)
        let unpinned = try #require(ScreenshotClock.problem(now: realNow, timeZone: zone))
        #expect(unpinned.contains("not pinned"))

        let utc = try #require(TimeZone(identifier: "UTC"))
        let wrongZone = try #require(
            ScreenshotClock.problem(now: ScreenshotClock.fixedNow, timeZone: utc))
        #expect(wrongZone.contains("time zone"))
    }

    /// Unpinned, the shared clock is the wall clock. It is only ever pinned
    /// in the README screenshot build's widget extension.
    @Test func theSharedClockIsTheWallClockUnlessPinned() {
        #expect(PacerClock.pinned == nil)
        #expect(abs(PacerClock.now.timeIntervalSinceNow) < 5)
    }
}
