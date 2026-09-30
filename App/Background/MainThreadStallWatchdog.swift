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
/// Two observers because order matters: the early one (`Int.min`) marks the
/// loop waking or starting an iteration before any other observer runs, and
/// the late one (`Int.max`) marks it going to sleep after every other
/// observer, including Core Animation's commit, which is where SwiftUI's
/// layout and rendering land. The accounting is `RunLoopStallMeter`.
@MainActor
final class MainThreadStallWatchdog {
    static let shared = MainThreadStallWatchdog()

    private var meter = RunLoopStallMeter(threshold: 0.1)
    private var observers: [CFRunLoopObserver] = []

    private init() {}

    func start() {
        guard observers.isEmpty else { return }
        let early: [CFRunLoopActivity] = [.entry, .beforeTimers, .afterWaiting]
        let late: [CFRunLoopActivity] = [.beforeWaiting, .exit]
        for (activities, order) in [(early, CFIndex.min), (late, CFIndex.max)] {
            let mask = activities.reduce(CFOptionFlags(0)) { $0 | $1.rawValue }
            guard let observer = CFRunLoopObserverCreateWithHandler(
                kCFAllocatorDefault, mask, true, order,
                { [weak self] _, activity in
                    MainActor.assumeIsolated { self?.record(activity) }
                }) else { continue }
            // Common modes, so a stall is still caught while a menu is open or
            // the window is being resized, which is when the account switch
            // this was written for happens.
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            observers.append(observer)
        }
    }

    private func record(_ activity: CFRunLoopActivity) {
        let mapped: RunLoopStallMeter.Activity
        switch activity {
        case .entry: mapped = .entry
        case .beforeTimers: mapped = .beforeTimers
        case .beforeWaiting: mapped = .beforeWaiting
        case .afterWaiting: mapped = .afterWaiting
        case .exit: mapped = .exit
        default: return
        }
        // System uptime excludes time the machine spent asleep, so a lid close
        // in the middle of a stretch is not reported as a stall.
        if let stall = meter.record(mapped, at: ProcessInfo.processInfo.systemUptime) {
            Log.write("MainThread", "stalled \(Int(stall * 1000))ms")
        }
    }
}
