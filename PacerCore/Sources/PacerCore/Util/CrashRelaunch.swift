import Foundation
import PacerRelaunch

/// Pacer's side of relaunching itself after it exits without quitting
/// (#412): what each launch arms, from the relaunches before it, and the
/// counts the daily check-in reports. The app's `CrashRelauncher` does the
/// process work; `PacerRelaunch` holds the policy and the relauncher.
///
/// State lives in the app's own defaults (`.standard`): neither the widget
/// nor the CLI has any business with it.
public enum CrashRelaunch {

    /// Set on the launch the relauncher makes (`open --env`). The app reads it
    /// once and removes it from its environment.
    public static let environmentKey = "PACER_CRASH_RELAUNCH"

    /// `defaults write com.ericandrechek.pacer crashRelaunch.disabled -bool YES`
    /// turns it off from the next launch; `delete` turns it back on.
    public static let disabledKey = "crashRelaunch.disabled"

    /// Where the relauncher sits in the app bundle.
    public static let helperPath = "Contents/Helpers/PacerRelauncher"

    static let historyKey = "crashRelaunch.history"
    static let pendingRelaunchedKey = "crashRelaunch.unreported.relaunched"
    static let pendingGaveUpKey = "crashRelaunch.unreported.gaveUp"

    /// `TelemetryCounters` keys (health counters, so Sentry metrics as well as
    /// PostHog `counter.*`; docs/telemetry-plan.md, "Crash relaunch").
    public static let relaunchedCounter = "crash_relaunch.relaunched"
    public static let gaveUpCounter = "crash_relaunch.gave_up"
    public static let unavailableCounter = "crash_relaunch.unavailable"

    public struct LaunchPlan: Equatable, Sendable {
        /// What the relauncher is told at start.
        public let instruction: RelaunchInstruction
        /// This launch is the relauncher's.
        public let relaunched: Bool
        /// Relaunches in a row inside the window, this one included.
        public let recentRelaunches: Int
    }

    /// Once per launch: store the history this launch extends (or clears),
    /// note the relaunch or the give-up for telemetry, and say what to arm.
    ///
    /// The counts are kept in defaults until the daily check-in sends them
    /// (`moveCountsToTelemetry`), not added to `TelemetryCounters` here: those
    /// live in memory, and a crash loop is exactly the case where a process
    /// does not live to its check-in.
    public static func planLaunch(relaunchedAfterCrash: Bool, now: Date = Date(),
                                  defaults: UserDefaults = .standard) -> LaunchPlan {
        let time = now.timeIntervalSince1970
        let previous = defaults.array(forKey: historyKey) as? [Double] ?? []
        let history = RelaunchPolicy.history(previous: previous, relaunchedAfterCrash: relaunchedAfterCrash, now: time)
        defaults.set(history, forKey: historyKey)
        let instruction = RelaunchPolicy.instruction(history: history, now: time)
        if relaunchedAfterCrash { bump(pendingRelaunchedKey, in: defaults) }
        if case .stayDown = instruction { bump(pendingGaveUpKey, in: defaults) }
        return LaunchPlan(instruction: instruction, relaunched: relaunchedAfterCrash,
                          recentRelaunches: RelaunchPolicy.recent(history, now: time).count)
    }

    /// What a run that has been up for a while should arm now, from the stored
    /// history: a run that stopped relaunching at launch is protected again
    /// once its relaunches have aged out of the window.
    public static func currentInstruction(now: Date = Date(), defaults: UserDefaults = .standard) -> RelaunchInstruction {
        let history = defaults.array(forKey: historyKey) as? [Double] ?? []
        return RelaunchPolicy.instruction(history: history, now: now.timeIntervalSince1970)
    }

    /// The counts not yet reported, into `add`, then cleared. The daily
    /// check-in calls it just before it drains `TelemetryCounters`.
    public static func moveCountsToTelemetry(defaults: UserDefaults = .standard,
                                             add: (String, Int) -> Void = { TelemetryCounters.add($0, $1) }) {
        for (key, counter) in [(pendingRelaunchedKey, relaunchedCounter), (pendingGaveUpKey, gaveUpCounter)] {
            let count = defaults.integer(forKey: key)
            guard count > 0 else { continue }
            add(counter, count)
            defaults.removeObject(forKey: key)
        }
    }

    /// How the relauncher starts Pacer again: a new instance (`-n`), so a
    /// Pacer that came back meanwhile is never sent a reopen event, which
    /// would bring its dashboard up; in the background (`-g`), as
    /// `make install` relaunches it; marked as the relauncher's.
    public static func relaunchCommand(bundlePath: String) -> [String] {
        ["/usr/bin/open", "-n", "-g", "-a", bundlePath, "--env", "\(environmentKey)=1"]
    }

    public enum Skip: String, Equatable, Sendable {
        case turnedOff = "turned off (crashRelaunch.disabled)"
        /// Xcode's Stop is a SIGKILL: relaunching after it would fight the developer.
        case debugger = "a debugger is attached"
        /// Ctrl-C in the terminal is a SIGINT, the same fight.
        case terminal = "started from a terminal"
    }

    /// Why this run should not arm at all, if it should not.
    public static func skip(disabled: Bool, debuggerAttached: Bool, startedFromTerminal: Bool) -> Skip? {
        if disabled { return .turnedOff }
        if debuggerAttached { return .debugger }
        if startedFromTerminal { return .terminal }
        return nil
    }

    private static func bump(_ key: String, in defaults: UserDefaults) {
        defaults.set(defaults.integer(forKey: key) + 1, forKey: key)
    }
}

/// Whether a debugger is attached to this process (`P_TRACED`).
public enum DebuggerProbe {
    public static var isAttached: Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }
}
