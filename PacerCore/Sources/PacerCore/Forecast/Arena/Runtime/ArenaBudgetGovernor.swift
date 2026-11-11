import CoreGraphics
import Foundation
import IOKit
import IOKit.ps
import Synchronization

// How much CPU the arena may use right now: one full core while the Mac is
// plugged in, cool, not in Low Power Mode and nobody has touched it for two
// minutes; a fifth of one core otherwise (`ArenaCPUBudget`). The user can
// waive the plugged-in and idle conditions for the catch-up, for up to an
// hour, and while the Mac is plugged in can have several cores
// (`ArenaSpeedUp`, `ArenaWorkerPolicy`); never against heat or Low Power Mode.
// Memory pressure holds the everyday rate to one worker at the everyday share
// at `.warning`, and a speed-up to half its workers; `.critical` pauses
// back-scoring either way (`ArenaMemoryHold`).
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
// snapshot. One core unless the user asked for more: the scorer's workers and
// the live lane are one thread each, BLAS stays on the calling thread, and the
// budget is shared by all of them, so its thread-CPU accounting stays exact.

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

/// What memory pressure does to back-scoring. `.warning`: one worker at the
/// everyday share, or half a speed-up's workers (`ArenaBudgetPolicy.decide`).
/// `.critical`: nothing at all, sped up or not. Going back up takes a calm
/// first, then one more worker per step, from where `.warning` left it. Pure, so the transitions
/// can be tested with a scripted level and clock (`ArenaBudgetGovernor` feeds
/// it).
///
/// **Why `.warning` does not pause.** It is common on a Mac doing nothing
/// wrong: under a heavy parallel build a 48 GB Mac with half its memory free sat
/// at `.warning` for 76% of three hours, in stretches of up to 36 minutes, and
/// with no such load 28 warnings in two days came a median of 30 minutes
/// apart. A pause needing minutes of `.normal` to lift would starve grading on
/// exactly the Macs that are often busy, and the grade that is waiting is the
/// forecast the user is looking at. What a single worker holds at a fifth of a
/// core is small and bounded (its memo and scratch are dropped on the way in,
/// `ArenaMemoryRelief`), and the fifth also bounds how fast it re-reads the
/// network weights macOS has evicted. `.critical` is the system saying it is
/// out of room, which is rare and worth a real stop.
///
/// **Why two minutes.** Everything the pressure dropped has to be made again to
/// go back up, and that is the memory it was about. Warnings come in bursts: in
/// those two days 2 came within 90 s of the one before and the rest at least 5
/// minutes after, and under that build the quiet stretches inside a burst were
/// 56 to 107 s. Two minutes clears every burst seen, and a longer calm would
/// keep a speed-up at one worker on a Mac that has room for more.
///
/// **Why a ramp.** Each worker adds its own stack of scratch; going straight
/// back to nine would be the same jump that may have caused the pressure.
public struct ArenaMemoryHold: Sendable, Equatable {
    public static let calmSeconds: Double = 120
    public static let rampStepSeconds: Double = 30

    public private(set) var level = MemoryPressure.Level.normal
    /// The last moment the level was above normal, and at critical.
    private var lastPressure: Double?
    private var lastCritical: Double?

    public init() {}

    /// The level at `now`. A level easing counts as under pressure until this
    /// very moment: a running governor hears it as it happens.
    public mutating func step(level next: MemoryPressure.Level, now: Double) {
        if level == .critical || next == .critical { lastCritical = now }
        if level > .normal || next > .normal { lastPressure = now }
        level = next
    }

    /// No back-scoring: at critical, and for the calm after it.
    public func isPaused(now: Double) -> Bool {
        level == .critical || (lastCritical.map { now - $0 < Self.calmSeconds } ?? false)
    }

