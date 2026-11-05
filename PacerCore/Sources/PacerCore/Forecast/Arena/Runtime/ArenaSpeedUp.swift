import Foundation
import Observation

// The compare sheet's "Speed up". The arena's catch-up (a first launch, or an
// update whose models or grading changed) is hours of CPU, and the full core
// it may use waits for the Mac to be plugged in and left alone for two minutes
// (`ArenaBudgetGovernor`). Someone looking at a board still being scored is,
// by definition, using the Mac, so it runs at a fifth of a core while they
// look. They can ask for the full core now: the speed-up lifts the idle and
// battery gates, never the thermal or Low Power Mode ones (the Mac's own
// state, which a click on a forecast sheet should not overrule), until the
// catch-up is done or an hour has passed, whichever comes first. Then the
// budget is back to its everyday rule. Nothing persists: a relaunch starts at
// the default, so a speed-up can never outlive the work it was asked for.

/// How the arena's budget stands, for the sheet: the governor's mode, and
/// until when the user's speed-up holds (nil: it does not).
public struct ArenaPace: Sendable, Equatable {
    public var mode: ArenaBudgetPolicy.Mode
    public var speedUpUntil: Date?

    public init(mode: ArenaBudgetPolicy.Mode, speedUpUntil: Date? = nil) {
        self.mode = mode; self.speedUpUntil = speedUpUntil
    }

    public var isSpedUp: Bool { speedUpUntil != nil }
}

/// The user's speed-up: on from a click, off from a click, the catch-up
/// finishing or its hour running out. The governor reads it at every
/// evaluation and ends it (`end`); the app's is `shared`, which the runtime
/// uses by default.
public final class ArenaSpeedUp: @unchecked Sendable {
    public static let shared = ArenaSpeedUp()

    /// The longest one speed-up holds.
    public static let limit: TimeInterval = 3600

    public enum End: String, Sendable, CaseIterable {
        case stopped, caughtUp = "caught up", timeUp = "time up"
    }

    /// What views read, on the main actor: the governor's latest pace.
    public let status = ArenaPaceStatus()

    private let lock = NSLock()
    // Guarded by `lock`.
    private var span: (start: Date, end: Date)?
    private var pace: ArenaPace?
    private var listeners: [UUID: @Sendable () -> Void] = [:]

    public init() {}

    /// Until when the speed-up holds; nil when it is off. One past its time
    /// still reads here until the governor ends it, which is also what puts
    /// the rate back.
    public var until: Date? { lock.lock(); defer { lock.unlock() }; return span?.end }

    /// Turn it on for `duration` (at most `limit`) from `now`; again while
    /// on, the time starts over.
    public func start(now: Date = Date(), duration: TimeInterval = limit) {
        lock.lock()
        span = (now, now.addingTimeInterval(min(max(0, duration), Self.limit)))
        let from = Self.telemetryFrom(pace?.mode)
        let wake = Array(listeners.values)
        lock.unlock()
        Log.write("Arena", "speed-up on (from \(from.rawValue)), up to \(Int(Self.limit / 60)) min")
        Analytics.capture(.arenaSpeedUp(.start, from: from))
        wake.forEach { $0() }
    }

    /// The user turned it off.
    public func stop(now: Date = Date()) { end(.stopped, now: now) }

    /// End it, and say why; returns how long it held (nil: it was off).
    @discardableResult
    func end(_ why: End, now: Date = Date()) -> TimeInterval? {
        lock.lock()
        guard let s = span else { lock.unlock(); return nil }
        span = nil
        let wake = Array(listeners.values)
        lock.unlock()
        let held = max(0, min(now, s.end).timeIntervalSince(s.start))
        Log.write("Arena", "speed-up off (\(why.rawValue)) after \(Int((held / 60).rounded())) min")
        Analytics.capture(.arenaSpeedUp(Self.telemetryAction(why), heldSeconds: held))
        wake.forEach { $0() }
        return held
    }

    /// The governor's pace, for `status`. Applied on the main queue, which
    /// reads the newest value when it runs, so two publishes from different
    /// threads can never land out of order.
    func publish(_ next: ArenaPace?) {
        lock.lock()
        guard next != pace else { lock.unlock(); return }
        pace = next
        lock.unlock()
        let status = self.status
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { status.set(self.currentPace) }
        }
    }

    /// The pace last published (nil before the governor's first evaluation).
    public var currentPace: ArenaPace? { lock.lock(); defer { lock.unlock() }; return pace }

    /// Called (on the caller's thread) whenever the speed-up starts or ends;
    /// the governor re-evaluates at once rather than at its next tick.
    func listen(_ wake: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        lock.lock(); listeners[id] = wake; lock.unlock()
        return id
    }

    func unlisten(_ id: UUID) { lock.lock(); listeners[id] = nil; lock.unlock() }

    static func telemetryAction(_ why: End) -> AnalyticsEvent.SpeedUpAction {
        switch why {
        case .stopped: return .stop
        case .caughtUp: return .caughtUp
        case .timeUp: return .timeUp
        }
    }

    static func telemetryFrom(_ mode: ArenaBudgetPolicy.Mode?) -> AnalyticsEvent.SpeedUpFrom {
        switch mode {
        case nil: return .unknown
        case .fullCore?: return .full
        case .share(.inUse)?: return .inUse
        case .share(.battery)?: return .battery
        case .share(.lowPower)?: return .lowPower
        case .share(.thermal)?: return .thermal
        }
    }
}

/// The arena's pace as views read it (`ArenaSpeedUp.status`): set on the main
/// actor from the governor's evaluations, so the sheet's line and its Speed
/// up control follow a click, the user stepping away or coming back, and the
/// speed-up ending on its own, without waiting for the sheet's minute tick.
@MainActor
@Observable
public final class ArenaPaceStatus {
    /// Nil before the governor's first evaluation, and in a process with no
    /// governor (the off-screen render, a runtime with a fixed budget).
    public private(set) var pace: ArenaPace?

    nonisolated public init() {}

    func set(_ next: ArenaPace?) {
        guard next != pace else { return }
        pace = next
    }
}
