import CoreGraphics
import Foundation
import IOKit
import IOKit.ps

// How much CPU the arena may use right now: one full core while the Mac is
// plugged in, cool, not in Low Power Mode and nobody has touched it for two
// minutes; a fifth of one core otherwise (`ArenaCPUBudget`).
//
// The first launch's back-scoring is hours of CPU at a fifth of a core. Most
// Macs that run Pacer sit plugged in and idle for long stretches (overnight,
// meetings, lunch), when a core the user is not using costs them nothing:
// no battery, no fan they would hear over their own work, no app of theirs
// waiting. The moment any of that stops being true the share drops back,
// within a couple of seconds for the user coming back (the idle clock is
// read every two seconds while the full core is in use), and at once for a
// thermal or power-mode change (both post notifications).
//
// Everything here only reads the machine's state: the idle time is
// `CGEventSource`'s seconds since the last input event (no events are ever
// posted, no tap is installed), the power source is IOKit's power-sources
// snapshot. Never more than one core: the arena's lanes are one thread each,
// BLAS stays on the calling thread, and the budget is shared by both lanes,
// so its thread-CPU accounting stays exact.

/// What the policy reads.
public struct ArenaBudgetSignals: Sendable, Equatable {
    /// Running on mains power. A Mac with no battery always is.
    public var onACPower: Bool
    public var lowPowerMode: Bool
    public var thermal: ProcessInfo.ThermalState
    /// Seconds since the user last used a keyboard, mouse or trackpad.
    public var idleSeconds: Double

    public init(onACPower: Bool, lowPowerMode: Bool, thermal: ProcessInfo.ThermalState, idleSeconds: Double) {
        self.onACPower = onACPower; self.lowPowerMode = lowPowerMode; self.thermal = thermal
        self.idleSeconds = idleSeconds
    }

    /// This Mac, now.
    public static func current() -> ArenaBudgetSignals {
        ArenaBudgetSignals(onACPower: Self.onACPower(), lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                           thermal: ProcessInfo.processInfo.thermalState, idleSeconds: Self.idleSeconds())
    }

    /// IOKit's providing power source. Unknown counts as battery: the full
    /// core is only for a Mac we know is plugged in.
    static func onACPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMACPowerKey
    }

    /// Seconds since the last input event of any kind, read from the window
    /// server's event-source state; IOKit's `HIDIdleTime` if that fails.
    /// Zero (in use) when neither answers.
    static func idleSeconds() -> Double {
        if let any = CGEventType(rawValue: ~0) {
            let s = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
            if s.isFinite, s >= 0 { return s }
        }
        return hidIdleSeconds() ?? 0
    }

    static func hidIdleSeconds() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return nil }
        return value.doubleValue / 1e9
    }
}

/// The rule, apart from the machine, so it can be tested.
public enum ArenaBudgetPolicy {
    /// How long nobody has to have touched the Mac.
    public static let idleSeconds: Double = 120

    public enum Mode: Sendable, Equatable {
        case fullCore
        /// The everyday share, and why it is not the full core.
        case share(Reason)
    }

    public enum Reason: String, Sendable, Equatable {
        case thermal, lowPower = "low power mode", battery = "on battery", inUse = "in use"
    }

    public static func mode(_ s: ArenaBudgetSignals) -> Mode {
        // The first reason that holds, the machine's own state before the
        // user's: a hot Mac is held back however long it has been idle.
        if s.thermal == .serious || s.thermal == .critical { return .share(.thermal) }
        if s.lowPowerMode { return .share(.lowPower) }
        if !s.onACPower { return .share(.battery) }
        if !(s.idleSeconds >= idleSeconds) { return .share(.inUse) }
        return .fullCore
    }

    /// The QoS the scorer works at in `mode`: utility at the full core, so
    /// it may run on a performance core (background QoS keeps a thread on
    /// the efficiency cores, where a forecast costs several times the CPU);
    /// background at the everyday share, behind everything the user runs.
    public static func scorerQoS(_ mode: Mode) -> qos_class_t {
        mode == .fullCore ? QOS_CLASS_UTILITY : QOS_CLASS_BACKGROUND
    }

    /// What the log says: `full core (plugged in, idle)`, `20% of a core (on battery)`.
    public static func describe(_ mode: Mode, shareRate: Double) -> String {
        switch mode {
        case .fullCore: return "full core (plugged in, idle)"
        case .share(let reason): return String(format: "%.0f%% of a core (%@)", shareRate * 100, reason.rawValue)
        }
    }
}

