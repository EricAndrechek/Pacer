import Darwin
import Foundation

// The grader's worker threads. A cycle is the unit of work: every model still
// missing at every cut of one completed cycle, on one thread. Cycles of a
// window share nothing a worker writes, except what is shared on purpose and
// safe for it (the forecast memo, the store-level memos, the networks, each
// making one thing once: `ArenaInFlight`), so they can run side by side
// whatever account or window they belong to, and a one-account user with one
// window gets the same speed-up as anyone.
//
// Workers are plain threads, not a Swift task group: their work is long,
// synchronous and paced by sleeping the thread, which on the cooperative pool
// would take a thread the rest of the app's tasks need. The scorer's actor
// only plans, collects and saves: it waits here, with no thread, between the
// cycles the workers hand back.

/// Wakes the scorer's actor: a cycle handed back, a worker gone, the worker
/// count changed, or a stop. One signal is enough however many arrive: it
/// looks at everything when it wakes.
final class ArenaWakeup: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var signalled = false

    func signal() {
        lock.lock()
        let wake = waiters
        waiters = []
        signalled = wake.isEmpty
        lock.unlock()
        wake.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if signalled {
                signalled = false
                lock.unlock()
                c.resume()
            } else {
                waiters.append(c)
                lock.unlock()
            }
        }
    }
}

/// The scorer's worker threads running now, so a stop can raise them to the
/// class of whatever waits on it (#446).
///
/// A worker runs at background QoS (`ArenaBudgetPolicy.scorerQoS`), and a
/// saturated Mac schedules nothing at that class: in #431 four sat runnable
/// at priority 4 with 0.0% CPU for minutes. A quit waiting for them to reach
/// their next check waited that long too. Once a stop has `hurry`ed them,
/// every worker runs at the stop's class until it leaves, through a kernel
/// override (`pthread_override_qos_class_start_np`): the thread's own class,
/// and the cut-by-cut `ArenaQoS.apply`, are untouched, and the override ends
/// when it leaves. A worker that starts after the stop is raised as it
/// enters. Nothing here changes what a worker runs at before a stop
/// (`BackgroundQoS`, #443).
///
/// Only a running thread is ever raised: a worker enters on its own thread
/// and leaves under the same lock `hurry` takes, before the thread ends, so
/// no override is started on a thread that has gone.
final class ArenaWorkerThreads: @unchecked Sendable {
    private struct Entry {
        let thread: pthread_t
        var override: OpaquePointer?
    }

    private let lock = NSLock()
    // Guarded by `lock`.
    private var entries: [Int: Entry] = [:]
    private var next = 0
    private var hurriedTo: qos_class_t?

    /// The calling thread begins its work; `leave` with what this returns.
    func enter() -> Int {
        let me = pthread_self()
        lock.lock(); defer { lock.unlock() }
        next += 1
        entries[next] = Entry(thread: me, override: hurriedTo.flatMap { Self.override(me, $0) })
        return next
    }

    /// The calling thread is done: anything waiting on it has been told, and
    /// it goes back to its own class to end.
    func leave(_ token: Int) {
        lock.lock()
        let entry = entries.removeValue(forKey: token)
        lock.unlock()
        if let o = entry?.override { pthread_override_qos_class_end_np(o) }
    }

    /// Run every worker at `qos` or above from now until it leaves, those
    /// that start later included. Returns how many running workers it raised.
    /// Once is what a stop needs: a second call raises only the workers the
    /// first did not reach, to the first's class.
    @discardableResult
    func hurry(to qos: qos_class_t) -> Int {
        lock.lock(); defer { lock.unlock() }
        let to = hurriedTo ?? qos
        hurriedTo = to
        var raised = 0
        for (token, entry) in entries where entry.override == nil {
            guard let o = Self.override(entry.thread, to) else { continue }
            entries[token]?.override = o
            raised += 1
        }
        return raised
    }

