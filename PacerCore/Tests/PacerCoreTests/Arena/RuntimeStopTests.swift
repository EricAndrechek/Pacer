import Darwin
import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// A stop, as a quit makes it (#446): it never waits long on workers the Mac
/// is not running, saves what is already back, and what it leaves behind is a
/// record the next launch completes exactly.
@Suite("Arena runtime: stopping at a quit", .serialized, .hangBackstop)
struct RuntimeStopTests {
    typealias Fixtures = RuntimeEngineTests

    /// Holds one caller while armed (the first past `skipping`) until
    /// released, as a worker the scheduler never runs looks to anything
    /// waiting on it: no check reached, no handback, for as long as it likes.
    /// Released or not, it lets go after `giveUp`, so a stop that waits for it
    /// fails the test (every wait below is shorter) instead of hanging the run.
    final class Gate: @unchecked Sendable {
        static let giveUp: TimeInterval = 300
        private let lock = NSLock()
        private var armed = false
        private var skip = 0
        private var holding = false
        private var holder: pthread_t?
        private let release = DispatchSemaphore(value: 0)

        func arm(skipping n: Int = 0) { lock.withLock { armed = true; skip = n } }
        var isHolding: Bool { lock.withLock { holding } }
        /// The thread held now: valid while `isHolding`, which it is until `open`.
        var heldThread: pthread_t? { lock.withLock { holding ? holder : nil } }
        func open() { release.signal() }

        func holdIfArmed() {
            let hold: Bool = lock.withLock {
                guard armed else { return false }
                guard skip == 0 else { skip -= 1; return false }
                armed = false
                holding = true
                holder = pthread_self()
                return true
            }
            guard hold else { return }
            _ = release.wait(timeout: .now() + Self.giveUp)
            lock.withLock { holding = false; holder = nil }
        }
    }

    static let gate = Gate()