    /// `floor` (one, or the half a speed-up is allowed at `.warning`) unless
    /// memory has been quiet: normal now, for the calm, then one more per
    /// step, up to `maxWorkers`.
    public func workers(now: Double, maxWorkers: Int, floor: Int = 1) -> Int {
        let most = max(1, maxWorkers)
        let base = min(most, max(1, floor))
        guard level == .normal else { return base }
        guard let lastPressure else { return most }
        let quiet = now - lastPressure - Self.calmSeconds
        guard quiet >= 0 else { return base }
        return min(most, base + Int(quiet / Self.rampStepSeconds))
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
        /// The user's speed-up, plugged in: this many cores (two or more).
        case cores(Int)
        /// Critical memory pressure: no back-scoring at all (`ArenaMemoryHold`).
        case paused
    }

    public enum Reason: String, Sendable, Equatable {
        case thermal, lowPower = "low power mode", lowMemory = "low memory", battery = "on battery", inUse = "in use"
    }

    /// What the live lane may make: every model drawn, each window's pick
    /// only, or nothing for now (its cache stays, and its requests come again
    /// at the next refit).
    public enum LiveLane: Sendable, Equatable { case all, picksOnly, none }

    /// Everything the rule sets (`ArenaBudgetGovernor` applies it).
    public struct Decision: Sendable, Equatable {
        public var mode: Mode
        /// The scorer's workers: 1 but under a speed-up; 0 while paused.
        public var workers: Int
        /// CPU-seconds per second for the whole arena.
        public var rate: Double
        public var liveLane: LiveLane
        /// The user's speed-up is what sets `mode` (not held back by heat or
        /// Low Power Mode, not paused).
        public var spedUp = false
        /// Sped up, and held to fewer workers by memory at `.warning`.
        public var lowMemory = false
        /// The QoS the scorer works at (`scorerQoS`).
        public var qos: qos_class_t = QOS_CLASS_BACKGROUND
    }

    /// `spedUp`: the user asked for more (`ArenaSpeedUp`), which lifts the
    /// battery and idle gates, and while plugged in gives `workers` cores. Not
    /// the thermal or Low Power Mode ones: those are the Mac's own state, and a
    /// forecast sheet is no place to overrule them. `lowMemory`: macOS reports
    /// memory pressure, which holds an unrequested rate to the share; a
    /// speed-up is held by it through `workers` (`decide`) instead.
    public static func mode(_ s: ArenaBudgetSignals, spedUp: Bool = false, workers: Int = 1,
                            lowMemory: Bool = false) -> Mode {
        // The first reason that holds, the machine's own state before the
        // user's: a hot Mac is held back however long it has been idle.
        if s.thermal == .serious || s.thermal == .critical { return .share(.thermal) }
        if s.lowPowerMode { return .share(.lowPower) }
        if lowMemory && !spedUp { return .share(.lowMemory) }
        if spedUp { return s.onACPower && workers > 1 ? .cores(workers) : .fullCore }
        if !s.onACPower { return .share(.battery) }
        if !(s.idleSeconds >= idleSeconds) { return .share(.inUse) }
        return .fullCore
    }

