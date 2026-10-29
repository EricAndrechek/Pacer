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

    static func model(_ h: ArenaHistory, seed: UInt64 = 42, log: Log? = nil, spec: ArenaModelSpec = MLParityTests.exactSpec,
                      cancelled: @escaping @Sendable () -> Bool = { false }) throws -> (MLGBMQuantileModel, ArenaRunner) {
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
        // Swift-only: train once per retrain_h bucket, serially.
        // Five-hour buckets are retrain_h; weekly ones 72 h (see MLModels.swift).
        let align = c.table("train_align_h")
        #expect(align.double("five_hour", 0) == c.double("retrain_h", -1))
        #expect(align.double("seven_day", 0) == 72 && align.double("weekly_scoped", 0) == 72)
        #expect(c.int("train_cache_buckets", 0) == 8)
        let h = ArenaHistory(store: ArenaHistoryStore(meters: [:], spend: [:], tzOffsetMin: 0), now: 0, accounts: [])
        let (m, r) = try Self.model(h, spec: spec)
        _ = r
        #expect(!m.parallel)
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

/// The model at many cuts of the parity history, as the app's backfill asks
/// it (`ArenaRunner`, every meter the cut has a cycle for): every answer is
/// a quantile forecast on the grid, finite, non-decreasing across levels and
/// along the grid, within [the meter now, 100]. The light run covers the
/// first days (the fallback, then the first trainings); `PACER_ML_BENCH=1`
/// sweeps the whole history (release build) and reports the time per cut.
@Suite struct MLSweepTests {
    static func check(_ fc: ArenaTargetForecast, grid: Int, label: String) -> [String] {
        guard let lv = fc.levels, let q = fc.quantiles else { return ["\(label): no quantiles"] }
        var bad: [String] = []
        if q.count != lv.count || q.contains(where: { $0.count != grid }) { bad.append("\(label): shape") }
        for row in q where row.contains(where: { !$0.isFinite || $0 < -1e-9 || $0 > 100 + 1e-9 }) { bad.append("\(label): range"); break }
        for i in 1..<q.count where zip(q[i], q[i - 1]).contains(where: { $0 < $1 - 1e-9 }) { bad.append("\(label): crossing"); break }
        for row in q where zip(row.dropFirst(), row).contains(where: { $0 < $1 - 1e-9 }) { bad.append("\(label): falls"); break }
        return bad
    }

    func sweep(every: Millis, until: Millis?) throws -> (cuts: Int, answers: Int, seconds: Double, bad: [String]) {
        let (store, hist) = try MLParityTests.store()
        let spec = ArenaRegistry.spec("ml-gbm-quantile")!
        let runner = ArenaRunner(registry: [spec])
        let full = ArenaHistory(store: store, now: hist.now, accounts: hist.accounts, start: hist.start)
        var t = hist.start + 6 * ArenaTime.hour
        let end = until.map { min($0, hist.now) } ?? hist.now
        var cuts = 0, answers = 0, bad: [String] = []
        let t0 = Date()
        while t <= end {
            let cut = full.asOf(t)
            let req = ArenaRunner.request(history: cut, targets: spec.targets)
            if !req.targets.isEmpty {
                let fc = try runner.forecast(model: spec.name, history: cut, request: req)
                for tr in req.targets {
                    guard let f = fc.byKey[tr.key] else { bad.append("\(tr.key) at \(t): missing"); continue }
                    answers += 1
                    bad += Self.check(f, grid: tr.grid.count, label: "\(tr.key) at \(t)")
                    if let used = KitMLData.AsOfData.of(cut).meter(tr.account, tr.target.windowKind, tr.cap)?
                        .stateAt(t, reset: tr.resetAt)?.used,
                       let q = f.quantiles, q.contains(where: { $0.contains { $0 < used - 1e-9 } }) {
                        bad.append("\(tr.key) at \(t): below the meter now")
                    }
                }
                cuts += 1
            }
            t += every
        }
        return (cuts, answers, Date().timeIntervalSince(t0), bad)
    }

    @Test func earlyCutsAreWellFormed() throws {
        let (_, hist) = try MLParityTests.store()
        let r = try sweep(every: 5 * ArenaTime.hour + 7 * ArenaTime.minute, until: hist.start + 4 * ArenaTime.day)
        #expect(r.bad.isEmpty, "\(r.bad.prefix(5))")
        #expect(r.answers > 10)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PACER_ML_BENCH"] != nil))
    func wholeHistoryIsWellFormed() throws {
        let r = try sweep(every: 7 * ArenaTime.hour + 13 * ArenaTime.minute, until: nil)
        #expect(r.bad.isEmpty, "\(r.bad.prefix(5))")
        print(String(format: "ml-gbm-quantile sweep: %d cuts, %d answers, %.1f s (%.2f s per cut, training included)",
                     r.cuts, r.answers, r.seconds, r.seconds / Double(max(r.cuts, 1))))
    }
}