    /// Workers running now.
    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    /// Tests: runs on each worker's thread before it begins, standing in for
    /// the wait a busy Mac can give a new background thread before its first
    /// instruction (`ArenaScoringCrew.isFinished`).
    var beforeBeginning: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return beginning }
        set { lock.lock(); beginning = newValue; lock.unlock() }
    }
    private var beginning: (@Sendable () -> Void)?

    /// An override of `thread` to `qos`, or nil if the kernel refused one.
    /// The SDK imports the result as never nil, though the call returns NULL
    /// for a class or priority it does not take: read the bits as they are.
    private static func override(_ thread: pthread_t, _ qos: qos_class_t) -> OpaquePointer? {
        unsafeBitCast(pthread_override_qos_class_start_np(thread, qos, 0), to: OpaquePointer?.self)
    }
}

/// One phase's workers: which cycle goes to which thread, and what comes back.
///
/// The cycles go out in the order one thread would take them (each window's
/// turn, newest first), so the order the record fills in does not depend on
/// how many workers there are, only how fast it does.
final class ArenaScoringCrew: @unchecked Sendable {
    typealias Scorer = ArenaRecordScorer

    /// One completed cycle's work, all of it by value: a forecast touches
    /// nothing of the pass's own.
    struct Job {
        let stream: Int
        let account: String
        let binding: ArenaWindowBinding
        let store: ArenaHistoryStore
        let surface: String
        let baseSurface: String
        let weekly: Bool
        let inputs: [String: String]
        let cycle: BurnTrajectory.Cycle
        let period: String
        /// The grading's cuts with anything missing, and what is missing there.
        let cuts: [(index: Int, models: [ArenaModelSpec])]
    }

    /// What a worker hands back.
    struct Handback {
        let stream: Int
        let account: String
        let surface: String
        let cycle: BurnTrajectory.Cycle
        var news: [EngineSelfEval.NewOutcome] = []
        /// (model, cut) pairs graded.
        var graded: [(model: String, cut: Int)] = []
        var declined: [String] = []
        var report = Scorer.Report()
        /// The worker stopped before the end: the cycle goes back in the queue
        /// for whatever is still missing.
        var abandoned = false
    }

    private let scorer: Scorer
    private let phase: Scorer.Phase
    private let wake: ArenaWakeup
    private let budget: ArenaCPUBudget
    private let cancel: ArenaCancelFlag
    private let threads: ArenaWorkerThreads
    private let lock = NSLock()
    // Guarded by `lock`.
    private var streams: [Scorer.Stream]
    private var declined: Set<String>
    private var cursor = -1
    private var turnLeft = 0
    /// Workers started (`staff`) and not yet gone.
    private var active = Set<Int>()
    /// Of those, the ones whose thread has begun: only these can hold a cycle.
    private var running = Set<Int>()
    private var handed: [Handback] = []
    private var plan: Scorer.ProgressPlan

    init(scorer: Scorer, phase: Scorer.Phase, streams: [Scorer.Stream], declined: Set<String>,
         plan: Scorer.ProgressPlan, wake: ArenaWakeup, budget: ArenaCPUBudget, cancel: ArenaCancelFlag,
         threads: ArenaWorkerThreads) {
        self.scorer = scorer; self.phase = phase; self.streams = streams; self.declined = declined
        self.plan = plan; self.wake = wake; self.budget = budget; self.cancel = cancel; self.threads = threads
    }

    /// What the actor gets back once the phase is over.
    func finish() -> (streams: [Scorer.Stream], declined: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        return (streams, declined)
    }

    /// The pause just ended (`ProgressPlan.resumed`).
    func resumed() {
        lock.lock(); plan.resumed(); lock.unlock()
    }

    var activeWorkers: Int { lock.lock(); defer { lock.unlock() }; return active.count }

    var hasQueued: Bool {
        lock.lock(); defer { lock.unlock() }
        return streams.contains { !$0.queue.isEmpty }
    }

