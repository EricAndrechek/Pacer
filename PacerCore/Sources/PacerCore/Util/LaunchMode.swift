import Foundation

/// Which of Pacer's non-normal launch modes, if any, this process is in.
///
/// **Why one place**: each diagnostic mode is a second process of the same
/// bundle that must not behave like the user's app (no stderr redirect, no
/// single-instance gate, no alerts, and now no telemetry). The app delegate
/// used to list the modes by hand at four sites, and a mode missing from one
/// list silently fell through to a normal startup. Every mode's `isActive`
/// reads from here, and anything that must happen only for the real app asks
/// `LaunchMode.isNormalLaunch`.
///
/// Modes overlap on purpose: the live render and the tooltip self-test also
/// set `PACER_SCREENSHOT_MODE`, because they reuse the screenshot path.
public enum LaunchMode: String, CaseIterable, Sendable {
    case screenshot       // PACER_SCREENSHOT_MODE=1 (make screenshots)
    case liveRender       // PACER_RENDER_LIVE=<scopes> (make render-live)
    case tooltipSelfTest  // PACER_TOOLTIP_SELFTEST=1
    case coldStartProbe   // PACER_COLD_START_PROBE=1
    case archiveBackfill  // PACER_ARCHIVE_BACKFILL=1
    case archiveRoundTrip // PACER_ARCHIVE_ROUNDTRIP=1
    case accountAssign    // PACER_ACCOUNT_ASSIGN=<spec>

    public static func active(in environment: [String: String]) -> Set<LaunchMode> {
        func on(_ key: String) -> Bool { environment[key] == "1" }
        func set(_ key: String) -> Bool { !(environment[key] ?? "").isEmpty }
        var modes: Set<LaunchMode> = []
        if on("PACER_SCREENSHOT_MODE") { modes.insert(.screenshot) }
        if set("PACER_RENDER_LIVE") { modes.insert(.liveRender) }
        if on("PACER_TOOLTIP_SELFTEST") { modes.insert(.tooltipSelfTest) }
        if on("PACER_COLD_START_PROBE") { modes.insert(.coldStartProbe) }
        if on("PACER_ARCHIVE_BACKFILL") { modes.insert(.archiveBackfill) }
        if on("PACER_ARCHIVE_ROUNDTRIP") { modes.insert(.archiveRoundTrip) }
        if set("PACER_ACCOUNT_ASSIGN") { modes.insert(.accountAssign) }
        return modes
    }

    /// The modes of this process. Read once: the environment does not change.
    public static let current: Set<LaunchMode> = active(in: ProcessInfo.processInfo.environment)

    public static func isActive(_ mode: LaunchMode) -> Bool { current.contains(mode) }

    /// The user's own app: no diagnostic mode and not a test process.
    public static var isNormalLaunch: Bool {
        current.isEmpty && !PacerPreferences.isTestProcess
    }
}
