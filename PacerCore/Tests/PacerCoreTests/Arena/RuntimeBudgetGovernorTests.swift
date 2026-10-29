import Foundation
import Testing
@testable import PacerCore

/// The arena's adaptive share (`ArenaBudgetPolicy`, `ArenaBudgetGovernor`):
/// one core while plugged in, cool, out of Low Power Mode and idle two
/// minutes; a fifth of a core otherwise. Signals are injected; nothing here
/// reads the machine.
@Suite("Arena runtime: the adaptive budget")
struct RuntimeBudgetGovernorTests {

    static func signals(ac: Bool = true, lowPower: Bool = false, thermal: ProcessInfo.ThermalState = .nominal,
                        idle: Double = 600) -> ArenaBudgetSignals {
        ArenaBudgetSignals(onACPower: ac, lowPowerMode: lowPower, thermal: thermal, idleSeconds: idle)
    }

    @Test func theFullCoreNeedsEveryConditionAtOnce() {
        typealias P = ArenaBudgetPolicy
        #expect(P.mode(Self.signals()) == .fullCore)
        #expect(P.mode(Self.signals(thermal: .fair)) == .fullCore)
        #expect(P.mode(Self.signals(idle: 120)) == .fullCore)
        #expect(P.mode(Self.signals(idle: 119.9)) == .share(.inUse))
        #expect(P.mode(Self.signals(idle: .nan)) == .share(.inUse))
        #expect(P.mode(Self.signals(ac: false)) == .share(.battery))
        #expect(P.mode(Self.signals(lowPower: true)) == .share(.lowPower))
        #expect(P.mode(Self.signals(thermal: .serious)) == .share(.thermal))
        #expect(P.mode(Self.signals(thermal: .critical)) == .share(.thermal))
        // The machine's state is the reason before the user's.
        #expect(P.mode(Self.signals(ac: false, thermal: .serious, idle: 0)) == .share(.thermal))
        #expect(P.mode(Self.signals(ac: false, idle: 0)) == .share(.battery))
        #expect(P.describe(.fullCore, shareRate: 0.2) == "full core (plugged in, idle)")
        #expect(P.describe(.share(.battery), shareRate: 0.2) == "20% of a core (on battery)")
        #expect(P.describe(.share(.inUse), shareRate: 0.2) == "20% of a core (in use)")
    }

    final class Signals: @unchecked Sendable {
        let lock = NSLock()
        var value = RuntimeBudgetGovernorTests.signals()
        var lines: [String] = []
        func set(_ s: ArenaBudgetSignals) { lock.lock(); value = s; lock.unlock() }
        func get() -> ArenaBudgetSignals { lock.lock(); defer { lock.unlock() }; return value }
        func log(_ l: String) { lock.lock(); lines.append(l); lock.unlock() }
        var logged: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }

