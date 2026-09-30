import CoreFoundation
import Foundation

/// Watches one run loop and reports each stretch of work longer than the
/// threshold, using `RunLoopStallMeter` for the accounting.
///
/// Two observers, because order matters. The early one (`CFIndex.min`) marks
/// the loop waking or starting an iteration before any other observer runs.
/// The late one (`CFIndex.max`) marks it going to sleep after every other
/// observer, including Core Animation's commit, which is where SwiftUI's
/// layout and rendering land.
///
/// Lives in PacerCore rather than beside the app's watchdog so the real
/// CoreFoundation behaviour can be tested: a unit test runs a loop on its own
/// thread with work of known length and checks what comes out.
///
/// Every callback runs on the observed loop's thread, and so does `report`.
public final class RunLoopStallObserver {
    private var meter: RunLoopStallMeter
    private var observers: [CFRunLoopObserver] = []
    private let runLoop: CFRunLoop
    private let clock: () -> TimeInterval
    private let report: (TimeInterval) -> Void

    /// - Parameters:
    ///   - clock: seconds on a monotonic clock. System uptime by default, which
    ///     excludes time the machine spent asleep, so a lid close in the middle
    ///     of a stretch is not reported as a stall.
    public init(
        runLoop: CFRunLoop,
        threshold: TimeInterval,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        report: @escaping (TimeInterval) -> Void
    ) {
        self.meter = RunLoopStallMeter(threshold: threshold)
        self.runLoop = runLoop
        self.clock = clock
        self.report = report
        let early: [CFRunLoopActivity] = [.entry, .beforeTimers, .afterWaiting]
        let late: [CFRunLoopActivity] = [.beforeWaiting, .exit]
        for (activities, order) in [(early, CFIndex.min), (late, CFIndex.max)] {
            let mask = activities.reduce(CFOptionFlags(0)) { $0 | $1.rawValue }
            guard let observer = CFRunLoopObserverCreateWithHandler(
                kCFAllocatorDefault, mask, true, order,
                { [weak self] _, activity in self?.record(activity) }
            ) else { continue }
            // Common modes, so a stall is still caught while a menu is open or
            // a window is being resized.
            CFRunLoopAddObserver(runLoop, observer, .commonModes)
            observers.append(observer)
        }
    }

    deinit { invalidate() }

    public func invalidate() {
        for observer in observers {
            CFRunLoopRemoveObserver(runLoop, observer, .commonModes)
            CFRunLoopObserverInvalidate(observer)
        }
        observers.removeAll()
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
        if let stall = meter.record(mapped, at: clock()) { report(stall) }
    }
}
