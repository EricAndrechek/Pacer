import Foundation
import Synchronization

/// Whether every display is asleep. Written by `MainThreadStallWatchdog`
/// (which owns the detection: the sleep/wake notifications plus a seed from
/// the main display) and read from `HangWatch`'s queue, so it is a lock, not
/// main-actor state.
public enum DisplaySleepState {
    private static let asleep = Mutex(false)
    public static var isAsleep: Bool { asleep.withLock { $0 } }
    public static func set(asleep value: Bool) { asleep.withLock { $0 = value } }
}

/// Which hangs are worth an "App Hanging" event.
///
/// Every hang event seen in production landed while the displays were asleep.
/// macOS slows the whole process then (stalls run 5-10x as often) and nobody is
/// looking, yet those events spent the per-Mac daily hang cap and sent alert
/// emails. They are counted instead, drained into the daily check-in.
public enum HangReportPolicy {
    /// Counter for hangs not sent because every display was asleep.
    public static let asleepCounter = "main_thread.hang_displays_asleep"

    public static func shouldSend(displaysAsleep: Bool) -> Bool { !displaysAsleep }

    /// Decide and, when the hang is not sent, count it. True: send it.
    public static func admit(displaysAsleep: Bool = DisplaySleepState.isAsleep) -> Bool {
        if shouldSend(displaysAsleep: displaysAsleep) { return true }
        TelemetryCounters.add(asleepCounter)
        return false
    }
}