    /// Whether the phase is over: every worker gone, and nothing queued. Or
    /// the scorer is stopping, and every worker that has begun is gone: what
    /// is queued waits for the next launch, and a thread started but not yet
    /// run holds nothing. It finds the stop at its first claim and leaves; on
    /// a saturated Mac a background thread can wait minutes for that first
    /// instruction, and a stop must not wait with it (#446).
    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        if cancel.isSet { return running.isEmpty }
        return active.isEmpty && !streams.contains { !$0.queue.isEmpty }
    }

    /// What has come back since the last call.
    func drain() -> [Handback] {
        lock.lock(); defer { lock.unlock() }
        let out = handed
        handed = []
        return out
    }

    /// Start the workers the count allows and the queue can use. A worker past
    /// the count stops by itself (`stopNow`).
    func staff() {
        guard !cancel.isSet else { return }
        let target = budget.scorerWorkers
        lock.lock()
        let queued = streams.reduce(0) { $0 + $1.queue.count }
        var start: [Int] = []
        var room = max(0, queued - active.filter { $0 < target }.count)
        for i in 0..<target where room > 0 && !active.contains(i) {
            active.insert(i)
            start.append(i)
            room -= 1
        }
        lock.unlock()
        for i in start { spawn(i) }
    }

    private func spawn(_ index: Int) {
        let thread = Thread { [self] in work(index) }
        thread.name = "com.ericandrechek.pacer.arena.worker.\(index)"
        // A model's children recurse a few levels deep; a dispatch worker's
        // 512 KB has been enough, and a thread's stack is only reserved until
        // it is used.
        thread.stackSize = 1 << 20
        // Through `BackgroundQoS`: a test waiting on this pass must get it
        // scheduled on a saturated Mac (#431).
        switch BackgroundQoS.applied(budget.scorerQoS) {
        case QOS_CLASS_USER_INITIATED: thread.qualityOfService = .userInitiated
        case QOS_CLASS_UTILITY: thread.qualityOfService = .utility
        default: thread.qualityOfService = .background
        }
        thread.start()
    }

    /// Whether worker `index` should stop: the scorer is stopping, or the
    /// count no longer reaches it.
    private func stopNow(_ index: Int) -> Bool {
        cancel.isSet || index >= budget.scorerWorkers
    }

    /// A worker thread, from its first cycle until nothing is left for it.
    private func work(_ index: Int) {
        threads.beforeBeginning?()
        // Before the first claim, so a stop that finds this worker running
        // can raise it (`ArenaWorkerThreads`), and waits for it (`isFinished`).
        let token = threads.enter()
        lock.lock()
        running.insert(index)
        lock.unlock()
        let stopped = ArenaCancelFlag()
        let budget = self.budget, cancel = self.cancel
        let shouldStop: @Sendable () -> Bool = {
            if stopped.isSet { return true }
            if cancel.isSet || index >= budget.scorerWorkers { stopped.set(true); return true }
            return false
        }
        var services = scorer.services
        // Every check a model makes for cancellation is also where it pays for
        // its CPU, on this thread's own clock, and where a worker the count no
        // longer reaches finds out.
        let check = services.isCancelled
        services.isCancelled = {
            budget.checkpoint(cancelled: shouldStop)
            return shouldStop() || check()
        }
        services.isAbandoned = { stopped.isSet }
        services.sharesWork = true
        let runner = ArenaRunner(registry: scorer.roster.registry, services: services, memo: scorer.memo)
        var warm = Set<String>()
        budget.mark()
        while let job = claim(index) {
            stopped.set(false)
            let back = scorer.grade(job, runner: runner, warm: &warm, stopped: shouldStop)
            deliver(back)
        }
        budget.leave()
        lock.lock()
        active.remove(index)
        running.remove(index)
        lock.unlock()
        wake.signal()
        // Last: a stop may be waiting on the signal above, at the class it
        // raised this thread to.
        threads.leave(token)
    }

    /// The next cycle, in the order one thread would take them: each window's
    /// turn in order, newest cycles first, a window's first turn long enough
    /// for selection (`EngineSelfEval.rlMinPeriods`).
    private func claim(_ index: Int) -> Job? {
        guard !stopNow(index) else { return nil }
        lock.lock(); defer { lock.unlock() }
        while let i = nextStream() {
            let models = scorer.phaseModels(streams[i], phase)
            guard !models.isEmpty else {
                streams[i].queue.removeAll()
                turnLeft = 0
                continue
            }
            turnLeft -= 1
            return job(i, cycle: streams[i].queue.removeFirst(), models: models)
        }
        return nil
    }

    private func nextStream() -> Int? {
        if turnLeft > 0, streams.indices.contains(cursor), !streams[cursor].queue.isEmpty { return cursor }
        guard !streams.isEmpty else { return nil }
        for k in 1...streams.count {
            let i = (cursor + k) % streams.count
            guard !streams[i].queue.isEmpty else { continue }
            cursor = i
            let weekly = streams[i].window.isWeeklyScale
            let perTurn = max(1, weekly ? scorer.config.weeklyCyclesPerTurn : scorer.config.sessionCyclesPerTurn)
            turnLeft = streams[i].turns == 0 ? max(perTurn, EngineSelfEval.rlMinPeriods(weekly: weekly)) : perTurn
            streams[i].turns += 1
            return i
        }
        return nil
    }

    private func job(_ i: Int, cycle: BurnTrajectory.Cycle, models: [ArenaModelSpec]) -> Job {
        let s = streams[i]
        let period = EngineSelfEval.periodKeyRL(cycle.resetsAt)
        let grading = scorer.config.grading
        var cuts: [(index: Int, models: [ArenaModelSpec])] = []
        for (ci, cf) in grading.cuts.enumerated() {
            let missing = models.filter {
                !scorer.isDone(s, $0.name, cut: ci, period: period)
                    && !declined.contains(Scorer.key(s.surface, $0.name, grading.bucket(cf), period))
            }
            if !missing.isEmpty { cuts.append((ci, missing)) }
        }
        return Job(stream: i, account: s.account, binding: s.binding, store: s.store, surface: s.surface,
                   baseSurface: EngineSelfEval.rlSurface(s.window.key), weekly: s.window.isWeeklyScale,
                   inputs: s.inputs, cycle: cycle, period: period, cuts: cuts)
    }

    private func deliver(_ back: Handback) {
        var back = back
        lock.lock()
        declined.formUnion(back.declined)
        let period = EngineSelfEval.periodKeyRL(back.cycle.resetsAt)
        for g in back.graded {
            guard let key = scorer.doneKey(streams[back.stream], g.model, cut: g.cut, period: period) else { continue }
            streams[back.stream].existing.insert(key)
            if streams[back.stream].stale.remove(key) != nil { back.report.regraded += 1 }
        }
        if back.abandoned {
            // Newest first still: this was the next cycle when it was taken.
            streams[back.stream].queue.insert(back.cycle, at: 0)
        } else {
            // Here, not when the actor wakes: the board is current by the time
            // this worker takes its next cycle.
            plan.visited(scorer.currentRate)
            scorer.publishProgress(streams, account: back.account, phase: phase, plan: plan)
        }
        handed.append(back)
        lock.unlock()
        wake.signal()
    }
}

