import Testing
@testable import PacerCore

// A diagnostic run that is classified as normal would start telemetry (and the
// single-instance gate, and alerts) beside the user's own app. These pin the
// exact variables each script sets.

@Suite("Launch mode")
struct LaunchModeTests {

    @Test("no Pacer variables is a normal launch")
    func normal() {
        #expect(LaunchMode.active(in: ["HOME": "/Users/x", "CI": "true"]).isEmpty)
    }

    @Test("each script's variables select its mode")
    func eachMode() {
        #expect(LaunchMode.active(in: ["PACER_SCREENSHOT_MODE": "1"]) == [.screenshot])
        #expect(LaunchMode.active(in: ["PACER_COLD_START_PROBE": "1"]) == [.coldStartProbe])
        #expect(LaunchMode.active(in: ["PACER_ARCHIVE_BACKFILL": "1"]) == [.archiveBackfill])
        #expect(LaunchMode.active(in: ["PACER_ARCHIVE_ROUNDTRIP": "1"]) == [.archiveRoundTrip])
        #expect(LaunchMode.active(in: ["PACER_ACCOUNT_ASSIGN": "acct=slot"]) == [.accountAssign])
    }

    @Test("render-live and the tooltip self-test also set screenshot mode, and both show")
    func overlapping() {
        // bin/dev-render-live.sh and bin/verify-menubar-tooltip.sh
        #expect(LaunchMode.active(in: ["PACER_RENDER_LIVE": "all", "PACER_SCREENSHOT_MODE": "1"])
                == [.liveRender, .screenshot])
        #expect(LaunchMode.active(in: ["PACER_TOOLTIP_SELFTEST": "1", "PACER_SCREENSHOT_MODE": "1"])
                == [.tooltipSelfTest, .screenshot])
    }

    @Test("a flag set to anything but 1, or an empty value, is off")
    func offValues() {
        #expect(LaunchMode.active(in: ["PACER_SCREENSHOT_MODE": "0", "PACER_RENDER_LIVE": "",
                                       "PACER_ACCOUNT_ASSIGN": ""]).isEmpty)
    }

    @Test("a test process is never a normal launch")
    func testProcess() {
        #expect(LaunchMode.isNormalLaunch == false)
    }
}
