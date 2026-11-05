import CoreFoundation
import Dispatch
import Foundation
import Synchronization

/// Notices a run loop (the app's main one) going `threshold` seconds without a
/// chance to handle input, while it is still stuck, so the report does not
/// depend on the thread ever getting free: a frozen launch that the user
/// force-quits, or an app replaced by an update while hung, is reported too.
///
/// **Why Pacer has its own** (Sentry's is turned off in `TelemetryController`):
/// on macOS sentry-cocoa has only its first watchdog, `SentryANRTrackerV1`. It
/// posts to the main queue every 0.4 s and reports when five posts in a row
/// went unserved, but it skips the check, recording nothing, whenever its own
/// sleep overran by the timeout (meant for a suspended app), it reports
/// "at least 2000 ms" whatever the length, and keeping a hang that ends in a
/// kill for the next launch is iOS-only. On 2026-11-05 a user's Mac started the
/// SDK in three launches of 0.8.1 in five minutes (three sessions reached
/// Sentry), each frozen in the store migration before the menu bar appeared,
/// two of them killed: no hang event, no client-side discard. And its thread
/// woke 2.5 times a second for as long as the app ran, busy or idle.
///
/// **How**: the run loop's own activity says when a stretch of work starts
/// and ends (the observation `RunLoopStallMeter` makes for stalls). A one-shot
/// timer on a background queue is armed only while a stretch is open and is
/// left unarmed once the loop sleeps, so an idle app has no wakeups from this
/// at all. The timer is `.strict`: macOS coalesces a windowless menu-bar
/// app's timers, and a check that comes late here is only late, never
/// skipped, because the length comes from the monotonic clock rather than
/// from counting ticks. Time asleep is not counted (uptime stops with the Mac).
///
/// **Launch counts**: with `startsBusy`, the loop counts as busy from `init`
/// (the app creates this in `PacerAppDelegate.init`, before the store opens
/// and before the main run loop exists) until it first sleeps.
///
/// Events go to `handler` on a private serial queue, never on the watched
/// thread: `.began` once a stretch passes the threshold, `.continuing` every
/// `heartbeat` while it lasts, `.ended` when the loop next gets a chance to
/// handle input.
public final class HangWatch: @unchecked Sendable {  // the timer is a DispatchSource, which is thread-safe

    public struct Hang: Sendable, Equatable {
        /// Monotonic seconds when the stretch began (`HangWatch.uptime`).
        public let start: TimeInterval
        /// How long it has lasted so far, or in all for `.ended`.
        public let duration: TimeInterval
        /// The stretch is the launch: it began before the loop first slept.
        public let atLaunch: Bool

        public init(start: TimeInterval, duration: TimeInterval, atLaunch: Bool) {
            self.start = start; self.duration = duration; self.atLaunch = atLaunch
        }
    }

    public enum Event: Sendable, Equatable {
        case began(Hang), continuing(Hang), ended(Hang)
    }

    /// The bookkeeping, apart from threads, timers and clocks, so a test can
    /// drive it activity by activity.
    public struct Core: Sendable, Equatable {
        public let threshold: TimeInterval
        public let heartbeat: TimeInterval
        /// When the open stretch began, or nil while the loop sleeps.
        public private(set) var busySince: TimeInterval?
        /// The open stretch has already been reported as a hang.
        private var reported = false
        /// The open stretch is the launch one.
        private var launching: Bool
        /// The loop has entered once: the launch stretch runs through the
        /// first `entry` (that is `NSApplication.run` starting, not a chance
        /// to handle input) and ends when the loop first sleeps or polls.
        private var enteredOnce = false
        /// Same rule as `RunLoopStallMeter`: an iteration that did not sleep
        /// polled its event port, which is a chance to handle input.
        private var sleptThisIteration = true

        public init(threshold: TimeInterval, heartbeat: TimeInterval, busySinceLaunch start: TimeInterval?) {
            self.threshold = threshold
            self.heartbeat = heartbeat
            self.busySince = start
            self.launching = start != nil
        }

        /// One run loop activity at `time`. Returns `.ended` when it closed a
        /// stretch that had been reported.
        public mutating func record(_ activity: RunLoopStallMeter.Activity, at time: TimeInterval) -> Event? {
            switch activity {
            case .afterWaiting:
                sleptThisIteration = true
                return restart(at: time)
            case .beforeTimers:
                defer { sleptThisIteration = false }
                if busySince == nil { busySince = time; return nil }
                return sleptThisIteration ? nil : restart(at: time)
            case .beforeWaiting:
                defer { busySince = nil; reported = false; launching = false }
                return close(at: time)
            case .entry:
                sleptThisIteration = true
                if launching && !enteredOnce { enteredOnce = true; return nil }
                enteredOnce = true
                return restart(at: time)
            case .exit:
                return restart(at: time)
            }
        }

