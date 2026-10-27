import Darwin
import Foundation

/// The arena's share of the CPU, counted in the CPU time its threads used, and
/// enforced where the models already stop to check for cancellation.
///
/// **Why CPU time, and why inside a forecast.** The first runtime paced the
/// scorer after each cut, by the cut's wall time, with a 30 s cap on the
/// sleep. In the installed (unoptimised) build one cut of two dozen models ran
/// for minutes, so the cap won and the scorer held a core at 100% for long
/// stretches (`sample(1)`: 1968 of 1968 samples busy in `CalibModel.forecast`).
/// Wall time also counts time the thread spent waiting for a core on a loaded
/// Mac, and misses any other thread the work fans out to. This charges the
/// thread CPU time (`CLOCK_THREAD_CPUTIME_ID`) the arena's own threads used
/// (BLAS is held to the calling thread while the runtime runs, see
/// `ArenaRuntime.start`), and sleeps the thread whenever the account is
/// overdrawn, at every `ArenaServices.isCancelled` check: before every model
/// and child forecast and inside every backtest. So the share holds over
/// seconds, not over a cut.
///
/// A token bucket: `rate` CPU-seconds accrue per second of wall time, up to
/// `burst`; each checkpoint spends what the thread used since its last one.
/// One budget is shared by every arena lane, so the scorer and the live
/// forecaster together stay within `rate`. The live forecaster is urgent (the
/// dashboard waits on it): while it works the scorer waits at its next
/// checkpoint (up to `maxUrgentYield` at a time), so the live answers get the
/// budget first.
public final class ArenaCPUBudget: @unchecked Sendable {

    /// Where time comes from: the system's clocks in the app, a script in tests.
    public struct Clock: Sendable {
        /// Seconds, monotonic.
        public var wall: @Sendable () -> Double
        /// The calling thread's CPU time, seconds.
        public var threadCPU: @Sendable () -> Double
        /// The calling thread's id.
        public var threadID: @Sendable () -> UInt64
        public var sleep: @Sendable (Double) -> Void

        public init(wall: @escaping @Sendable () -> Double, threadCPU: @escaping @Sendable () -> Double,
                    threadID: @escaping @Sendable () -> UInt64, sleep: @escaping @Sendable (Double) -> Void) {
            self.wall = wall; self.threadCPU = threadCPU; self.threadID = threadID; self.sleep = sleep
        }

