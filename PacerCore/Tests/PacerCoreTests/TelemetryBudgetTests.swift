import Foundation
import Synchronization
import Testing
@testable import PacerCore

@Suite("Telemetry send caps", .serialized)
struct TelemetryBudgetTests {

    private final class Clock: @unchecked Sendable {
        private let t: Mutex<Date>
        init(_ d: Date) { t = Mutex(d) }
        var now: Date { t.withLock { $0 } }
        func advance(_ s: TimeInterval) { t.withLock { $0 = $0.addingTimeInterval(s) } }
    }

    private func make(_ limits: TelemetryBudget.Limits = .release, store: UserDefaults? = nil,
                      clock: Clock = Clock(Date(timeIntervalSince1970: Double(20_500 * 86_400 + 3_600))))
        throws -> (TelemetryBudget, UserDefaults, Clock) {
        let defaults = try store ?? #require(UserDefaults(suiteName: "budget-\(UUID().uuidString)"))
        return (TelemetryBudget(store: defaults, limits: limits, now: { clock.now }), defaults, clock)
    }

    @Test("a kind allows its limit, then refuses")
    func perKind() throws {
        var limits = TelemetryBudget.Limits.release
        limits.error = 3
        let (budget, _, _) = try make(limits)
        #expect((0..<3).allSatisfy { _ in budget.take(.error) })
        #expect(!budget.take(.error))
        // another kind is untouched
        #expect(budget.take(.hang))
    }

    @Test("rolls over at UTC midnight")
    func rollover() throws {
        var limits = TelemetryBudget.Limits.release
        limits.feedback = 1
        let (budget, _, clock) = try make(limits)
        #expect(budget.take(.feedback))
        #expect(!budget.take(.feedback))
        clock.advance(23 * 3_600 - 1)   // 23:59:59 UTC, same day
        #expect(!budget.take(.feedback))
        clock.advance(1)                // midnight UTC
        #expect(budget.take(.feedback))
    }

    @Test("counts persist across instances, so a relaunch cannot reset them")
    func persistence() throws {
        var limits = TelemetryBudget.Limits.release
        limits.crash = 2
        let (first, store, clock) = try make(limits)
        #expect(first.take(.crash))
        #expect(first.take(.crash))
        let (second, _, _) = try make(limits, store: store, clock: clock)
        #expect(!second.take(.crash))
        clock.advance(86_400)
        let (third, _, _) = try make(limits, store: store, clock: clock)
        #expect(third.take(.crash))
    }

    @Test("high-volume kinds persist on the throttle and on flush")
    func throttledPersistence() throws {
        var limits = TelemetryBudget.Limits.release
        limits.metric = 2
        let (first, store, clock) = try make(limits)
        #expect(first.take(.metric, name: "a"))   // first write is due
        #expect(first.take(.metric, name: "a"))   // within the interval: memory only
        let (stale, _, _) = try make(limits, store: store, clock: clock)
        #expect(stale.used(.metric, name: "a") == 1)
        first.flush()
        let (fresh, _, _) = try make(limits, store: store, clock: clock)
        #expect(fresh.used(.metric, name: "a") == 2)
        #expect(!fresh.take(.metric, name: "a"))
    }

    @Test("metrics are capped per name; the stall metric has its own cap")
    func perMetricName() throws {
        var limits = TelemetryBudget.Limits.release
        limits.metric = 2
        limits.stall = 1
        let (budget, _, _) = try make(limits)
        #expect(budget.takeMetric("scan.cycle_ms"))
        #expect(budget.takeMetric("scan.cycle_ms"))
        #expect(!budget.takeMetric("scan.cycle_ms"))
        #expect(budget.takeMetric("other.metric"))
        #expect(budget.takeMetric("main_thread.stall_ms"))
        #expect(!budget.takeMetric("main_thread.stall_ms"))
    }

    @Test("debug limits are tighter than release")
    func debugVsRelease() throws {
        let r = TelemetryBudget.Limits.release, d = TelemetryBudget.Limits.debug
        #expect(r.error == 25 && d.error == 10)
        #expect(r.hang == 10 && d.hang == 3)
        #expect(r.crash == 10 && d.crash == 5)
        #expect(r.transaction == 150 && d.transaction == 40)
        #expect(r.metric == 300 && d.metric == 60)
        #expect(r.stall == 100 && d.stall == 20)
        let (budget, _, _) = try make(.debug)
        #expect((0..<20).allSatisfy { _ in budget.takeMetric("main_thread.stall_ms") })
        #expect(!budget.takeMetric("main_thread.stall_ms"))
    }

    @Test("the check-in is never capped")
    func checkInExempt() throws {
        var limits = TelemetryBudget.Limits.release
        limits.transaction = 0
        limits.metric = 0
        let (budget, _, _) = try make(limits)
        #expect(!budget.takeTransaction(op: "history.rebuild"))
        #expect((0..<5).allSatisfy { _ in budget.takeTransaction(op: TelemetryBudget.checkInTransactionOp) })
        #expect(!budget.takeMetric("scan.cycle_ms"))
        #expect(budget.takeMetric("checkin.snapshot"))
    }

    @Test("a refusal is counted as telemetry.capped.<kind>")
    func droppedCounted() throws {
        _ = TelemetryCounters.drain()
        var limits = TelemetryBudget.Limits.release
        limits.hang = 1
        limits.metric = 1
        let (budget, _, _) = try make(limits)
        #expect(budget.take(.hang))
        #expect(!budget.take(.hang))
        #expect(!budget.take(.hang))
        #expect(budget.takeMetric("x.y"))
        #expect(!budget.takeMetric("x.y"))
        let counts = TelemetryCounters.drain()
        #expect(counts["telemetry.capped.hang"] == 2)
        #expect(counts["telemetry.capped.metric"] == 1)
        #expect(counts["telemetry.capped.metric.x.y"] == 1)
    }
}
