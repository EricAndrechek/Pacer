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

    private init() {}

    func start() {
        guard observer == nil else { return }
        observer = RunLoopStallObserver(runLoop: CFRunLoopGetMain(), threshold: 0.1) { stall in
            Log.write("MainThread", "stalled \(Int(stall * 1000))ms")
        }
    }
}
