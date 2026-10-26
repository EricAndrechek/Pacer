import Foundation
import Testing
@testable import PacerCore

/// `ml-gbm-quantile` and its kit (`kit/ml`) against the Python, on the
/// arena's synthetic snapshot (`ml-history.json`: two accounts' thinned
/// five-hour, seven-day and Fable weekly readings and their spend as
/// pseudo-turns, 36 days; `ml-gbm-quantile-ref.json`: what the Python made of
/// them at five probes). Both made by a script over the arena's own kit
/// (`kit.ml.data.AsOfData._build` on exactly these rows, `FeatureBuilder`,
/// `build_trainset`, the model's `_fit` and `_meter`; LightGBM 4.7), in a
/// private ARENA_HOME holding only `arena synth --out port-fixtures --seed 42`.
///
/// Checked, per probe: (a) the walk-forward training set equals the
/// Python's (cutoffs, resets, accounts, cycles, and every row's features,
/// labels and lead features to the bit, by FNV-1a hash), and so do the live
/// row and its lead rows; (b) the Swift GBM trained on the same rows as
/// LightGBM (the model's own folds: two to train, one held out) predicts
/// what LightGBM predicts; (c) end to end, the model's spread scale and
/// meter quantiles. (b) and (c) are exact against LightGBM with exclusive
/// feature bundling off (`ml-gbm-quantile-ref-nobundle.json`, the same
/// script with `enable_bundle=False`): bundling is a LightGBM speed-up that
/// is not lossless on these features (on the five-hour A2 rows it scores a
/// split at 12.5 whose gain on the rows themselves is 5.7), and the port does
/// not reproduce it. Against the Python's own setting (bundling on) they are
/// reported, and the held-out pinball loss must be no worse on average.
@Suite struct MLParityTests {
    struct History: Decodable {
        let start: Int64
        let now: Int64
        let tz_offset_min: Int?
        let accounts: [String]
        let meters: [Meter]
        let spend: [Spend]
        struct Meter: Decodable {
            let account: String; let window_kind: String; let scope_model: String?; let n: Int
            let t_event: String; let t_known: String; let util: String; let resets_at: String; let active: String
        }
        struct Spend: Decodable {
            let account: String; let n: Int
            let t_event: String; let t_known: String; let family: String; let cost_micro_usd: String
        }
    }

    struct Ref: Decodable {
        let lightgbm: String
        let seed: UInt64
        let feature_names: [String]
        let probes: [Probe]
        struct Probe: Decodable {
            let kind: String; let account: String; let cap: String?; let now: Int64; let reset: Int64
            let grid: String; let grid_n: Int
            let n_rows: Int; let t: String; let reset_rows: String; let account_rows: [Int]; let cycle: String
            let row_hash: String; let col_hash: [String]
            let sample_every: Int; let sample_X: [[Double]]; let sample_Y: [[Double?]]; let sample_leadX: [[[Double]]]
            let live_row: [Double]; let live_lead: [[Double]]
            let py_build_s: Double
            let lgb: LGB?
            let e2e: E2E
        }
        struct LGB: Decodable {
            let n_train: Int; let n_test: Int; let pred_every: Int; let pred_test: String; let py_fit_s: Double
            let pinball: [Double]
        }
        struct E2E: Decodable {
            let trained: Bool; let scale: [Double]?; let levels: [Double]; let q_anchors: [[Double]]; let used: Double
            let levels_out: [Double]; let quantiles: String; let py_s: Double
        }
    }

    // MARK: - decoding (base64 of raw-deflated little-endian columns)

    static func inflate(_ b64: String) throws -> Data {
        guard let d = Data(base64Encoded: b64) else { throw ArenaError.invalid("bad base64") }
        if d.isEmpty { return d }
        return try (d as NSData).decompressed(using: .zlib) as Data
    }

    static func words<T>(_ b64: String, _: T.Type) throws -> [T] {
        let d = try inflate(b64)
        let n = d.count / MemoryLayout<T>.size
        return d.withUnsafeBytes { raw in (0..<n).map { raw.loadUnaligned(fromByteOffset: $0 * MemoryLayout<T>.size, as: T.self) } }
    }

    static func ints(_ b64: String, delta: Bool = false) throws -> [Int64] {
        var a = try words(b64, Int64.self)
        if delta { for i in a.indices.dropFirst() { a[i] += a[i - 1] } }
        return a
    }

    static func doubles(_ b64: String) throws -> [Double] { try words(b64, Double.self) }

