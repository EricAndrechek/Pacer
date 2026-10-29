import Foundation
import Testing
@testable import PacerCore

/// `ml-gbm-quantile` as registered: trained once per `train_align_h` (24 h)
/// bucket, at the bucket's start, and reused by every cut in it through the
/// store's memo. Checked on the parity history: one training per bucket
/// whatever cut and seed ask; the training never sees a row after its
/// bucket's start (a store that differs only after it trains the same
/// model); the cache holds at most `train_cache_buckets` buckets per meter.
/// `PACER_ML_BENCH=1` (release) adds the backfill's cost: 180 five-hour and
/// 18 weekly cycles × 8 cuts on a synthetic 120-day history, serial.
@Suite struct MLAlignTests {
    typealias Log = MLModelTests.Log

    /// The registered spec with test speed-ups that keep the alignment.
    static func spec(_ edit: (inout ArenaConfig) -> Void = { _ in }) -> ArenaModelSpec {
        var s = ArenaRegistry.spec("ml-gbm-quantile")!
        s.config.values["parallel"] = true
        // The mechanism under test, on day buckets whatever the registered
        // weekly bucket is (`registeredAsItsModelToml` pins that).
        s.config.values["train_align_h"] = 24
        edit(&s.config)
        return s
    }

    /// Fit and forecast A1's weekly meter at `t` (seeded per cut, as the
    /// runner seeds), the model kept for its state.
    static func run(_ store: ArenaHistoryStore, _ hist: MLParityTests.History, at t: Millis, spec: ArenaModelSpec,
                    log: Log) throws -> (MLGBMQuantileModel, ArenaTargetForecast?) {
        let h = MLParityTests.cut(store, hist, t)
        let runner = ArenaRunner(registry: [spec])
        let services = ArenaServices(log: { _, m in log.add(m) })
        let ctx = ArenaContext(spec: spec, seed: ArenaRunner.deriveSeed(42, spec.name, t), services: services,
                               runner: runner, history: { h })
        let m = try MLGBMQuantileModel(context: ctx)
        try m.fit(h)
        guard let req = MLModelTests.request(h, account: "A1", kind: "seven_day") else { return (m, nil) }
        let fc = try m.forecast(req).byKey[req.targets[0].key]
        withExtendedLifetime(runner) {}
        return (m, fc)
    }

    static func bucket(_ t: Millis, hours: Int = 24) -> Millis {
        KitMLData.floorDiv(t, Millis(hours) * ArenaTime.hour) * Millis(hours) * ArenaTime.hour
    }

    static func state(_ m: MLGBMQuantileModel, bucket b: Millis) -> MLGBMQuantileModel.State? {
        m.states[.init(kind: "seven_day", cap: nil, bucket: b)]?.1 as? MLGBMQuantileModel.State
    }

    static func same(_ a: MLGBMQuantileModel.State?, _ b: MLGBMQuantileModel.State?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.scale == b.scale && a.boosters.count == b.boosters.count
            && zip(a.boosters, b.boosters).allSatisfy { x, y in
                x.trees.count == y.trees.count && zip(x.trees, y.trees).allSatisfy {
                    $0.leafValue == $1.leafValue && $0.threshold == $1.threshold && $0.feature == $1.feature
                }
            }
    }

    @Test func oneTrainingPerBucket() throws {
        let (store, hist) = try MLParityTests.store()
        let spec = Self.spec()
        let log = Log()
        let b = Self.bucket(hist.now) - ArenaTime.day
        let (m1, f1) = try Self.run(store, hist, at: b + 2 * ArenaTime.hour, spec: spec, log: log)
        let (m2, f2) = try Self.run(store, hist, at: b + 17 * ArenaTime.hour + 5 * ArenaTime.minute, spec: spec, log: log)
        #expect(f1 != nil && f2 != nil)
        #expect(log.trained == 1, "\(log.lines)")
        #expect(log.lines.contains { $0.contains("data to \(b))") }, "trained on the history at the bucket's start")
        #expect(Self.same(Self.state(m1, bucket: b), Self.state(m2, bucket: b)))
        _ = try Self.run(store, hist, at: b + ArenaTime.day + ArenaTime.hour, spec: spec, log: log)
        #expect(log.trained == 2, "the next bucket trains its own")
    }