    /// The whole decision, the one place it is made. Heat and Low Power Mode
    /// come first (in `mode`), then memory.
    ///
    /// **Memory.** `.critical` pauses, sped up or not. At `.warning` an
    /// unrequested rate drops to one worker at the share. A speed-up is the
    /// user's own ask, for at most an hour, and a `.warning` is common on a Mac
    /// with room to spare, so it goes on at half its workers (at least one,
    /// still at the full rate); on battery it is one core already. When
    /// pressure eases the crew starts from that half and ramps to the full
    /// count; without a speed-up the ramp starts from one.
    ///
    /// **The live lane under pressure.** It keeps the dashboard's numbers from
    /// going stale, so it does not stop with the scorer: at `.warning` it makes
    /// only each window's pick (a request or two, at the everyday share, on a
    /// runner it does not keep), and at `.critical` nothing at all, leaving
    /// what is in its cache to age out onto the engine's fits. The engine asks
    /// for the same; this holds whoever else asks to it.
    public static func decide(_ s: ArenaBudgetSignals, spedUp: Bool = false, hold: ArenaMemoryHold = ArenaMemoryHold(),
                              now: Double = 0, maxWorkers: Int = 1, shareRate: Double, fullRate: Double = 1)
        -> Decision {
        let lane: LiveLane = hold.level == .critical ? .none : hold.level == .warning ? .picksOnly : .all
        if hold.isPaused(now: now) {
            return Decision(mode: .paused, workers: 0, rate: shareRate, liveLane: lane,
                            qos: scorerQoS(.paused, spedUp: false))
        }
        let warned = hold.level > .normal
        let workers = hold.workers(now: now, maxWorkers: maxWorkers, floor: spedUp ? max(1, maxWorkers / 2) : 1)
        let mode = mode(s, spedUp: spedUp, workers: workers, lowMemory: warned)
        switch mode {
        case .cores(let n):
            return Decision(mode: mode, workers: n, rate: Double(n) * fullRate, liveLane: lane, spedUp: true,
                            lowMemory: warned, qos: scorerQoS(mode, spedUp: true))
        case .fullCore:
            return Decision(mode: mode, workers: 1, rate: fullRate, liveLane: lane, spedUp: spedUp,
                            lowMemory: warned && spedUp, qos: scorerQoS(mode, spedUp: spedUp))
        case .share, .paused:
            return Decision(mode: mode, workers: 1, rate: shareRate, liveLane: lane,
                            qos: scorerQoS(mode, spedUp: false))
        }
    }

    /// The QoS the scorer works at in `mode`. At the everyday share:
    /// background, behind everything the user runs. At a full core the Mac
    /// gave itself (plugged in and idle): utility, so it may run on a
    /// performance core (background QoS keeps a thread on the efficiency
    /// cores, where a forecast costs several times the CPU). While `spedUp`,
    /// at a full core or several: user-initiated. On a busy Mac (load 50 to
    /// 200) utility gained nothing from more workers (462 s at one against
    /// 472 s at eight), and user-initiated was about four times faster at
    /// eight (69 s against 272 s). The user asked for it, for at most an hour,
    /// and heat, Low Power Mode and memory pressure still hold it back
    /// (`decide`), so the user's own work is not starved for long.
    public static func scorerQoS(_ mode: Mode, spedUp: Bool) -> qos_class_t {
        switch mode {
        case .cores: return QOS_CLASS_USER_INITIATED
        case .fullCore: return spedUp ? QOS_CLASS_USER_INITIATED : QOS_CLASS_UTILITY
        case .share, .paused: return QOS_CLASS_BACKGROUND
        }
    }

    /// Which measured pace the board's time left is made from in `mode`
    /// (`ArenaScoringProgress.Pace`).
    public static func paceRate(_ mode: Mode) -> ArenaScoringProgress.Rate {
        switch mode {
        case .fullCore: return .cores(1)
        case .cores(let n): return .cores(n)
        case .share, .paused: return .share
        }
    }

    /// The coarse mode for telemetry: `full` (a whole core), `fifth` (the
    /// everyday share), `multi` (several cores) or `paused` (low memory).
    public static func telemetryName(_ mode: Mode) -> String {
        switch mode {
        case .fullCore: return "full"
        case .share: return "fifth"
        case .cores: return "multi"
        case .paused: return "paused"
        }
    }

    /// What the log says: `full core (plugged in, idle)`, `full core (sped
    /// up)`, `9 cores (sped up)`, `4 cores (sped up, low memory)`, `20% of a
    /// core (on battery)`, `paused (low memory)`.
    public static func describe(_ mode: Mode, shareRate: Double, spedUp: Bool = false,
                                lowMemory: Bool = false) -> String {
        let why = lowMemory ? ", low memory" : ""
        switch mode {
        case .fullCore: return spedUp ? "full core (sped up\(why))" : "full core (plugged in, idle)"
        case .share(let reason): return String(format: "%.0f%% of a core (%@)", shareRate * 100, reason.rawValue)
        case .cores(let n): return "\(n) cores (sped up\(why))"
        case .paused: return "paused (low memory)"
        }
    }
}