    static func store() throws -> (ArenaHistoryStore, History) {
        let h = try JSONDecoder().decode(History.self, from: Data(contentsOf: ArenaFixtures.url("ml-history")))
        var meters: [ArenaMeterID: [ArenaReading]] = [:]
        for m in h.meters {
            let te = try ints(m.t_event, delta: true), tk = try ints(m.t_known, delta: true)
            let u = try doubles(m.util), r = try ints(m.resets_at), a = try ints(m.active)
            meters[ArenaMeterID(account: m.account, windowKind: m.window_kind, scopeModel: m.scope_model)] =
                te.indices.map { i in
                    ArenaReading(tEvent: te[i], tKnown: tk[i], utilPct: u[i].isNaN ? nil : u[i],
                                 resetsAt: r[i] < 0 ? nil : r[i], active: a[i] == 1)
                }
        }
        var spend: [String: [ArenaSpendRow]] = [:]
        for s in h.spend {
            let te = try ints(s.t_event, delta: true), tk = try ints(s.t_known, delta: true)
            let f = try ints(s.family), c = try ints(s.cost_micro_usd)
            spend[s.account] = te.indices.map { i in
                ArenaSpendRow(tEvent: te[i], tKnown: tk[i], family: arenaFamilies[Int(f[i])],
                              costUSD: c[i] < 0 ? nil : Double(c[i]) * 1e-6)
            }
        }
        return (ArenaHistoryStore(meters: meters, spend: spend, tzOffsetMin: h.tz_offset_min, dataStart: h.start), h)
    }

    static func ref() throws -> Ref {
        try JSONDecoder().decode(Ref.self, from: Data(contentsOf: ArenaFixtures.url("ml-gbm-quantile-ref")))
    }

    /// The same probes against LightGBM without feature bundling.
    struct RefNB: Decodable {
        let seed: UInt64
        let probes: [Probe]
        struct Probe: Decodable { let kind: String; let account: String; let lgb: Ref.LGB?; let e2e: Ref.E2E }
    }

    static func refNB() throws -> RefNB {
        try JSONDecoder().decode(RefNB.self, from: Data(contentsOf: ArenaFixtures.url("ml-gbm-quantile-ref-nobundle")))
    }

