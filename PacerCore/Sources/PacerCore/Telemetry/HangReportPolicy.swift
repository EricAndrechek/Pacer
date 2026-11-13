import CoreGraphics
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

    /// Whether every online display is asleep right now, asked of
    /// CoreGraphics directly and safe off the main thread. The flag above only
    /// flips back to awake when the wake notification reaches the main queue,
    /// and a main thread already stuck when someone wakes the screen can't
    /// receive it, so the flag would hold back exactly the hang they are
    /// watching. No online display (lid closed, no external screen) counts as
    /// asleep.
    public static func allDisplaysAsleepNow() -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return isAsleep }
        guard count > 0 else { return true }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return isAsleep }
        return ids.prefix(Int(count)).allSatisfy { CGDisplayIsAsleep($0) != 0 }
    }
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

    /// Whether the displays are asleep for this decision: the watchdog's flag,
    /// confirmed live when it says asleep (see
    /// `DisplaySleepState.allDisplaysAsleepNow`). Only the asleep case pays
    /// for the query, and it is the one a missed wake would get wrong.
    public static func displaysAsleepNow() -> Bool {
        DisplaySleepState.isAsleep && DisplaySleepState.allDisplaysAsleepNow()
    }

    /// Decide and, when the hang is not sent, count it. True: send it.
    public static func admit(displaysAsleep: Bool = displaysAsleepNow()) -> Bool {
        if shouldSend(displaysAsleep: displaysAsleep) { return true }
        TelemetryCounters.add(asleepCounter)
        return false
    }
}
