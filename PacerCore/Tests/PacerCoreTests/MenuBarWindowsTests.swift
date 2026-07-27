import Foundation
import Testing
@testable import PacerCore

/// Unit coverage for the pure logic behind the menu bar's two dynamic
/// behaviours: which window's utilization drives the status-item icon
/// (`MenuBarWindows.resolveDriver`) and the order the dropdown lists windows in
/// (`MenuBarWindows.ordered`). Pinning the driver fallback here is what
/// guarantees the icon keeps working — and keeps looking like it always has —
/// when a chosen per-model window disappears.
struct MenuBarWindowsTests {

    // MARK: - Fixtures

    private func fixed(_ key: String, _ name: String, pct: Double?, duration: TimeInterval) -> MenuBarWindowItem {
        MenuBarWindowItem(key: key, displayName: name, usedPercentage: pct, resetsAt: nil,
                          duration: duration, group: "", isScoped: false, isActive: false)
    }

    private func scoped(_ key: String, _ name: String, group: String, pct: Double,
                        duration: TimeInterval, active: Bool = false) -> MenuBarWindowItem {
        MenuBarWindowItem(key: key, displayName: name, usedPercentage: pct, resetsAt: nil,
                          duration: duration, group: group, isScoped: true, isActive: active)
    }

    private var fiveHour: MenuBarWindowItem {
        fixed(RateLimitWindowName.fiveHour, "5-hour", pct: 39, duration: MenuBarWindows.fiveHourDuration)
    }
    private var sevenDay: MenuBarWindowItem {
        fixed(RateLimitWindowName.sevenDay, "7-day", pct: 71, duration: MenuBarWindows.sevenDayDuration)
    }
    private var fable: MenuBarWindowItem {
        scoped("weekly_scoped|Fable|", "Fable", group: "weekly", pct: 49, duration: MenuBarWindows.sevenDayDuration)
    }
    private var coworkSession: MenuBarWindowItem {
        scoped("session_scoped|cowork|", "cowork", group: "session", pct: 22, duration: MenuBarWindows.fiveHourDuration, active: true)
    }

    // MARK: - Driver resolution

    @Test func autoResolvesToFiveHour() {
        // Empty key = "auto" = today's behaviour: the 5-hour window paints the icon.
        let resolved = MenuBarWindows.resolveDriver(
            key: MenuBarWindows.autoDriverKey, windows: [coworkSession, fiveHour, sevenDay, fable])
        #expect(resolved?.key == RateLimitWindowName.fiveHour)
    }

    @Test func explicitPresentWindowWins() {
        let resolved = MenuBarWindows.resolveDriver(
            key: fable.key, windows: [fiveHour, sevenDay, fable])
        #expect(resolved?.key == fable.key)
        #expect(resolved?.usedPercentage == 49)
    }

    @Test func explicitFixedWindowWins() {
        let resolved = MenuBarWindows.resolveDriver(
            key: RateLimitWindowName.sevenDay, windows: [fiveHour, sevenDay, fable])
        #expect(resolved?.key == RateLimitWindowName.sevenDay)
    }

    @Test func missingChosenWindowFallsBackToFiveHour() {
        // The user picked a scoped window that's since vanished from the poll —
        // the icon must fall back to the default anchor, not go blank.
        let resolved = MenuBarWindows.resolveDriver(
            key: "weekly_scoped|Fable|", windows: [fiveHour, sevenDay])
        #expect(resolved?.key == RateLimitWindowName.fiveHour)
    }

    @Test func autoFallsBackToSevenDayWhenNoFiveHour() {
        let resolved = MenuBarWindows.resolveDriver(
            key: MenuBarWindows.autoDriverKey, windows: [sevenDay, fable])
        #expect(resolved?.key == RateLimitWindowName.sevenDay)
    }

    @Test func missingChosenFallsBackToFirstWhenNoFixed() {
        // No fixed windows at all (degenerate) — fall back to the first window
        // rather than returning nil.
        let resolved = MenuBarWindows.resolveDriver(key: "gone", windows: [coworkSession, fable])
        #expect(resolved?.key == coworkSession.key)
    }

    @Test func noWindowsResolvesNil() {
        #expect(MenuBarWindows.resolveDriver(key: MenuBarWindows.autoDriverKey, windows: []) == nil)
        #expect(MenuBarWindows.resolveDriver(key: "anything", windows: []) == nil)
    }

    // MARK: - Resolvability (settings picker "unavailable" flag)

    @Test func resolvabilityFlagsVanishedPick() {
        let windows = [fiveHour, sevenDay]
        #expect(MenuBarWindows.driverIsResolvable(key: MenuBarWindows.autoDriverKey, windows: windows))
        #expect(MenuBarWindows.driverIsResolvable(key: RateLimitWindowName.fiveHour, windows: windows))
        #expect(!MenuBarWindows.driverIsResolvable(key: "weekly_scoped|Fable|", windows: windows))
    }

    // MARK: - Ordering (glued heroes)

    @Test func fixedPairKeepsFiveThenSevenOrder() {
        let ordered = MenuBarWindows.ordered([sevenDay, fiveHour])
        #expect(ordered.map(\.key) == [RateLimitWindowName.fiveHour, RateLimitWindowName.sevenDay])
    }

    @Test func scopedWindowsNeverSplitTheHeroes() {
        // Session-scoped sorts ahead of 5h; weekly-scoped after 7d — the two
        // fixed heroes stay back-to-back in the middle.
        let ordered = MenuBarWindows.ordered([fable, fiveHour, coworkSession, sevenDay])
        #expect(ordered.map(\.key) == [
            coworkSession.key,
            RateLimitWindowName.fiveHour,
            RateLimitWindowName.sevenDay,
            fable.key,
        ])
    }
}