    /// `RuntimeEngineTests.Peeker`, behind the gate.
    final class Held: ArenaModel {
        let inner: Fixtures.Peeker
        init(context: ArenaContext) { inner = Fixtures.Peeker(context: context) }
        func fit(_ history: ArenaHistory) { inner.fit(history) }
        func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
            RuntimeStopTests.gate.holdIfArmed()
            return try inner.forecast(request)
        }
    }

    static let held = ArenaModelSpec(name: "test-held", targets: Fixtures.meters, complexity: 2) { Held(context: $0) }
    static let roster = ArenaRoster(registry: [held])

    /// Nothing saved or handed over during the pass: everything back sits
    /// unsaved until the stop.
    static func config() -> ArenaRecordScorer.Config {
        var c = RuntimeWorkersTests.config()
        c.flushOutcomes = .max
        c.flushInterval = 1e9
        return c
    }

    static func runtime(_ container: ModelContainer, workers: Int) -> ArenaRuntime {
        let rt = RuntimeWorkersTests.runtime(container, config: config(), roster: roster, workers: workers)
        // The class the app runs them at (a test process applies utility,
        // `BackgroundQoS`): the gate stands in for the starving.
        rt.budget.scorerQoS = QOS_CLASS_BACKGROUND
        return rt
    }

    /// The thread's scheduling priority: 4 at background, higher for every
    /// class above it, overrides included (`qos_class_self` does not show
    /// those).
    static func priority(_ thread: pthread_t) -> Int32 {
        var info = thread_extended_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_extended_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(pthread_mach_thread_np(thread), thread_flavor_t(THREAD_EXTENDED_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.pth_priority : -1
    }

    /// The issue's check: workers parked mid-cut at background, one of them
    /// never coming back. The stop returns within its bound, with everything
    /// already handed back saved; the store it leaves (what a quit there
    /// leaves) is the uninterrupted record less only the cycle still out; the
    /// next launch's pass completes it exactly; and the abandoned worker,
    /// when it does run, adds nothing.
    @Test func aStopDoesNotWaitForAWorkerTheMacIsNotRunning() async throws {
        let baseline = try Fixtures.seeded(cycles: 6)
        _ = await Self.runtime(baseline, workers: 1).scorer.pass(accounts: [Fixtures.account], now: Fixtures.now)
        let whole = try RuntimeWorkersTests.rows(baseline)
        #expect(whole.count == 6 * Fixtures.cuts)

        let container = try Fixtures.seeded(cycles: 6)
        let rt = Self.runtime(container, workers: 2)
        Self.gate.arm()
        rt.start(accounts: { [Fixtures.account] })
        // One worker held at its first forecast; the other has graded every
        // other cycle and gone.
        #expect(await eventually { Self.gate.isHolding && rt.scorer.workers.count == 1 },
                "the pass never reached the held forecast")
        #expect(try RuntimeWorkersTests.rows(container).isEmpty, "nothing is saved before the stop")

        let held = try #require(Self.gate.heldThread)
        let before = Self.priority(held)
        // From a user-initiated task, as a quit's is: the class the workers
        // are raised to is the waiter's.
        let (wound, took) = await Task(priority: .userInitiated) { () -> (Bool, Duration) in
            let began = ContinuousClock.now
            let wound = await rt.stop()
            return (wound, ContinuousClock.now - began)
        }.value
        #expect(!wound, "the held worker cannot have handed back")
        // The runtime's own worker, raised by the stop out of the class it
        // was started at (utility here, `BackgroundQoS`; background in the
        // app), and still raised while it is out.
        #expect(Self.priority(held) > before, "the stop did not raise the scorer's worker")
        // Its bound, give or take a loaded Mac; a stop that waited for the
        // worker would wait out the gate (`Gate.giveUp`).
        #expect(took < .seconds(30), "the stop waited \(took) for a worker that never ran")

        // Saved by the scorer as it woke to the stop, with the held worker
        // still out: before #446 nothing was saved until every worker was
        // back. (Waited for, not read at once: the scorer's own queue may be
        // a moment behind on a loaded Mac.)
        #expect(try await eventually(timeout: .seconds(120)) {
            try RuntimeWorkersTests.rows(container).count == whole.count - Fixtures.cuts
        }, "what was back before the stop was not saved")
        let left = try RuntimeWorkersTests.rows(container)
        #expect(Set(left).isSubset(of: Set(whole)))
        #expect(Set(whole).subtracting(left).count == Fixtures.cuts, "only the held cycle may be missing")
        #expect(Self.gate.isHolding && rt.scorer.workers.count == 1)

        // The next launch, from exactly that store.
        _ = await Self.runtime(container, workers: 2).scorer.pass(accounts: [Fixtures.account], now: Fixtures.now)
        #expect(try RuntimeWorkersTests.rows(container) == whole)

        // The abandoned worker runs at last: it finds the stop and leaves.
        Self.gate.open()
        #expect(await eventually { rt.scorer.workers.count == 0 }, "the released worker never left")
        await rt.scorer.stop()
        #expect(try RuntimeWorkersTests.rows(container) == whole)
    }

    /// A worker started but not yet run (a busy Mac can make a new background
    /// thread wait minutes for its first instruction) holds no cycle, and a
    /// stop does not wait for it: the stop winds down cleanly, well inside its
    /// bound. The worker, when it runs, finds the stop and leaves.
    @Test func aStopDoesNotWaitForAWorkerThatHasNotBegun() async throws {
        let baseline = try Fixtures.seeded(cycles: 6)
        _ = await Self.runtime(baseline, workers: 1).scorer.pass(accounts: [Fixtures.account], now: Fixtures.now)
        let whole = try RuntimeWorkersTests.rows(baseline)

        let container = try Fixtures.seeded(cycles: 6)
        let rt = Self.runtime(container, workers: 2)
        let notYet = Gate()
        notYet.arm(skipping: 1)
        rt.scorer.workers.beforeBeginning = { notYet.holdIfArmed() }
        rt.start(accounts: { [Fixtures.account] })
        // One worker has graded every cycle and gone; the other was started
        // and has not begun.
        #expect(await eventually { notYet.isHolding && rt.scorer.workers.count == 0 },
                "the pass never got one worker started and the other not begun")

        // A bound far past what winding down takes here, short of the gate's.
        let wound = await rt.stop(within: .seconds(60))
        #expect(wound, "the stop waited for a worker that holds nothing")
        #expect(try RuntimeWorkersTests.rows(container) == whole)

        notYet.open()
        #expect(await eventually { !notYet.isHolding && rt.scorer.workers.count == 0 },
                "the late worker never left")
        #expect(try RuntimeWorkersTests.rows(container) == whole)
    }

    /// A stop raises every running worker to its class until the worker
    /// leaves, and one that starts after the stop as it starts; the thread's
    /// own class is left as it was.
    @Test func aStopRaisesItsWorkersUntilTheyLeave() async throws {
        final class Worker: @unchecked Sendable {
            let threads: ArenaWorkerThreads
            let entered = DispatchSemaphore(value: 0)
            let mayLeave = DispatchSemaphore(value: 0)
            let mayEnd = DispatchSemaphore(value: 0)
            var thread: pthread_t?
            init(_ threads: ArenaWorkerThreads) {
                self.threads = threads
                // Started at utility so it is scheduled to enter on a busy
                // Mac; it then asks for background, as a worker does
                // (`ArenaQoS`), and waits without needing a core.
                let t = Thread { [self] in
                    let token = threads.enter()
                    pthread_set_qos_class_self_np(QOS_CLASS_BACKGROUND, 0)
                    thread = pthread_self()
                    entered.signal()
                    mayLeave.wait()
                    threads.leave(token)
                    mayEnd.wait()
                }
                t.qualityOfService = .utility
                t.start()
                entered.wait()
            }
        }
        let threads = ArenaWorkerThreads()
        let before = Worker(threads)
        let t1 = try #require(before.thread)
        let background = Self.priority(t1)
        #expect(background > 0)
        #expect(threads.count == 1)

        #expect(threads.hurry(to: QOS_CLASS_USER_INITIATED) == 1)
        #expect(await eventually { Self.priority(t1) > background })
        let raised = Self.priority(t1)
        #expect(threads.hurry(to: QOS_CLASS_USER_INITIATED) == 0, "a worker is raised once")

        let after = Worker(threads)
        let t2 = try #require(after.thread)
        #expect(await eventually { Self.priority(t2) == raised }, "a worker starting after the stop is raised as it enters")
        #expect(threads.count == 2)

        // Leaving ends the override: back to what it asked for.
        before.mayLeave.signal()
        #expect(await eventually { threads.count == 1 })
        #expect(await eventually { Self.priority(t1) == background })
        before.mayEnd.signal()
        after.mayLeave.signal()
        #expect(await eventually { threads.count == 0 })
        after.mayEnd.signal()
    }

    /// The waiter's class, kept out of the tier a busy Mac starves and off
    /// the event loop's.
    @Test func theWorkersAreRaisedToTheWaitersClass() {
        let cases: [(qos_class_t, qos_class_t)] = [
            (QOS_CLASS_BACKGROUND, QOS_CLASS_UTILITY), (QOS_CLASS_UTILITY, QOS_CLASS_UTILITY),
            (QOS_CLASS_DEFAULT, QOS_CLASS_DEFAULT), (QOS_CLASS_USER_INITIATED, QOS_CLASS_USER_INITIATED),
            (QOS_CLASS_USER_INTERACTIVE, QOS_CLASS_USER_INITIATED), (QOS_CLASS_UNSPECIFIED, QOS_CLASS_UTILITY),
        ]
        for (waiter, raised) in cases {
            #expect(ArenaRuntime.hurryQoS(waiter: waiter) == raised)
        }
    }

    /// Work that finishes is waited for; work that does not is waited for
    /// only as long as the bound, and goes on after it.
    @Test func aBoundedWaitWaitsNoLongerThanItsBound() async {
        #expect(await BoundedWait.atMost(.seconds(60)) {})

        let gate = AsyncGate()
        let finished = ArenaCancelFlag()
        let began = ContinuousClock.now
        let done = await BoundedWait.atMost(.milliseconds(200)) {
            await gate.wait()
            finished.set(true)
        }
        #expect(!done)
        #expect(ContinuousClock.now - began < .seconds(30))
        #expect(!finished.isSet)
        gate.open()
        #expect(await eventually { finished.isSet }, "the work stopped when the wait did")
    }

    /// Resumes every waiter once opened.
    final class AsyncGate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let now: Bool = lock.withLock {
                    if isOpen { return true }
                    waiters.append(c)
                    return false
                }
                if now { c.resume() }
            }
        }
        func open() {
            let all: [CheckedContinuation<Void, Never>] = lock.withLock {
                isOpen = true
                defer { waiters = [] }
                return waiters
            }
            all.forEach { $0.resume() }
        }
    }
}