/// Sets the arena budget's rate and the scorer's workers from the policy,
/// every 30 s, every 2 s while a full core or more is in use (so the user's
/// return is seen at once), and at once on a thermal, power-mode or
/// memory-pressure change or a speed-up turned on or off. Logs each change of
/// rate. Ends a speed-up once nothing is left to catch up (`pending`) or its
/// time is up, and publishes the pace the sheet shows (`ArenaSpeedUp.status`).
public final class ArenaBudgetGovernor: @unchecked Sendable {
    public static let interval: TimeInterval = 30
    public static let fullCoreInterval: TimeInterval = 2

    /// Told the mode name (`ArenaBudgetPolicy.telemetryName`) at the first
    /// evaluation and whenever it changes. The app's telemetry layer sets this
    /// to tag crash and CPU reports; PacerCore does not link Sentry. Called
    /// off the main thread; keep it cheap.
    public static var onModeChange: (@Sendable (String) -> Void) {
        get { modeObserver.withLock { $0 } }
        set { modeObserver.withLock { $0 = newValue } }
    }
    /// The last mode reported, for an observer installed after the first
    /// evaluation (nil before it).
    public static var lastModeName: String? { lastMode.withLock { $0 } }
    private static let lastMode = Mutex<String?>(nil)
    private static let modeObserver = Mutex<@Sendable (String) -> Void>({ _ in })

