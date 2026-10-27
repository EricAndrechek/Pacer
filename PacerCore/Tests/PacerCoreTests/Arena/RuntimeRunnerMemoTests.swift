import Foundation
import Testing
@testable import PacerCore

/// The runner's memo (`ArenaRunner`): only what a model asks from inside
/// itself is kept; what the caller asks directly is answered but not stored;
/// past the values budget the least recently used entries go.
@Suite("Arena runtime: the runner's memo", .serialized)
struct RuntimeRunnerMemoTests {

    static let account = "acct-memo"
    static let hour = ArenaTime.hour
    static let t0: Millis = 1_790_000_000_000 / (5 * 3600_000) * (5 * 3600_000)

    /// Two days of five-hour readings every ten minutes, cycles back to back.
    static func store() -> ArenaHistoryStore {
        var rows: [ArenaReading] = []
        var t = t0
        while t <= t0 + 48 * hour {
            let reset = (t / (5 * hour) + 1) * (5 * hour)
            let used = Double((t - (reset - 5 * hour)) / (10 * ArenaTime.minute))
            rows.append(ArenaReading(tEvent: t, tKnown: t, utilPct: used, resetsAt: reset, active: true))
            t += 10 * ArenaTime.minute
        }
        return ArenaHistoryStore(meters: [ArenaMeterID(account: account, windowKind: "five_hour"): rows], spend: [:],
                                 tzOffsetMin: 0, dataStart: t0)
    }

    /// Counts fits by name.
    final class Counts: @unchecked Sendable {
        let lock = NSLock()
        var fits: [String: Int] = [:]
        func add(_ n: String) { lock.lock(); fits[n, default: 0] += 1; lock.unlock() }
        func of(_ n: String) -> Int { lock.lock(); defer { lock.unlock() }; return fits[n] ?? 0 }
    }
    nonisolated(unsafe) static var counts = Counts()

    /// A leaf whose forecast is `paths` rows of the grid (its size in the memo).
    final class Leaf: ArenaModel {
        let name: String, paths: Int
        init(context: ArenaContext) { name = context.name; paths = context.config.int("paths", 1) }
        func fit(_ history: ArenaHistory) { RuntimeRunnerMemoTests.counts.add(name) }
        func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
            var out: [String: ArenaTargetForecast] = [:]
            for tr in request.targets {
                out[tr.key] = ArenaTargetForecast(paths: Array(repeating: Array(repeating: 1, count: tr.grid.count),
                                                               count: paths))
            }
            return ArenaForecast(byKey: out)
        }
    }

    /// Backtests its child every two hours, then answers flat.
    final class Parent: ArenaModel {
        let ctx: ArenaContext
        init(context: ArenaContext) { ctx = context }
        func fit(_ history: ArenaHistory) {}
        func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
            _ = try ctx.backtest("memo-leaf", every: 2 * RuntimeRunnerMemoTests.hour, targets: [.meterFiveHour])
            var out: [String: ArenaTargetForecast] = [:]
            for tr in request.targets { out[tr.key] = .point(Array(repeating: 0, count: tr.grid.count)) }
            return ArenaForecast(byKey: out)
        }
    }

    static let five: Set<ArenaTarget> = [.meterFiveHour]
    static let registry = [
        ArenaModelSpec(name: "memo-leaf", targets: five, config: ["paths": 1]) { Leaf(context: $0) },
        ArenaModelSpec(name: "memo-wide", targets: five, config: ["paths": 200]) { Leaf(context: $0) },
        ArenaModelSpec(name: "memo-parent", targets: five, children: ["memo-leaf"]) { Parent(context: $0) },
    ]

    static func ask(_ runner: ArenaRunner, _ model: String, store: ArenaHistoryStore, at now: Millis) throws {
        let h = ArenaHistory(store: store, now: now, accounts: [account])
        let req = ArenaRunner.request(history: h, targets: five)
        #expect(!req.targets.isEmpty)
        _ = try runner.forecast(model: model, history: h, request: req)
    }

    @Test func whatTheCallerAsksDirectlyIsNotKept() throws {
        Self.counts = Counts()
        let store = Self.store(), runner = ArenaRunner(registry: Self.registry)
        let now = Self.t0 + 30 * Self.hour + 20 * ArenaTime.minute
        try Self.ask(runner, "memo-wide", store: store, at: now)
        try Self.ask(runner, "memo-wide", store: store, at: now)
        #expect(Self.counts.of("memo-wide") == 2)
        #expect(runner.memoCount == 0)
        #expect(runner.memoValueCount == 0)
    }

    /// A parent's child lattice survives a stream of large top-level answers
    /// in between: its next cut refits only the new origin.
    @Test func aNestedBacktestSurvivesAStreamOfTopLevelForecasts() throws {
        func run(legacy: Bool) throws -> (first: Int, second: Int) {
            ArenaRunner.legacyMemoForMeasurement = legacy
            defer { ArenaRunner.legacyMemoForMeasurement = false }
            Self.counts = Counts()
            let store = Self.store(), runner = ArenaRunner(registry: Self.registry)
            // Room for the lattice and a few wide answers, not for all of them.
            runner.memoLimitValues = 60_000
            let first = Self.t0 + 30 * Self.hour + 20 * ArenaTime.minute
            try Self.ask(runner, "memo-parent", store: store, at: first)
            let fitsFirst = Self.counts.of("memo-leaf")
            for k in 0..<20 {
                try Self.ask(runner, "memo-wide", store: store, at: first + Millis(k + 1) * 5 * ArenaTime.minute)
            }
            try Self.ask(runner, "memo-parent", store: store, at: first + 2 * Self.hour)
            return (fitsFirst, Self.counts.of("memo-leaf") - fitsFirst)
        }
        let now = try run(legacy: false)
        #expect(now.first >= 10)
        #expect(now.second == 1)
        // The memo as it was: the wide answers filled it and it was cleared,
        // so the whole lattice was fitted again.
        let before = try run(legacy: true)
        #expect(before.second == before.first + 1)
    }

    /// Past the budget the least recently used entries go, and what stays is
    /// still answered, to direct asks too.
    @Test func theLeastRecentlyUsedGoFirst() throws {
        Self.counts = Counts()
        let store = Self.store(), runner = ArenaRunner(registry: Self.registry)
        // A child forecast here is ~30 grid points: room for about 8.
        runner.memoLimitValues = 250
        let now = Self.t0 + 30 * Self.hour + 20 * ArenaTime.minute
        try Self.ask(runner, "memo-parent", store: store, at: now)
        let fitted = Self.counts.of("memo-leaf")
        #expect(fitted >= 10)
        #expect(runner.memoValueCount <= 250)
        #expect(runner.memoCount >= 1 && runner.memoCount < fitted)
        // The newest origin is still there (a hit: no fit), the oldest is not.
        let origins = stride(from: Self.t0, to: now, by: Int(2 * Self.hour)).suffix(runner.maxBacktestPoints)
        let newest = origins.last!, oldest = origins.first!
        try Self.ask(runner, "memo-leaf", store: store, at: newest)
        #expect(Self.counts.of("memo-leaf") == fitted)
        try Self.ask(runner, "memo-leaf", store: store, at: oldest)
        #expect(Self.counts.of("memo-leaf") == fitted + 1)
    }
}