    /// The bucket's model is a function of what was known at its start: a
    /// store whose rows after it differ (higher readings, ten times the
    /// spend, an extra reading) trains the same boosters, at a later cut.
    @Test func trainingNeverSeesRowsAfterItsBucketStart() throws {
        let (store, hist) = try MLParityTests.store()
        let b = Self.bucket(hist.now) - 2 * ArenaTime.day
        var meters = store.meters
        for (id, rs) in meters {
            meters[id] = rs.map { r in
                guard r.tKnown > b else { return r }
                var x = r; x.utilPct = r.utilPct.map { min($0 + 7, 100) }; return x
            }
            if let last = rs.last(where: { $0.tKnown > b }) {
                meters[id]!.append(ArenaReading(tEvent: last.tEvent + 1, tKnown: last.tKnown + 1, utilPct: 99,
                                                resetsAt: last.resetsAt, active: last.active))
            }
        }
        let spend = store.spend.mapValues { rows in
            rows.map { r in r.tKnown > b ? ArenaSpendRow(tEvent: r.tEvent, tKnown: r.tKnown, family: r.family,
                                                          costUSD: r.costUSD.map { $0 * 10 }) : r }
        }
        let poisoned = ArenaHistoryStore(meters: meters, spend: spend, tzOffsetMin: store.tzOffsetMin,
                                         dataStart: store.dataStart)
        let spec = Self.spec()
        let t = b + 20 * ArenaTime.hour
        let (m1, f1) = try Self.run(store, hist, at: t, spec: spec, log: Log())
        let (m2, f2) = try Self.run(poisoned, hist, at: t, spec: spec, log: Log())
        #expect(Self.state(m1, bucket: b) != nil)
        #expect(Self.same(Self.state(m1, bucket: b), Self.state(m2, bucket: b)), "the bucket's training saw rows after it")
        // The forecast itself reads the cut's own (different) rows.
        #expect(f1?.quantiles != f2?.quantiles)
        // And a cut at the bucket's start trains exactly what a later cut uses.
        let (m3, f3) = try Self.run(store, hist, at: b, spec: spec, log: Log())
        if f3 != nil { #expect(Self.same(Self.state(m1, bucket: b), Self.state(m3, bucket: b))) }
    }

    @Test func cacheKeepsTheMostRecentBuckets() throws {
        let (store, hist) = try MLParityTests.store()
        let spec = Self.spec { $0.values["train_cache_buckets"] = 2; $0.values["n_estimators"] = 3 }
        let log = Log()
        let b0 = Self.bucket(hist.now) - 4 * ArenaTime.day
        for d in 0..<4 { _ = try Self.run(store, hist, at: b0 + Millis(d) * ArenaTime.day + ArenaTime.hour, spec: spec, log: log) }
        #expect(log.trained == 4)
        let cache = KitMLStateCache.of(store, capacity: 2)
        let meter = try #require(cache.meters.first { $0.hasSuffix("|seven_day|") })
        #expect(cache.buckets(meter) == [b0 + 2 * ArenaTime.day, b0 + 3 * ArenaTime.day])
        _ = try Self.run(store, hist, at: b0 + 3 * ArenaTime.day + 5 * ArenaTime.hour, spec: spec, log: log)
        #expect(log.trained == 4, "held")
        _ = try Self.run(store, hist, at: b0 + ArenaTime.hour, spec: spec, log: log)
        #expect(log.trained == 5, "evicted, so trained again")
        #expect(cache.buckets(meter).count == 2)
    }

    /// CPU seconds of this process (all threads).
    static func cpuSeconds() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }

    /// The backfill's shape: the last `cycles` completed cycles of a meter,
    /// each cut at 8 points, every cut asked through the runner as the app
    /// asks, the registered model (aligned, serial).
    static func backfill(_ store: ArenaHistoryStore, account: String, kind: String, target: ArenaTarget, cycles: Int,
                         align: ArenaValue? = nil) throws -> (cuts: Int, trainings: Int, cpu: Double, wall: Double) {
        var spec = ArenaRegistry.spec("ml-gbm-quantile")!
        if let align { spec.config.values["train_align_h"] = align }
        let log = Log()
        let services = ArenaServices(log: { _, m in log.add(m) })
        let end = store.meters.values.compactMap { $0.last?.tKnown }.max()!
        let full = ArenaHistory(store: store, now: end, accounts: [account])
        // Completed cycles: distinct resets (half-window rule) before the end.
        let rs = full.readings(account: account, windowKind: kind).compactMap { $0.active ? $0.resetsAt : nil }
        var resets: [Millis] = []
        for r in rs.sorted() where r < end && (resets.last.map { r - $0 >= target.windowMillis / 2 } ?? true) { resets.append(r) }
        let picked = resets.suffix(cycles)
        var cuts = 0
        let c0 = cpuSeconds(), w0 = Date()
        for r in picked {
            for i in 1...8 {
                let t = r - target.windowMillis + Millis(i) * target.windowMillis / 9
                let cut = full.asOf(t)
                let req = ArenaRunner.request(history: cut, targets: [target])
                guard !req.targets.isEmpty else { continue }
                let runner = ArenaRunner(registry: [spec], services: services)
                _ = try runner.forecast(model: spec.name, history: cut, request: req)
                cuts += 1
            }
        }
        return (cuts, log.trained, cpuSeconds() - c0, Date().timeIntervalSince(w0))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PACER_ML_BENCH"] != nil))
    func backfillCost() throws {
        let store = MLTimingTests.synthetic(days: 120, accounts: ["S1"], seed: 11)
        var lines: [String] = []
        for (kind, target, n) in [("five_hour", ArenaTarget.meterFiveHour, 180), ("seven_day", .meterSevenDay, 18)] {
            let r = try Self.backfill(store, account: "S1", kind: kind, target: target, cycles: n)
            lines.append(String(format: "  %@: %d cuts (of the last %d cycles × 8), %d trainings, %.1f CPU s, %.1f s wall (%.0f ms per cut)",
                                kind, r.cuts, n, r.trainings, r.cpu, r.wall, 1000 * r.wall / Double(max(r.cuts, 1))))
        }
        // The option of a week-long bucket for the weekly meters.
        let wk = try Self.backfill(MLTimingTests.synthetic(days: 120, accounts: ["S1"], seed: 11), account: "S1",
                                   kind: "seven_day", target: .meterSevenDay, cycles: 18,
                                   align: ["five_hour": 24, "seven_day": 168, "weekly_scoped": 168])
        lines.append(String(format: "  seven_day with 168 h buckets: %d cuts, %d trainings, %.1f CPU s", wk.cuts, wk.trainings, wk.cpu))
        print("ml-gbm-quantile backfill, synthetic 120 days, registered model (24 h buckets, serial):\n"
              + lines.joined(separator: "\n"))
    }
}
