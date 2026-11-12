import AppKit
import Foundation
import PacerCore

/// Logs when the main thread goes longer than a frame budget without being
/// able to handle input.
///
/// Added because "switching accounts takes about five seconds" could not be
/// explained by anything measurable: the pace chart's own load was 578 ms and
/// already off the main actor, and every other query on the dashboard reads a
/// table of a few hundred rows. Guessing produced three plausible culprits and
/// no evidence. This produces evidence — a timestamped duration for every main
/// thread stall, so a slow interaction says how long it blocked and when.
///
/// **It watches the run loop, not a timer.** The first version ran a 20 Hz
/// timer and logged whenever a tick came late. macOS throttles a background
/// app's timers, so while the user was working in another app every tick came
/// late and logged: ~16,000 lines an hour, for four days, while clicks in the
/// same hours were delivered in 2–4 ms (#168). Observers are only called when
/// the loop runs, so throttling cannot fake a stall, and there is no timer
/// waking the app twenty times a second to look.
///
/// The observing and the accounting are `RunLoopStallObserver` and
/// `RunLoopStallMeter` in PacerCore, where a unit test runs them against a real
/// run loop.
@MainActor
final class MainThreadStallWatchdog {
    static let shared = MainThreadStallWatchdog()

    private var observer: RunLoopStallObserver?

    /// Whether every display is asleep, so a stall line says whether anyone
    /// could have felt it.
    ///
    /// The rate of these lines depends far more on this than on any build.
    /// Over 141 hours of one Mac's log before #403, hours with the displays
    /// asleep ran about 1,460 stalls an hour and hours with them awake about
    /// 300. Asleep, the whole process ran slower, not just the main thread:
    /// on #403 the same forecast refit took a median 15 s of CPU against 6 s
    /// awake, and the stalls were 80-95% waiting rather than working.
    /// Comparing two builds across a change of display state read as a 4x
    /// regression (#403) that was not one.
    ///
    /// Mirrored into `DisplaySleepState`, which `HangReporter` reads from
    /// another queue to hold back hang events nobody could feel.
    private var displaysAsleep = false {
        didSet { DisplaySleepState.set(asleep: displaysAsleep) }
    }
    private var sleepObservers: [NSObjectProtocol] = []

    private init() {}

    func start() {
        guard observer == nil else { return }
        // Seeded from the main display: a launch while the displays sleep (an
        // install over a locked screen) gets no `screensDidSleep` of its own.
        displaysAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        let workspace = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                                  object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MainThreadStallWatchdog.shared.displaysAsleep = true }
            },
            workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                  object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MainThreadStallWatchdog.shared.displaysAsleep = false }
            },
        ]
        // `cpu` is the main thread's own CPU time in the stretch. Close to the
        // wall time means it was working; far below means it was waiting (a
        // lock, a fetch blocked on another context's write) or throttled.
        observer = RunLoopStallObserver(runLoop: CFRunLoopGetMain(), threshold: 0.1) { stall in
            // The observer fires on the main run loop, so this is the main actor.
            let asleep = MainActor.assumeIsolated { MainThreadStallWatchdog.shared.displaysAsleep }
            Log.write("MainThread",
                      "stalled \(Int(stall.wall * 1000))ms (cpu \(Int(stall.cpu * 1000))ms)"
                        + (asleep ? " · displays asleep" : ""))
            // The log keeps every stall over 100 ms; telemetry sends only the
            // ones a person would feel (250 ms and up). The rest are one
            // in-memory tally, drained into the daily check-in.
            if stall.wall >= 0.25 {
                // Busy (working) vs waiting (a lock or throttled), in thirds.
                let busy = stall.wall > 0 ? stall.cpu / stall.wall : 0
                let cpuBucket = busy >= 0.66 ? "busy" : busy >= 0.33 ? "mixed" : "waiting"
                Telemetry.distribution("main_thread.stall_ms", stall.wall * 1000, unit: .millisecond,
                                       attributes: ["cpu": .string(cpuBucket),
                                                    "pressure": .string(MemoryPressure.shared.level.name)])
                Telemetry.breadcrumb("stall", "\(Int(stall.wall * 1000)) ms")
            } else {
                TelemetryCounters.add("main_thread.stall_100ms")
            }
        }
    }
}