        /// The timer fired at `time`. Returns what to report and when to look
        /// again (nil: the loop is asleep, leave the timer unarmed).
        public mutating func check(at time: TimeInterval) -> (event: Event?, next: TimeInterval?) {
            guard let since = busySince else { return (nil, nil) }
            let elapsed = time - since
            guard elapsed >= threshold else { return (nil, since + threshold) }
            let hang = Hang(start: since, duration: elapsed, atLaunch: launching)
            if reported { return (.continuing(hang), time + heartbeat) }
            reported = true
            return (.began(hang), time + heartbeat)
        }

        private mutating func restart(at time: TimeInterval) -> Event? {
            let closed = close(at: time)
            busySince = time
            reported = false
            launching = false
            return closed
        }

        private func close(at time: TimeInterval) -> Event? {
            guard reported, let since = busySince else { return nil }
            return .ended(Hang(start: since, duration: max(0, time - since), atLaunch: launching))
        }
    }

    /// Seconds on the clock the timer uses: uptime, which stops while the Mac
    /// sleeps, so a lid closed in the middle of work is not a hang.
    public static func uptime() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    private struct State {
        var core: Core
        var armed = false
    }

    private let state: Mutex<State>
    private let queue = DispatchQueue(label: "com.ericandrechek.pacer.hang-watch", qos: .userInitiated)
    private let timer: DispatchSourceTimer
    private let handler: @Sendable (Event) -> Void
    private let runLoop: CFRunLoop
    private var observers: [CFRunLoopObserver] = []

    /// - Parameters:
    ///   - runLoop: the loop to watch; its callbacks run on its own thread.
    ///   - startsBusy: count the loop as busy from now until it first sleeps
    ///     (the app's main thread before `NSApplication.run`).
    public init(runLoop: CFRunLoop, threshold: TimeInterval, heartbeat: TimeInterval,
                startsBusy: Bool, handler: @escaping @Sendable (Event) -> Void) {
        let now = Self.uptime()
        self.state = Mutex(State(core: Core(threshold: threshold, heartbeat: heartbeat,
                                            busySinceLaunch: startsBusy ? now : nil),
                                 armed: startsBusy))
        self.runLoop = runLoop
        self.handler = handler
        self.timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.setEventHandler { [weak self] in self?.fire() }
        timer.activate()
        if startsBusy { arm(at: now + threshold) }

        let early: [CFRunLoopActivity] = [.entry, .beforeTimers, .afterWaiting]
        let late: [CFRunLoopActivity] = [.beforeWaiting, .exit]
        for (activities, order) in [(early, CFIndex.min), (late, CFIndex.max)] {
            let mask = activities.reduce(CFOptionFlags(0)) { $0 | $1.rawValue }
            guard let observer = CFRunLoopObserverCreateWithHandler(
                kCFAllocatorDefault, mask, true, order,
                { [weak self] _, activity in self?.observe(activity) }
            ) else { continue }
            // Common modes: a menu being tracked or a modal alert runs the
            // loop in other modes, and both sleep while they wait, which ends
            // the stretch as it should.
            CFRunLoopAddObserver(runLoop, observer, .commonModes)
            observers.append(observer)
        }
    }

    deinit { invalidate() }

    /// Stop watching. Call on the watched loop's thread.
    public func invalidate() {
        for observer in observers {
            CFRunLoopRemoveObserver(runLoop, observer, .commonModes)
            CFRunLoopObserverInvalidate(observer)
        }
        observers.removeAll()
        timer.cancel()
    }

    /// Called on the watched thread for every activity: a lock and a few
    /// assignments; the timer is touched only when it has to be armed.
    private func observe(_ activity: CFRunLoopActivity) {
        let mapped: RunLoopStallMeter.Activity
        switch activity {
        case .entry: mapped = .entry
        case .beforeTimers: mapped = .beforeTimers
        case .beforeWaiting: mapped = .beforeWaiting
        case .afterWaiting: mapped = .afterWaiting
        case .exit: mapped = .exit
        default: return
        }
        let now = Self.uptime()
        let (event, armAt) = state.withLock { s -> (Event?, TimeInterval?) in
            let event = s.core.record(mapped, at: now)
            guard !s.armed, let since = s.core.busySince else { return (event, nil) }
            s.armed = true
            return (event, since + s.core.threshold)
        }
        if let armAt { arm(at: armAt) }
        // Off the watched thread: the handler writes files and talks to Sentry.
        if let event { queue.async { [handler] in handler(event) } }
    }

    /// Runs on `queue`.
    private func fire() {
        let now = Self.uptime()
        let (event, next) = state.withLock { s -> (Event?, TimeInterval?) in
            let (event, next) = s.core.check(at: now)
            s.armed = next != nil
            return (event, next)
        }
        if let next { arm(at: next) }
        if let event { handler(event) }
    }

    private func arm(at deadline: TimeInterval) {
        let nanoseconds = UInt64(max(0, deadline) * 1_000_000_000)
        timer.schedule(deadline: DispatchTime(uptimeNanoseconds: nanoseconds),
                       repeating: .never, leeway: .milliseconds(50))
    }
}