    private let budget: ArenaCPUBudget
    private let shareRate: Double
    private let fullRate: Double
    private let maxWorkers: Int
    private let pressure: MemoryPressure
    private let read: @Sendable () -> ArenaBudgetSignals
    private let log: @Sendable (String) -> Void
    private let speedUp: ArenaSpeedUp?
    private let pending: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "com.ericandrechek.pacer.arena.governor", qos: .utility)
    private let lock = NSLock()
    // Guarded by `lock`.
    private var decision: ArenaBudgetPolicy.Decision?
    private var hold = ArenaMemoryHold()
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var listener: UUID?
    private var pressureListener: UUID?

    /// - Parameters:
    ///   - shareRate: the everyday share (a fifth of a core).
    ///   - fullRate: plugged in and idle, or sped up; at most one core.
    ///   - maxWorkers: the most workers a speed-up may run on this Mac
    ///     (`ArenaWorkerPolicy`); 1, it stays at one core.
    ///   - pressure: the memory level this governor holds back-scoring to;
    ///     by default one that stays normal (the app's runtime passes
    ///     `MemoryPressure.shared`).
    ///   - speedUp: the user's speed-up this governor honours and publishes
    ///     its pace to; nil, none.
    ///   - pending: whether catch-up work is still queued
    ///     (`ArenaScoringProgressBoard.hasWork`): a speed-up ends once it
    ///     is not.
    ///   - now: the clock a speed-up's hour and a memory hold are measured on
    ///     (tests pin it).
    public init(budget: ArenaCPUBudget, shareRate: Double, fullRate: Double = 1, maxWorkers: Int = 1,
                pressure: MemoryPressure = MemoryPressure(watching: false),
                speedUp: ArenaSpeedUp? = nil, pending: @escaping @Sendable () -> Bool = { true },
                now: @escaping @Sendable () -> Date = { Date() },
                read: @escaping @Sendable () -> ArenaBudgetSignals = { ArenaBudgetSignals.current() },
                log: @escaping @Sendable (String) -> Void = { Log.write("Arena", $0) }) {
        self.budget = budget
        self.shareRate = min(1, ArenaCPUBudget.clampRate(shareRate))
        self.fullRate = max(self.shareRate, min(1, ArenaCPUBudget.clampRate(fullRate)))
        self.maxWorkers = max(1, maxWorkers)
        self.pressure = pressure
        self.speedUp = speedUp
        self.pending = pending
        self.now = now
        self.read = read
        self.log = log
    }

    deinit { stop() }

    /// The current mode (nil before the first evaluation).
    public var current: ArenaBudgetPolicy.Mode? { lock.lock(); defer { lock.unlock() }; return decision?.mode }

    /// Read the signals and set the rate and the workers; returns the mode.
    @discardableResult
    public func evaluate() -> ArenaBudgetPolicy.Mode {
        let at = now()
        let spedUp = speedUpHolds(at: at)
        let signals = read(), level = pressure.level
        let t = at.timeIntervalSinceReferenceDate
        lock.lock()
        let previous = decision
        hold.step(level: level, now: t)
        let next = ArenaBudgetPolicy.decide(signals, spedUp: spedUp, hold: hold, now: t, maxWorkers: maxWorkers,
                                            shareRate: shareRate, fullRate: fullRate)
        decision = next
        lock.unlock()
        speedUp?.publish(ArenaPace(mode: next.mode, speedUpUntil: spedUp ? speedUp?.until : nil,
                                   lowMemory: next.lowMemory))
        budget.liveLane = next.liveLane
        if previous == nil || previous?.rate != next.rate || previous?.workers != next.workers
            || previous?.qos != next.qos {
            // The rate first: a worker let go must find the lower rate, and a
            // worker added must find the higher one.
            budget.rate = next.rate
            budget.scorerQoS = next.qos
            budget.scorerWorkers = next.workers
            log("budget: " + ArenaBudgetPolicy.describe(next.mode, shareRate: shareRate, spedUp: spedUp,
                                                       lowMemory: next.lowMemory))
            let name = ArenaBudgetPolicy.telemetryName(next.mode)
            Self.lastMode.withLock { $0 = name }
            Self.onModeChange(name)
            reschedule(fast: next.rate > shareRate)
        }
        return next.mode
    }

    /// Whether the user's speed-up holds at `at`; one whose hour is up, or
    /// with nothing left to catch up, is ended here.
    private func speedUpHolds(at: Date) -> Bool {
        guard let speedUp, let until = speedUp.until else { return false }
        if at >= until { speedUp.end(.timeUp, now: at); return false }
        if !pending() { speedUp.end(.caughtUp, now: at); return false }
        return true
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
        // A speed-up turned on or off takes hold at once, not at the next tick.
        let id = speedUp?.listen { [weak self] in
            guard let queue = self?.queue else { return }
            queue.async { [weak self] in self?.evaluate() }
        }
        // Pressure takes hold at once, and a level easing starts the calm from
        // the moment it happened.
        let pid = pressure.listen { [weak self] _ in
            guard let queue = self?.queue else { return }
            queue.async { [weak self] in self?.evaluate() }
        }
        lock.lock()
        observers = tokens
        listener = id
        pressureListener = pid
        lock.unlock()
        t.activate()
        queue.async { [weak self] in self?.evaluate() }
    }

    public func stop() {
        lock.lock()
        let t = timer, obs = observers, id = listener, pid = pressureListener
        timer = nil
        observers = []
        listener = nil
        pressureListener = nil
        lock.unlock()
        t?.cancel()
        obs.forEach { NotificationCenter.default.removeObserver($0) }
        if let id { speedUp?.unlisten(id) }
        if let pid { pressure.unlisten(pid) }
    }

    /// The next evaluations at the cadence the mode needs (a no-op before
    /// `start()`, so a test's `evaluate()` leaves nothing running).
    private func reschedule(fast: Bool) {
        let every = fast ? Self.fullCoreInterval : Self.interval
        lock.lock()
        let t = timer
        lock.unlock()
        t?.schedule(deadline: .now() + every, repeating: every, leeway: .milliseconds(fast ? 250 : 1000))
    }
}

/// Sets the calling thread's QoS for the work it runs next.
///
/// Each of the scorer's workers is a thread of its own (`ArenaScoringCrew`).
/// It applies the QoS it should have at every cut (`scorerQoS`), so a change
/// of mode takes hold within one cut. On a dispatch queue's thread the QoS
/// lasts until the job returns, when dispatch puts it back to the queue's.
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