    /// The rate follows the mode, and each change is logged once.
    @Test func theGovernorSetsTheRateAndLogsEachChangeOnce() {
        let script = RuntimeBudgetTests.Script()
        let budget = ArenaCPUBudget(rate: 0.2, burst: 0, clock: script.clock)
        let s = Signals()
        s.set(Self.signals(idle: 10))
        let g = ArenaBudgetGovernor(budget: budget, shareRate: 0.2, fullRate: 1, read: { s.get() }, log: { s.log($0) })
        #expect(g.evaluate() == .share(.inUse))
        #expect(budget.rate == 0.2)
        #expect(g.evaluate() == .share(.inUse))
        s.set(Self.signals(idle: 300))
        #expect(g.evaluate() == .fullCore)
        #expect(budget.rate == 1)
        #expect(g.evaluate() == .fullCore)
        // The user is back.
        s.set(Self.signals(idle: 1))
        #expect(g.evaluate() == .share(.inUse))
        #expect(budget.rate == 0.2)
        // Another reason for the same share is not a change of rate.
        s.set(Self.signals(ac: false, idle: 1))
        #expect(g.evaluate() == .share(.battery))
        #expect(s.logged == ["budget: 20% of a core (in use)", "budget: full core (plugged in, idle)",
                             "budget: 20% of a core (in use)"])
    }

    /// The scorer's QoS follows the mode: utility (performance cores) at the
    /// full core, background at the everyday share.
    @Test func theScorersQoSFollowsTheMode() {
        #expect(ArenaBudgetPolicy.scorerQoS(.fullCore) == QOS_CLASS_UTILITY)
        for r in [ArenaBudgetPolicy.Reason.inUse, .battery, .lowPower, .thermal] {
            #expect(ArenaBudgetPolicy.scorerQoS(.share(r)) == QOS_CLASS_BACKGROUND)
        }
        let script = RuntimeBudgetTests.Script()
        let budget = ArenaCPUBudget(rate: 0.2, burst: 0, clock: script.clock)
        #expect(budget.scorerQoS == QOS_CLASS_BACKGROUND)
        let s = Signals()
        s.set(Self.signals(idle: 300))
        let g = ArenaBudgetGovernor(budget: budget, shareRate: 0.2, fullRate: 1, read: { s.get() }, log: { _ in })
        g.evaluate()
        #expect(budget.scorerQoS == QOS_CLASS_UTILITY)
        s.set(Self.signals(idle: 1))
        g.evaluate()
        #expect(budget.scorerQoS == QOS_CLASS_BACKGROUND)
    }

    /// On a background serial queue's thread, as the scorer's work runs: the
    /// QoS is raised for the job, and dispatch puts the next job back at the
    /// queue's.
    @Test func theQoSIsAppliedOnTheScorersKindOfThread() async {
        let queue = DispatchSerialQueue(label: "test.arena.qos", qos: .background)
        let seen: (before: qos_class_t, applied: Bool, after: qos_class_t) = await withCheckedContinuation { c in
            queue.async {
                let before = qos_class_self()
                let ok = ArenaQoS.apply(QOS_CLASS_UTILITY)
                c.resume(returning: (before, ok, qos_class_self()))
            }
        }
        #expect(seen.before == QOS_CLASS_BACKGROUND)
        #expect(seen.applied)
        #expect(seen.after == QOS_CLASS_UTILITY)
        let next: qos_class_t = await withCheckedContinuation { c in queue.async { c.resume(returning: qos_class_self()) } }
        #expect(next == QOS_CLASS_BACKGROUND)
        let back: qos_class_t = await withCheckedContinuation { c in
            queue.async { _ = ArenaQoS.apply(QOS_CLASS_UTILITY); ArenaQoS.apply(QOS_CLASS_BACKGROUND); c.resume(returning: qos_class_self()) }
        }
        #expect(back == QOS_CLASS_BACKGROUND)
    }

    /// Never more than one core, whatever is asked.
    @Test func neverMoreThanOneCore() {
        let script = RuntimeBudgetTests.Script()
        let budget = ArenaCPUBudget(rate: 4, burst: 0, clock: script.clock)
        #expect(budget.rate == 1)
        budget.rate = 8
        #expect(budget.rate == 1)
        let g = ArenaBudgetGovernor(budget: budget, shareRate: 0.2, fullRate: 3, read: { Self.signals() }, log: { _ in })
        g.evaluate()
        #expect(budget.rate == 1)
    }

    /// Up to a full core while idle, and the cut back to a fifth holds from
    /// the next checkpoint: the credit built up at the higher rate is not
    /// spent at the lower one.
    @Test func aCutTakesHoldAtTheNextCheckpoint() {
        let script = RuntimeBudgetTests.Script()
        let budget = ArenaCPUBudget(rate: 1, burst: 2, clock: script.clock)
        budget.mark()
        let start = script.wall
        for _ in 0..<100 { script.work(0.1); budget.checkpoint() }
        // 10 s of CPU at a full core: about 10 s of wall time, no pacing.
        #expect(script.wall - start < 10.5)
        script.wall += 30        // idle: credit up to the burst
        budget.rate = 0.2
        let cut = script.wall
        script.work(1)
        budget.checkpoint()
        // 1 s of CPU at a fifth of a core is 5 s, and no credit carried over.
        #expect(abs((script.wall - cut) - 5) < 0.3)
    }
}