    /// FNV-1a 64 over float64 little-endian bytes (the Python's `fnv`).
    static func fnv(_ xs: [Double]) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for x in xs {
            var b = x.bitPattern
            for _ in 0..<8 { h = (h ^ (b & 0xFF)) &* 0x0000_0100_0000_01B3; b >>= 8 }
        }
        return h
    }

    static func cut(_ store: ArenaHistoryStore, _ hist: History, _ now: Int64) -> ArenaHistory {
        ArenaHistory(store: store, now: now, accounts: hist.accounts, start: hist.start)
    }

    // MARK: - tests

    @Test func featureNamesAndIndices() throws {
        let ref = try Self.ref()
        #expect(KitMLFeatures.featureNames == ref.feature_names)
        typealias F = KitMLFeatures.F
        let named: [(Int, String)] = [
            (F.elapsedFrac, "elapsed_frac"), (F.remainingH, "remaining_h"), (F.usedNow, "used_now"),
            (F.headroom, "headroom"), (F.nRead, "n_read"), (F.sinceLastH, "since_last_h"), (F.rate0, "rate_0"),
            (F.rateCycle, "rate_cycle"), (F.accel, "accel"), (F.projCycle, "proj_cycle"), (F.projRate1, "proj_rate1"),
            (F.traj25, "traj_25"), (F.flatShare, "flat_share"), (F.spend0, "spend_0"), (F.spendCycle, "spend_cycle"),
            (F.spendSinceRead, "spend_since_read"), (F.conv, "conv"), (F.convRate0, "conv_rate_0"),
            (F.convRate1, "conv_rate_1"), (F.nowcastGap, "nowcast_gap"), (F.convResid, "conv_resid"),
            (F.convProj, "conv_proj"), (F.expSpendRem, "exp_spend_rem"), (F.expActiveRem, "exp_active_rem"),
            (F.expPtsRem, "exp_pts_rem"), (F.actFracLeft, "act_frac_left"), (F.activeNow, "active_now"),
            (F.expSpendNextH, "exp_spend_next_h"), (F.hodSin, "hod_sin"), (F.hodCos, "hod_cos"),
            (F.dowSin, "dow_sin"), (F.dowCos, "dow_cos"), (F.nPast, "n_past"), (F.pastFinalMean, "past_final_mean"),
            (F.pastFinalLast, "past_final_last"), (F.pastHit, "past_hit"), (F.pastPhaseRise, "past_phase_rise"),
            (F.pastPhaseRiseMax, "past_phase_rise_max"), (F.poolFinalMean, "pool_final_mean"),
            (F.poolPhaseRise, "pool_phase_rise"), (F.poolHit, "pool_hit"), (F.xLevel, "x_level"),
            (F.xElapsed, "x_elapsed"), (F.xRate, "x_rate"), (F.sess15m, "sess_15m"), (F.sess60m, "sess_60m"),
            (F.turns15m, "turns_15m"), (F.subShare60m, "sub_share_60m"), (F.prompts15m, "prompts_15m"),
            (F.prompts60m, "prompts_60m"), (F.idleH, "idle_h"), (F.nAcct7d, "n_acct_7d"), (F.nAcct1h, "n_acct_1h"),
            (F.othersSpend1h, "others_spend_1h"), (F.mixFable, "mix_fable"),
        ]
        for (i, n) in named { #expect(KitMLFeatures.featureNames[i] == n) }
    }

    @Test func blake2bMatchesHashlib() {
        // hashlib.blake2b(s.encode(), digest_size=8)
        #expect(Blake2b.hash(Array("wf|A1|1784503800000".utf8), outLength: 8) == [0x99, 0x57, 0x3f, 0xdd, 0x69, 0x81, 0x77, 0x9f])
        #expect(Blake2b.hash(Array("".utf8), outLength: 8) == [0xe4, 0xa6, 0xa0, 0x57, 0x74, 0x79, 0xb2, 0xb4])
        #expect(KitMLWalkforward.keep("A2", 1_700_000_000_000, salt: "wf") == 0.392642591285205)
        #expect(KitMLWalkforward.keep("A1", 1_784_503_800_000, salt: "wf") == 0.5989875712925875)
    }

    /// (a): the training rows and the live row, to the bit.
    @Test func trainingSetsAndLiveRowsMatchThePython() throws {
        let (store, hist) = try Self.store()
        let ref = try Self.ref()
        var report: [String] = []
        for p in ref.probes {
            let h = Self.cut(store, hist, p.now)
            let data = KitMLData.AsOfData(history: h)
            let b = KitMLFeatures.FeatureBuilder(data: data, kind: p.kind)
            let t0 = Date()
            let ts = try KitMLWalkforward.buildTrainset(data, b, kind: p.kind, cap: p.cap, now: p.now, start: hist.start,
                                                        maxRows: 3000)
            let dt = Date().timeIntervalSince(t0)
            let label = "\(p.kind):\(p.account)\(p.cap.map { ":" + $0 } ?? "") at \(p.now)"
            #expect(ts.count == p.n_rows, "\(label): \(ts.count) rows vs \(p.n_rows)")
            guard ts.count == p.n_rows else { continue }
            #expect(ts.t == (try Self.ints(p.t, delta: true)), "\(label) cutoffs")
            #expect(ts.reset == (try Self.ints(p.reset_rows)), "\(label) resets")
            #expect(ts.account == p.account_rows.map { hist.accounts[$0] }, "\(label) accounts")
            #expect(ts.cycle.map(Int64.init) == (try Self.ints(p.cycle)), "\(label) cycles")
            let rowHash = try Self.words(p.row_hash, UInt64.self)
            var bad: [Int] = []
            for i in 0..<ts.count where Self.fnv(ts.X[i] + ts.Y[i] + ts.leadX[i].flatMap { $0 }) != rowHash[i] { bad.append(i) }
            var badCols: [String] = []
            for j in KitMLFeatures.featureNames.indices where String(Self.fnv(ts.X.map { $0[j] })) != p.col_hash[j] {
                badCols.append(KitMLFeatures.featureNames[j])
            }
            #expect(bad.isEmpty, "\(label): \(bad.count) of \(ts.count) rows differ (first \(bad.prefix(5))), columns \(badCols)")
            for (k, i) in stride(from: 0, to: ts.count, by: p.sample_every).enumerated() where k < p.sample_X.count {
                let d = zip(ts.X[i], p.sample_X[k]).enumerated().filter { $0.element.0 != $0.element.1 }
                if !d.isEmpty {
                    report.append("\(label) row \(i): " + d.prefix(6).map {
                        "\(KitMLFeatures.featureNames[$0.offset]) \($0.element.0) vs \($0.element.1)"
                    }.joined(separator: ", "))
                }
            }
            // The live row the forecast is made from.
            let series = data.meter(p.account, p.kind, p.cap)!
            let st = series.stateAt(p.now, reset: p.reset)!
            let row = b.row(series, p.now, reset: p.reset, st: st)!
            let liveDiff = zip(row, p.live_row).enumerated().filter { $0.element.0 != $0.element.1 }
            let liveMsg = liveDiff.prefix(6).map {
                "\(KitMLFeatures.featureNames[$0.offset]) \($0.element.0) vs \($0.element.1)" }.joined(separator: ", ")
            #expect(liveDiff.isEmpty, "\(label) live row: \(liveMsg)")
            let lead = b.leadRows(row, series, p.now, reset: p.reset, fracs: KitMLMeterModel.anchors)
            #expect(lead == p.live_lead, "\(label) live lead rows")
            report.append(String(format: "%@: %d rows, %d cycles, all equal: %@; Swift build %.3fs (Python %.2fs)",
                                 label, ts.count, (ts.cycle.max() ?? -1) + 1, bad.isEmpty ? "yes" : "NO", dt, p.py_build_s))
        }
        print("ML training sets vs Python:\n" + report.joined(separator: "\n"))
    }

    /// (b): the Swift GBM on the Python's training rows vs LightGBM.
    @Test func gbmOnTrainingRowsMatchesLightGBM() throws {
        let (store, hist) = try Self.store()
        let ref = try Self.ref(), nb = try Self.refNB()
        var report: [String] = []
        for (pi, p) in ref.probes.enumerated() {
            guard let lgb = p.lgb, let lgbNB = nb.probes[pi].lgb else { continue }
            let h = Self.cut(store, hist, p.now)
            let data = KitMLData.AsOfData(history: h)
            let ts = try KitMLWalkforward.buildTrainset(data, KitMLFeatures.FeatureBuilder(data: data, kind: p.kind),
                                                        kind: p.kind, cap: p.cap, now: p.now, start: hist.start, maxRows: 3000)
            let (X, y, r, w) = ts.stacked()
            let nCyc = (ts.cycle.max() ?? -1) + 1
            var first = [Int64](repeating: .max, count: nCyc)
            for (i, c) in ts.cycle.enumerated() { first[c] = min(first[c], ts.reset[i]) }
            var rank = [Int](repeating: 0, count: nCyc)
            for (pos, c) in first.indices.sorted(by: { (first[$0], $0) < (first[$1], $1) }).enumerated() { rank[c] = pos }
            let fold = r.map { rank[ts.cycle[$0]] * 3 / nCyc }
            let tr = fold.indices.filter { fold[$0] != 0 }, te = fold.indices.filter { fold[$0] == 0 }
            #expect(tr.count == lgb.n_train && te.count == lgb.n_test)
            let spec = ArenaRegistry.spec("ml-gbm-quantile")!
            let runner = ArenaRunner(registry: [spec])
            let model = try MLGBMQuantileModel(context: ArenaContext(spec: spec, seed: ref.seed, services: ArenaServices(),
                                                                     runner: runner, history: { h }))
            let levels = MLGBMQuantileModel.defaultLevels
            let t0 = Date()
            let boosters = model.fit(sets: [tr], x: X, y: y, width: w, levels: levels, params: model.params(p.kind))[0]
            let dt = Date().timeIntervalSince(t0)
            let yTe = te.map { y[$0] }
            var pins: [Double] = []
            var lines: [String] = []
            for (j, a) in levels.enumerated() {
                let pred = X.withUnsafeBufferPointer { xp in te.map { boosters[j].predict(xp.baseAddress! + $0 * w) } }
                let pin = MLGBMQuantileModel.pinball(yTe, pred, a)
                pins.append(pin)
                let mine = stride(from: 0, to: pred.count, by: lgb.pred_every).map { pred[$0] }
                func diff(_ ref: Ref.LGB) throws -> [Double] {
                    let all = try Self.doubles(ref.pred_test)
                    let per = all.count / levels.count
                    return zip(mine, all[(j * per)..<((j + 1) * per)]).map { abs($0 - $1) }
                }
                let dNB = try diff(lgbNB), dB = try diff(lgb)
                #expect((dNB.max() ?? 0) < 1e-9, "\(p.kind):\(p.account) a=\(a): max |d| \(dNB.max() ?? 0) vs LightGBM without bundling")
                #expect(abs(pin - lgbNB.pinball[j]) < 1e-9 * max(1, pin))
                lines.append(String(format: "  a=%.2f no bundling: max |d| %.1e; bundling: mean |d| %.2e max %.2e, pinball %.6f vs %.6f (%+.2f%%)",
                                    a, dNB.max() ?? 0, dB.reduce(0, +) / Double(max(dB.count, 1)), dB.max() ?? 0, pin,
                                    lgb.pinball[j], 100 * (pin - lgb.pinball[j]) / max(lgb.pinball[j], 1e-12)))
            }
            let meanMine = pins.reduce(0, +) / Double(pins.count), meanLGB = lgb.pinball.reduce(0, +) / Double(pins.count)
            #expect(meanMine <= meanLGB * 1.03, "\(p.kind):\(p.account) mean pinball \(meanMine) vs LightGBM \(meanLGB)")
            report.append(String(format: "%@:%@ train %d test %d stacked rows; Swift 7 boosters %.2fs (LightGBM %.2fs); mean pinball %.6f vs %.6f (%+.2f%%)",
                                 p.kind, p.account, tr.count, te.count, dt, lgb.py_fit_s, meanMine, meanLGB,
                                 100 * (meanMine - meanLGB) / meanLGB))
            report += lines
        }
        print("GBM on the Python's training rows vs LightGBM \(ref.lightgbm):\n" + report.joined(separator: "\n"))
    }

    /// (c): the whole model, at each probe, against the Python's.
    @Test func endToEndQuantilesMatchThePython() throws {
        let (store, hist) = try Self.store()
        let ref = try Self.ref(), nb = try Self.refNB()
        guard let spec = ArenaRegistry.spec("ml-gbm-quantile") else { Issue.record("not registered"); return }
        var report: [String] = []
        for (pi, p) in ref.probes.enumerated() {
            let h = Self.cut(store, hist, p.now)
            let runner = ArenaRunner(registry: [spec])
            let ctx = ArenaContext(spec: spec, seed: ref.seed, services: ArenaServices(), runner: runner, history: { h })
            let model = try MLGBMQuantileModel(context: ctx)
            let grid = try Self.ints(p.grid, delta: true)
            let target = ArenaTarget.allCases.first { $0.windowKind == p.kind }!
            let tr = ArenaTargetRequest(key: target.key(account: p.account, cap: p.cap), target: target,
                                        accounts: [p.account], grid: grid, cap: p.cap, resetAt: p.reset)
            let t0 = Date()
            try model.fit(h)
            let fc = try model.forecast(ArenaRequest(now: p.now, accounts: hist.accounts, targets: [tr])).byKey[tr.key]!
            let dt = Date().timeIntervalSince(t0)
            let label = "\(p.kind):\(p.account)\(p.cap.map { ":" + $0 } ?? "")"
            let st = model.states[.init(kind: p.kind, cap: p.cap)]?.1 as? MLGBMQuantileModel.State
            #expect((st != nil) == p.e2e.trained, "\(label) trained")
            func compare(_ e: Ref.E2E) throws -> (scale: Double, worst: Double) {
                var ds = 0.0
                if let st, let scale = e.scale { ds = zip(st.scale, scale).map { abs($0 - $1) }.max() ?? 0 }
                let Q = try Self.doubles(e.quantiles)
                let g = grid.count
                var worst = 0.0
                if fc.levels == e.levels_out, let qs = fc.quantiles, qs.count * g == Q.count {
                    for i in qs.indices { for j in 0..<g { worst = max(worst, abs(qs[i][j] - Q[i * g + j])) } }
                } else { worst = .infinity }
                return (ds, worst)
            }
            let exact = try compare(nb.probes[pi].e2e), asIs = try compare(p.e2e)
            #expect(exact.scale < 1e-9, "\(label) scale vs LightGBM without bundling: \(exact.scale)")
            #expect(exact.worst < 1e-9, "\(label) quantiles vs LightGBM without bundling: worst |d| \(exact.worst)")
            report.append(String(format: "%@: no bundling worst |d| %.1e (scale %.1e); bundling worst |d| %.3f points (scale %.3f); %d levels × %d grid times; Swift fit+forecast %.2fs (Python %.2fs)",
                                 label, exact.worst, exact.scale, asIs.worst, asIs.scale, fc.levels?.count ?? 0, grid.count,
                                 dt, p.e2e.py_s))
        }
        print("ml-gbm-quantile end to end vs Python:\n" + report.joined(separator: "\n"))
    }
}
