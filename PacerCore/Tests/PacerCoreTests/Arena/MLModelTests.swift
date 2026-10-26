import Foundation
import Testing
@testable import PacerCore

/// `ml-gbm-quantile` as the app runs it: registered with its `model.toml`,
/// the burn fallback against the Python (`ml-gbm-quantile-fallback.json`,
/// two early cuts of the parity history with too little to learn from:
/// 50 five-hour rows, two weekly cycles), training shared through the cut's
/// memo, `update`'s retrain rule, and cancellation.
@Suite struct MLModelTests {
    struct FallbackRef: Decodable {
        let seed: UInt64
        let probes: [Probe]
        struct Probe: Decodable {
            let kind: String; let account: String; let cap: String?; let now: Int64; let reset: Int64
            let grid: String; let n_rows: Int; let e2e: MLParityTests.Ref.E2E
        }
    }

    final class Log: @unchecked Sendable {
        var lines: [String] = []
        let lock = NSLock()
        func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
        var trained: Int { lock.lock(); defer { lock.unlock() }; return lines.filter { $0.contains(" in ") }.count }
    }

    static func model(_ h: ArenaHistory, seed: UInt64 = 42, log: Log? = nil, cancelled: @escaping @Sendable () -> Bool = { false })
        throws -> (MLGBMQuantileModel, ArenaRunner) {
        let spec = ArenaRegistry.spec("ml-gbm-quantile")!
        let runner = ArenaRunner(registry: [spec])
        let services = ArenaServices(log: { _, m in log?.add(m) }, isCancelled: cancelled)
        let ctx = ArenaContext(spec: spec, seed: seed, services: services, runner: runner, history: { h })
        return (try MLGBMQuantileModel(context: ctx), runner)
    }

    static func request(_ h: ArenaHistory, account: String, kind: String) -> ArenaRequest? {
        guard let tr = ArenaRunner.targetRequest(history: h, meter: ArenaMeterID(account: account, windowKind: kind))
        else { return nil }
        return ArenaRequest(now: h.now, accounts: h.accounts, targets: [tr])
    }

    @Test func registeredAsItsModelToml() throws {
        let spec = try #require(ArenaRegistry.spec("ml-gbm-quantile"))
        #expect(spec.targets == [.meterFiveHour, .meterSevenDay, .meterScoped])
        #expect(spec.children.isEmpty && spec.weights.isEmpty)
        let c = spec.config
        #expect(c.doubles("levels", []) == [0.03, 0.1, 0.25, 0.5, 0.75, 0.9, 0.97])
        #expect(c.doubles("default_scale", []) == [1.2, 1.2, 1.1, 1.0, 1.3, 1.7, 2.0])
        for (k, v) in [("max_rows", 3000), ("min_rows", 60), ("retrain_h", 24), ("n_estimators", 150), ("num_leaves", 15),
                       ("min_child_samples", 20), ("weekly_num_leaves", 7), ("weekly_min_child_samples", 10),
                       ("calibrate_folds", 3), ("prior_cycles", 10), ("min_cycles", 4)] {
            #expect(c.int(k, -1) == v, "\(k)")
        }
        #expect(c.double("learning_rate", 0) == 0.05)
    }

