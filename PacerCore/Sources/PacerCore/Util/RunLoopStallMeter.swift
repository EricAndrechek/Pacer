import Foundation

/// Turns the main run loop's activity into the lengths of time it went without
/// being able to handle input: a stall is one stretch of work between two
/// chances to service the event port.
///
/// This replaced a 20 Hz timer that logged whenever a tick arrived late. macOS
/// throttles a background app's timers, so every late tick counted as a stall:
/// 16,000 `[MainThread] stalled` lines an hour for four days, 97.6% of the log,
/// while clicks in the same hours were delivered in 2–4 ms (#168). A run loop
/// observer is only called when the loop does something, so throttling cannot
/// create a stall and the watchdog adds no wakeups of its own.
///
/// Pure bookkeeping, fed by `MainThreadStallWatchdog` from two observers: one
/// that runs before every other observer (`.afterWaiting`, `.beforeTimers`,
/// `.entry`) and one that runs after every other observer (`.beforeWaiting`,
/// `.exit`). The late one matters: Core Animation commits SwiftUI's layout and
/// rendering in a `.beforeWaiting` observer of its own, and that is often the
/// expensive part of a stretch.
public struct RunLoopStallMeter: Sendable {
    /// The run loop activities the meter understands, mirroring
    /// `CFRunLoopActivity` so this type does not depend on CoreFoundation.
    public enum Activity: Sendable, Equatable {
        /// A run of the loop starts, including a nested one (a menu, a modal).
        case entry
        /// The top of a loop iteration, before timers and sources are handled.
        case beforeTimers
        /// The loop is about to sleep: the stretch of work is over.
        case beforeWaiting
        /// The loop woke for a message: a stretch of work starts.
        case afterWaiting
        /// A run of the loop ends.
        case exit
    }

    /// Stretches shorter than this are not reported. Roughly six frames at
    /// 60 Hz: below it a stall is invisible, above it the window stops
    /// responding.
    public let threshold: TimeInterval

    /// When the current stretch of work began, or nil while the loop sleeps.
    private var busySince: TimeInterval?
    /// Whether the loop has slept since the last iteration began. An iteration
    /// that did not sleep polled its event port and went round again, which is
    /// a chance to handle input, so the next iteration is a new stretch.
    private var sleptThisIteration = true

    public init(threshold: TimeInterval = 0.1) {
        self.threshold = threshold
    }

    /// Record one activity at `time` (seconds, any monotonic origin). Returns
    /// the length of the stretch it closed, if that stretch was a stall.
    public mutating func record(_ activity: Activity, at time: TimeInterval) -> TimeInterval? {
        switch activity {
        case .afterWaiting:
            busySince = time
            sleptThisIteration = true
            return nil
        case .beforeTimers:
            defer { sleptThisIteration = false }
            guard let start = busySince else {
                busySince = time
                return nil
            }
            // Woke, handled the message, came round to the top: same stretch.
            if sleptThisIteration { return nil }
            // Polled without sleeping: the port was checked, so a new stretch.
            busySince = time
            return stall(from: start, to: time)
        case .beforeWaiting:
            defer { busySince = nil }
            return busySince.flatMap { stall(from: $0, to: time) }
        case .entry:
            // A nested run (menu tracking, a modal) handles input itself; the
            // outer stretch so far ends here and the nested loop takes over.
            let closed = busySince.flatMap { stall(from: $0, to: time) }
            busySince = time
            sleptThisIteration = true
            return closed
        case .exit:
            // Back in the outer loop's handler: whatever it does next is a
            // stretch of its own.
            let closed = busySince.flatMap { stall(from: $0, to: time) }
            busySince = time
            return closed
        }
    }

    private func stall(from start: TimeInterval, to end: TimeInterval) -> TimeInterval? {
        let length = end - start
        return length >= threshold ? length : nil
    }
}
