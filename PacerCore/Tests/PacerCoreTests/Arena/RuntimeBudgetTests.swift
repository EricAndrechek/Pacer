import Foundation
import Testing
@testable import PacerCore

/// The arena's CPU budget (`ArenaCPUBudget`), on a scripted clock: the work
/// is "CPU time the thread used", the sleeps advance the wall clock, and the
/// share the work gets is what the budget allows.
@Suite("Arena runtime: the CPU budget")
struct RuntimeBudgetTests {

    /// A clock the test drives: `work` spends CPU (and the same wall time),
    /// `sleep` only wall time. One thread unless `thread` is changed.
    final class Script: @unchecked Sendable {
        let lock = NSLock()
        var wall = 1000.0
        var cpu: [UInt64: Double] = [:]
        var thread: UInt64 = 1
        var slept = 0.0
        var onSleep: (() -> Void)?

        func work(_ s: Double) {
            lock.lock(); wall += s; cpu[thread, default: 0] += s; lock.unlock()
        }

        var clock: ArenaCPUBudget.Clock {
            ArenaCPUBudget.Clock(
                wall: { self.lock.lock(); defer { self.lock.unlock() }; return self.wall },
                threadCPU: { self.lock.lock(); defer { self.lock.unlock() }; return self.cpu[self.thread, default: 0] },
                threadID: { self.lock.lock(); defer { self.lock.unlock() }; return self.thread },
                sleep: { s in
                    self.lock.lock(); self.wall += s; self.slept += s; let hook = self.onSleep; self.lock.unlock()
                    hook?()
                })
        }
    }

    @Test func aQuarterOfACoreIsAQuarterOfTheWallClock() {
        let script = Script()
        let budget = ArenaCPUBudget(rate: 0.25, burst: 0, clock: script.clock)
        budget.mark()
        let start = script.wall
        // 200 steps of 50 ms CPU each: 10 s of work.
        for _ in 0..<200 {
            script.work(0.05)
            budget.checkpoint()
        }
        let elapsed = script.wall - start
        // 10 s of CPU at a quarter of a core is 40 s of wall time.
        #expect(abs(elapsed - 40) < 0.5)
        #expect(abs(budget.totals.spent - 10) < 1e-9)
        #expect(abs(budget.totals.slept - 30) < 0.5)
    }

    /// One long step (a forecast with no check inside) is paid for in full
    /// at the next checkpoint: nothing caps the sleep and breaks the share.
    @Test func aLongStepIsPaidForInFull() {
        let script = Script()
        let budget = ArenaCPUBudget(rate: 0.25, burst: 0, clock: script.clock)
        budget.mark()
        script.work(90)
        budget.checkpoint()
        #expect(abs(script.slept - 270) < 0.3)
    }

    /// After a quiet spell up to `burst` seconds run without a pause.
    @Test func aQuietSpellBuysABurst() {
        let script = Script()
        let budget = ArenaCPUBudget(rate: 0.25, burst: 2, clock: script.clock)
        script.wall += 60
        budget.mark()
        script.work(1.5)
        budget.checkpoint()
        #expect(script.slept == 0)
        // 3 s against 2 in hand (and 0.75 earned meanwhile): a pause.
        script.work(3)
        budget.checkpoint()
        #expect(abs(script.slept - 1) < 1e-6)
    }

    /// `mark` starts a thread's count afresh: what a pooled thread did for
    /// someone else before is not charged.
    @Test func markForgetsWhatTheThreadDidBefore() {
        let script = Script()
        let budget = ArenaCPUBudget(rate: 0.25, burst: 0, clock: script.clock)
        script.work(100)            // not the arena's
        budget.mark()
        script.work(0.01)
        budget.checkpoint()
        #expect(abs(budget.totals.spent - 0.01) < 1e-9)
        // A thread first seen at a checkpoint is marked, not charged.
        script.thread = 2
        script.work(50)
        budget.checkpoint()
        #expect(abs(budget.totals.spent - 0.01) < 1e-9)
    }

    /// Two lanes on two threads share one budget.
    @Test func lanesShareTheBudget() {
        let script = Script()
        let budget = ArenaCPUBudget(rate: 0.5, burst: 0, clock: script.clock)
        for t: UInt64 in [1, 2] { script.thread = t; budget.mark() }
        let start = script.wall
        for i in 0..<100 {
            script.thread = i.isMultiple(of: 2) ? 1 : 2
            script.work(0.1)
            budget.checkpoint()
        }
        // 10 s of CPU between them at half a core: 20 s.
        #expect(abs((script.wall - start) - 20) < 0.5)
    }

    /// While an urgent lane works, the others wait at their checkpoints
    /// however much budget there is; the urgent one does not.
    @Test func theScorerWaitsWhileLiveWorkRuns() {
        let script = Script()
        let budget = ArenaCPUBudget(rate: 1, burst: 100, clock: script.clock)
        budget.mark()
        budget.beginUrgent()
        var sleeps = 0
        script.onSleep = {
            sleeps += 1
            if sleeps == 8 { budget.endUrgent() }
        }
        budget.checkpoint(urgent: true)
        #expect(sleeps == 0)
        budget.checkpoint()
        #expect(sleeps == 8)
        #expect(abs(script.slept - 8 * ArenaCPUBudget.sleepStep) < 1e-9)
    }

    /// Urgent work that never ends does not starve the others: after
    /// `maxUrgentYield` a checkpoint takes its turn.
    @Test func theScorerTakesItsTurnAfterAWhile() {
        let script = Script()
        let budget = ArenaCPUBudget(rate: 1, burst: 100, clock: script.clock)
        budget.mark()
        budget.beginUrgent()
        budget.checkpoint()
        #expect(abs(script.slept - ArenaCPUBudget.maxUrgentYield) < 1e-9)
        budget.endUrgent()
    }

    @Test func cancellingStopsTheWait() {
        let script = Script()
        let budget = ArenaCPUBudget(rate: 0.01, burst: 0, clock: script.clock)
        budget.mark()
        script.work(100)
        var cancelled = false
        script.onSleep = { cancelled = true }
        budget.checkpoint(cancelled: { cancelled })
        // One step, then it saw the flag.
        #expect(abs(script.slept - ArenaCPUBudget.sleepStep) < 1e-9)
    }

    /// The real clocks: thread CPU time moves with work on this thread.
    @Test func theSystemClockCountsThisThread() {
        let clock = ArenaCPUBudget.Clock.system
        let before = clock.threadCPU()
        var x = 0.0
        for i in 0..<2_000_000 { x += sin(Double(i)) }
        #expect(x.isFinite)
        #expect(clock.threadCPU() > before)
        #expect(clock.threadID() == clock.threadID())
    }
}