/// Sets the arena budget's rate from the policy, every 30 s, every 2 s while
/// the full core is in use (so the user's return is seen at once), and at
/// once on a thermal or power-mode notification. Logs each change of rate.
public final class ArenaBudgetGovernor: @unchecked Sendable {
    public static let interval: TimeInterval = 30
    public static let fullCoreInterval: TimeInterval = 2

    private let budget: ArenaCPUBudget
    private let shareRate: Double
    private let fullRate: Double
    private let read: @Sendable () -> ArenaBudgetSignals
    private let log: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "com.ericandrechek.pacer.arena.governor", qos: .utility)
    private let lock = NSLock()
    // Guarded by `lock`.
    private var mode: ArenaBudgetPolicy.Mode?
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []

    /// - Parameters:
    ///   - shareRate: the everyday share (a fifth of a core).
    ///   - fullRate: plugged in and idle; at most one core.
    public init(budget: ArenaCPUBudget, shareRate: Double, fullRate: Double = 1,
                read: @escaping @Sendable () -> ArenaBudgetSignals = { ArenaBudgetSignals.current() },
                log: @escaping @Sendable (String) -> Void = { Log.write("Arena", $0) }) {
        self.budget = budget
        self.shareRate = ArenaCPUBudget.clampRate(shareRate)
        self.fullRate = max(self.shareRate, ArenaCPUBudget.clampRate(fullRate))
        self.read = read
        self.log = log
    }

    deinit { stop() }

    /// The current mode (nil before the first evaluation).
    public var current: ArenaBudgetPolicy.Mode? { lock.lock(); defer { lock.unlock() }; return mode }

    /// Read the signals and set the rate; returns the mode.
    @discardableResult
    public func evaluate() -> ArenaBudgetPolicy.Mode {
        let next = ArenaBudgetPolicy.mode(read())
        lock.lock()
        let previous = mode
        mode = next
        lock.unlock()
        let rate = next == .fullCore ? fullRate : shareRate
        let wasFull = previous == .fullCore
        if previous == nil || wasFull != (next == .fullCore) {
            budget.rate = rate
            budget.scorerQoS = ArenaBudgetPolicy.scorerQoS(next)
            log("budget: " + ArenaBudgetPolicy.describe(next, shareRate: shareRate))
            reschedule(full: next == .fullCore)
        }
        return next
    }

    /// Evaluate now and keep evaluating until `stop()`.
    public func start() {
        lock.lock()
        guard timer == nil else { lock.unlock(); return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        timer = t
        lock.unlock()
        t.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .seconds(1))
        t.setEventHandler { [weak self] in self?.evaluate() }
        let center = NotificationCenter.default
        let tokens = [ProcessInfo.thermalStateDidChangeNotification,
                      Notification.Name.NSProcessInfoPowerStateDidChange].map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.queue.async { self?.evaluate() }
            }
        }
        lock.lock()
        observers = tokens
        lock.unlock()
        t.activate()
        queue.async { [weak self] in self?.evaluate() }
    }

    public func stop() {
        lock.lock()
        let t = timer, obs = observers
        timer = nil
        observers = []
        lock.unlock()
        t?.cancel()
        obs.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// The next evaluations at the cadence the mode needs (a no-op before
    /// `start()`, so a test's `evaluate()` leaves nothing running).
    private func reschedule(full: Bool) {
        let every = full ? Self.fullCoreInterval : Self.interval
        lock.lock()
        let t = timer
        lock.unlock()
        t?.schedule(deadline: .now() + every, repeating: every, leeway: .milliseconds(full ? 250 : 1000))
    }
}

/// Sets the calling thread's QoS for the work it runs next.
///
/// The scorer's actor runs on a background serial queue; each stretch of work
/// between suspensions is one job on one of the queue's worker threads, and
/// dispatch puts the thread back to the queue's QoS when the job returns. So
/// the scorer applies the QoS it should have at every cut (`scorerQoS`), and
/// a change of mode takes hold within one cut.
public enum ArenaQoS {
    private static let failures = ArenaCancelFlag()

    /// Returns whether the thread now runs at `qos`.
    @discardableResult
    public static func apply(_ qos: qos_class_t) -> Bool {
        guard qos_class_self() != qos else { return true }
        let rc = pthread_set_qos_class_self_np(qos, 0)
        if rc != 0, !failures.isSet {
            failures.set(true)
            Log.write("Arena", "could not set the scorer's QoS (\(rc)); it stays at the queue's")
        }
        return rc == 0
    }
}