    @Test func burnFallbackMatchesThePython() throws {
        let (store, hist) = try MLParityTests.store()
        let ref = try JSONDecoder().decode(FallbackRef.self, from: Data(contentsOf: ArenaFixtures.url("ml-gbm-quantile-fallback")))
        var report: [String] = []
        for p in ref.probes {
            let h = MLParityTests.cut(store, hist, p.now)
            let (model, runner) = try Self.model(h, seed: ref.seed)
            _ = runner
            let grid = try MLParityTests.ints(p.grid, delta: true)
            let target = ArenaTarget.allCases.first { $0.windowKind == p.kind }!
            let tr = ArenaTargetRequest(key: target.key(account: p.account, cap: p.cap), target: target,
                                        accounts: [p.account], grid: grid, cap: p.cap, resetAt: p.reset)
            try model.fit(h)
            let fc = try model.forecast(ArenaRequest(now: p.now, accounts: hist.accounts, targets: [tr])).byKey[tr.key]!
            #expect(!p.e2e.trained)
            #expect(model.states[.init(kind: p.kind, cap: p.cap)].map { $0.1 == nil } == true, "fell back")
            let Q = try MLParityTests.doubles(p.e2e.quantiles)
            #expect(fc.levels == p.e2e.levels_out)
            var worst = 0.0
            if let qs = fc.quantiles {
                for i in qs.indices { for j in grid.indices { worst = max(worst, abs(qs[i][j] - Q[i * grid.count + j])) } }
            }
            // The levels' normal quantiles: scipy's ndtri there, KitDetQ.ndtri here.
            #expect(worst < 1e-9, "\(p.kind): worst |d| \(worst)")
            report.append(String(format: "%@:%@ fallback (%d rows): worst |d| %.1e points", p.kind, p.account, p.n_rows, worst))
        }
        print("ml-gbm-quantile burn fallback vs Python:\n" + report.joined(separator: "\n"))
    }

    /// The app asks every model at every cut; a second model on the same cut
    /// (another instance, the same seed and config) reuses the training.
    @Test func trainingIsSharedThroughTheCutsMemo() throws {
        let (store, hist) = try MLParityTests.store()
        let h = MLParityTests.cut(store, hist, hist.now)
        let req = try #require(Self.request(h, account: "A1", kind: "seven_day"))
        let log = Log()
        let (m1, r1) = try Self.model(h, log: log)
        try m1.fit(h)
        let a = try m1.forecast(req)
        let (m2, r2) = try Self.model(h, log: log)
        try m2.fit(h)
        let b = try m2.forecast(req)
        _ = (r1, r2)
        #expect(log.trained == 1, "\(log.lines)")
        let k = req.targets[0].key
        #expect(a.byKey[k]!.quantiles == b.byKey[k]!.quantiles)
        // A different seed trains its own.
        let (m3, r3) = try Self.model(h, seed: 7, log: log)
        _ = r3
        try m3.fit(h)
        _ = try m3.forecast(req)
        #expect(log.trained == 2)
    }

    /// `update`: the state trained at the cut keeps forecasting from fresh
    /// features until `retrain_h` (24 h) of new data has arrived.
    @Test func updateRetrainsAfterRetrainHours() throws {
        let (store, hist) = try MLParityTests.store()
        let t0 = hist.now - 2 * ArenaTime.day
        let log = Log()
        let h0 = MLParityTests.cut(store, hist, t0)
        let (m, r) = try Self.model(h0, log: log)
        _ = r
        try m.fit(h0)
        guard let q0 = Self.request(h0, account: "A1", kind: "seven_day") else { return }
        _ = try m.forecast(q0)
        #expect(log.trained == 1)
        let h1 = MLParityTests.cut(store, hist, t0 + 6 * ArenaTime.hour)
        try m.update(h1)
        if let q1 = Self.request(h1, account: "A1", kind: "seven_day") { _ = try m.forecast(q1) }
        #expect(log.trained == 1, "kept within retrain_h")
        let h2 = MLParityTests.cut(store, hist, t0 + 25 * ArenaTime.hour)
        try m.update(h2)
        if let q2 = Self.request(h2, account: "A1", kind: "seven_day") {
            _ = try m.forecast(q2)
            #expect(log.trained == 2, "retrained after retrain_h")
        }
    }

    @Test func cancellationStopsTraining() throws {
        let (store, hist) = try MLParityTests.store()
        let h = MLParityTests.cut(store, hist, hist.now)
        let req = try #require(Self.request(h, account: "A1", kind: "five_hour"))
        let (m, r) = try Self.model(h, cancelled: { true })
        _ = r
        try m.fit(h)
        #expect(throws: ArenaError.cancelled) { _ = try m.forecast(req) }
    }
}