        public static let system = Clock(
            wall: { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9 },
            threadCPU: { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) * 1e-9 },
            threadID: { var tid: UInt64 = 0; pthread_threadid_np(nil, &tid); return tid },
            sleep: { s in if s > 0 { usleep(useconds_t(min(s, 1) * 1_000_000)) } })
    }

    /// CPU-seconds per second: 0.25 is a quarter of one core. At most one
    /// core: the arena's work is one thread at a time per lane, and BLAS is
    /// held to the calling thread, so the thread clocks it is charged by
    /// see all of it. Changed while it runs by `ArenaBudgetGovernor`.
    public var rate: Double {
        get { lock.lock(); defer { lock.unlock() }; return currentRate }
        set { setRate(newValue) }
    }
    static func clampRate(_ r: Double) -> Double { min(1, max(0.01, r.isFinite ? r : 0.2)) }
    /// The most CPU time that may be spent ahead of the rate after a quiet
    /// spell, seconds: a short live forecast after an idle minute runs at once.
    public let burst: Double
    /// The longest single sleep, so cancellation and an urgent lane are seen
    /// promptly.
    static let sleepStep = 0.25
    /// The longest a non-urgent checkpoint waits for urgent work before it
    /// takes its turn anyway (still within the rate): in an unoptimised
    /// build one round of live projections can outlast the five minutes
    /// between refits, and the scorer must not starve behind it forever.
    static let maxUrgentYield = 5.0

    private let clock: Clock
    private let createdAt: Double
    private let lock = NSLock()
    // Guarded by `lock`.
    private var currentRate: Double
    private var currentScorerQoS = QOS_CLASS_BACKGROUND
    private var tokens: Double
    private var refilledAt: Double
    private var marks: [UInt64: Double] = [:]
    private var urgent = 0
    private var spentTotal = 0.0
    private var sleptTotal = 0.0

    public init(rate: Double, burst: Double = 2, clock: Clock = .system) {
        self.currentRate = Self.clampRate(rate)
        self.burst = max(0, burst)
        self.clock = clock
        self.tokens = max(0, burst)
        self.refilledAt = clock.wall()
        self.createdAt = clock.wall()
    }

    /// A new rate from now on. What accrued at the old rate up to now stays
    /// earned; on a cut the bucket gives up any credit, so the lower share
    /// holds from the next checkpoint rather than after the burst.
    public func setRate(_ r: Double) {
        let now = clock.wall()
        let new = Self.clampRate(r)
        lock.lock(); defer { lock.unlock() }
        tokens = min(burst, tokens + max(0, now - refilledAt) * currentRate)
        refilledAt = now
        if new < currentRate { tokens = min(tokens, 0) }
        currentRate = new
    }

    /// The QoS the scorer runs its work at (`ArenaQoS.apply`, at every cut):
    /// background, the efficiency cores only, at the everyday share; utility,
    /// which may use the performance cores, while the governor gives it the
    /// full core (`ArenaBudgetPolicy.scorerQoS`).
    public var scorerQoS: qos_class_t {
        get { lock.lock(); defer { lock.unlock() }; return currentScorerQoS }
        set { lock.lock(); currentScorerQoS = newValue; lock.unlock() }
    }

    /// The calling thread's CPU time, seconds, on the budget's clock.
    public func threadCPUSeconds() -> Double { clock.threadCPU() }

    /// CPU seconds charged so far, and seconds slept to stay within the rate.
    public var totals: (spent: Double, slept: Double) {
        lock.lock(); defer { lock.unlock() }
        return (spentTotal, sleptTotal)
    }

    /// CPU charged per second since the budget was made: the share of one
    /// core the arena has averaged (at most `rate`, plus `burst` early on).
    public var averageShare: Double {
        let elapsed = clock.wall() - createdAt
        lock.lock(); defer { lock.unlock() }
        return elapsed > 0 ? spentTotal / elapsed : 0
    }

    /// Start counting this thread from now, without charging what it did
    /// before (other work a pooled thread ran in between).
    public func mark() {
        let id = clock.threadID(), cpu = clock.threadCPU()
        lock.lock()
        if marks.count > 64 { marks.removeAll(keepingCapacity: true) }
        marks[id] = cpu
        lock.unlock()
    }

    /// An urgent lane starts or stops working; non-urgent checkpoints wait
    /// while any is.
    public func beginUrgent() { lock.lock(); urgent += 1; lock.unlock() }
    public func endUrgent() { lock.lock(); urgent = max(0, urgent - 1); lock.unlock() }

    /// Charge the CPU this thread used since its last mark or checkpoint, then
    /// sleep for as long as the budget is overdrawn (and, unless `urgent`,
    /// while an urgent lane works). Returns at once when `cancelled` is true.
    public func checkpoint(urgent isUrgent: Bool = false, cancelled: () -> Bool = { false }) {
        let id = clock.threadID(), cpu = clock.threadCPU()
        lock.lock()
        if let last = marks[id] {
            let used = max(0, cpu - last)
            tokens -= used
            spentTotal += used
        }
        marks[id] = cpu
        lock.unlock()
        var yielded = 0.0
        while !cancelled() {
            let wait = needed(yieldToUrgent: !isUrgent && yielded < Self.maxUrgentYield)
            guard wait > 0 else { break }
            let step = min(Self.sleepStep, wait)
            clock.sleep(step)
            yielded += step
            lock.lock(); sleptTotal += step; lock.unlock()
        }
        // What the thread did while it slept was nothing; start from here.
        mark()
    }

    /// How long to wait before the next step may run: zero when the bucket is
    /// in credit (and, when yielding, no urgent lane is working).
    private func needed(yieldToUrgent: Bool) -> Double {
        lock.lock(); defer { lock.unlock() }
        let now = clock.wall()
        tokens = min(burst, tokens + max(0, now - refilledAt) * currentRate)
        refilledAt = now
        if yieldToUrgent, urgent > 0 { return Self.sleepStep }
        // Under a millisecond owed is paid: a wait the clock can't resolve
        // would never end.
        let wait = -tokens / currentRate
        return wait > 0.001 ? wait : 0
    }
}