/// How many worker threads a speed-up may run on a Mac.
public enum ArenaWorkerPolicy {
    /// One less than the performance cores, so a core always stays free for
    /// what the user is doing, and one per 2 GB of memory above the first 4 GB,
    /// at least one. Measured on a real store, a worker adds about 170 MB of
    /// footprint, most of it network scratch; the network weights are memory
    /// maps every worker shares (1.4 GB resident at one worker and at eight), and
    /// the page-ins did not grow with the count. So memory only limits an 8 GB
    /// Mac (two workers), which is the one that would feel it: such a Mac is
    /// often under pressure, when `ArenaMemoryHold` keeps it to one anyway.
    public static func maxWorkers(performanceCores: Int, physicalMemory: UInt64) -> Int {
        let gigabytes = Int(physicalMemory >> 30)
        return max(1, min(performanceCores - 1, (gigabytes - 4) / 2))
    }

    /// This Mac's.
    public static let forThisMac = maxWorkers(performanceCores: performanceCores(),
                                              physicalMemory: ProcessInfo.processInfo.physicalMemory)

    /// Apple silicon's performance cores; an Intel Mac has no `perflevel`, and
    /// every physical core is one.
    static func performanceCores() -> Int {
        func read(_ name: String) -> Int? {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            guard sysctlbyname(name, &value, &size, nil, 0) == 0, value > 0 else { return nil }
            return Int(value)
        }
        return read("hw.perflevel0.physicalcpu") ?? read("hw.physicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount
    }
}
