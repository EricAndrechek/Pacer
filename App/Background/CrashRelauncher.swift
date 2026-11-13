import Darwin
import Foundation
import PacerCore
import PacerRelaunch

/// Brings Pacer back when it exits without quitting: a crash, a watchdog or
/// memory kill (#412). On 2026-11-12 a crash left it down for 15 hours, usage
/// unrecorded and every `pacer` gate reading stale data, and SentryCrash only
/// reports a crash at the next launch, so nobody was told.
///
/// **How.** Each normal launch starts `PacerRelauncher` (Contents/Helpers) as
/// a child in its own session, its stdin a pipe whose only write end Pacer
/// holds. The kernel closes that end when Pacer's process ends, whatever ends
/// it, and the relauncher reads end-of-file. Pacer says `quit` on the pipe
/// whenever it ends on purpose (`standDown`); an end-of-file without it is a
/// crash or a kill, and the relauncher relaunches Pacer after a back-off, or
/// leaves it closed after three relaunches in 30 minutes (`RelaunchPolicy`).
/// The relaunched Pacer starts its own relauncher.
///
/// **Why not launchd** (`SMAppService.agent` with `KeepAlive`): launchd only
/// keeps alive what it started, and Pacer is started by Finder, the login
/// item, Sparkle and `open`; covering those means routing every launch
/// through the agent. Registering one also shows "Background Items Added"
/// and puts a switch in System Settings, and `KeepAlive.SuccessfulExit`
/// implies `RunAtLoad`, which starts Pacer at login whatever "Open at Login"
/// says. A child process needs no registration, shows nothing, covers every
/// way Pacer is launched, and goes away with the run it protects.
@MainActor
enum CrashRelauncher {

    /// The pipe's write end, or -1 when this run is not protected.
    private static var input: Int32 = -1
    private static var stoodDown = false

    /// This launch is the relauncher's. Read once, early (the single-instance
    /// gate asks), and taken out of the environment so nothing Pacer starts
    /// inherits it.
    static let isRelaunch: Bool = {
        let set = getenv(CrashRelaunch.environmentKey) != nil
        unsetenv(CrashRelaunch.environmentKey)
        return set
    }()

    /// From `PacerAppDelegate.init`, after the single-instance gate (a second
    /// instance must not arm anything) and after stderr points at the log file
    /// (the relauncher inherits it and writes its lines there), and before the
    /// store opens: a crash opening or migrating it is a crash like any other.
    static func armAtLaunch() {
        let relaunched = isRelaunch
        guard LaunchMode.isNormalLaunch else { return }
        let defaults = UserDefaults.standard
        if let skip = CrashRelaunch.skip(disabled: defaults.bool(forKey: CrashRelaunch.disabledKey),
                                         debuggerAttached: DebuggerProbe.isAttached,
                                         startedFromTerminal: isatty(STDIN_FILENO) == 1) {
            Log.write("CrashRelaunch", "off for this run: \(skip.rawValue)")
            return
        }
        let plan = CrashRelaunch.planLaunch(relaunchedAfterCrash: relaunched, defaults: defaults)
        let minutes = Int(RelaunchPolicy.window / 60)
        if plan.relaunched {
            Log.write("CrashRelaunch", "relaunched after Pacer exited without quitting "
                      + "(\(plan.recentRelaunches) of \(RelaunchPolicy.maxRelaunches) in \(minutes) min)")
        }
        let helper = Bundle.main.bundleURL.appendingPathComponent(CrashRelaunch.helperPath).path
        guard FileManager.default.isExecutableFile(atPath: helper) else {
            Log.write("CrashRelaunch", "no relauncher in this build (\(CrashRelaunch.helperPath)); not protected")
            TelemetryCounters.add(CrashRelaunch.unavailableCounter)
            return
        }
        let arguments = RelauncherArguments(
            watchedPID: getpid(),
            processName: Bundle.main.executableURL?.lastPathComponent ?? "Pacer",
            command: CrashRelaunch.relaunchCommand(bundlePath: Bundle.main.bundlePath))
        switch RelaunchProcess.start(executable: helper, arguments: arguments.arguments, initial: plan.instruction) {
        case .failure(let failure):
            Log.write("CrashRelaunch", "could not start the relauncher (\(failure)); not protected")
            TelemetryCounters.add(CrashRelaunch.unavailableCounter)
        case .success(let started):
            input = started.input
            switch plan.instruction {
            case .relaunch(let seconds):
                Log.write("CrashRelaunch", "armed (relauncher pid \(started.pid)): "
                          + "an exit without quitting relaunches Pacer after \(seconds) s")
            case .stayDown(let relaunches):
                Log.write("CrashRelaunch", "\(relaunches) relaunches in \(minutes) min: if this run exits "
                          + "without quitting too, Pacer stays closed until it is opened "
                          + "(relauncher pid \(started.pid))")
                rearmOnceTheRelaunchesAgeOut()
            case .quit:
                break
            }
        }
    }

    /// Pacer is ending on purpose: the relauncher must not bring it back.
    /// Called first thing in `applicationShouldTerminate` (Quit, ⌘Q, logout,
    /// shutdown, Sparkle's install and `make install`'s AppleScript quit all
    /// arrive there), so a hang or a kill during the shutdown that follows is
    /// not mistaken for a crash; before the fatal store alert's `exit(1)`; and
    /// when Sparkle says it is about to relaunch the new version.
    static func standDown() {
        guard input >= 0, !stoodDown else { return }
        stoodDown = true
        // A relauncher already gone (`bin/dev-quit-app.sh` stops it first)
        // makes this a quiet failure: the write end raises no SIGPIPE.
        RelaunchProcess.send(.quit, to: input)
    }

    /// A run that hit the cap at launch, then stayed up: once its relaunches
    /// are older than the window it is not in a loop, and a later crash
    /// should bring it back. Without this, a loop that settled would leave
    /// the run unprotected for as long as it lasts, which can be days.
    private static func rearmOnceTheRelaunchesAgeOut() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(RelaunchPolicy.window + 5))
            guard input >= 0, !stoodDown else { return }
            let instruction = CrashRelaunch.currentInstruction()
            guard case .relaunch(let seconds) = instruction, RelaunchProcess.send(instruction, to: input) else { return }
            Log.write("CrashRelaunch", "up for \(Int(RelaunchPolicy.window / 60)) min since the last relaunch: "
                      + "an exit without quitting relaunches Pacer after \(seconds) s again")
        }
    }
}
