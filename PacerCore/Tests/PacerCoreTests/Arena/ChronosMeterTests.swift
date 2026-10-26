import Foundation
import Testing
@testable import PacerCore

/// `fm-chronos2-meter` (`FMMeterModel` over the `chronos2` backend) end to
/// end through the runner, against `chronos-fm-chronos2-meter.json`: the
/// context it reads, then its quantiles at the fixture's levels, within the
/// network's tolerance carried through (`1e-3 · max(1, |raw|)` on the
/// cumulative burn, `|raw| <= |c_last| + 100` wherever the meter is not
/// clipped). Skips when the weights are not on this Mac.
@Suite struct ChronosMeterTests {
    static let model = "fm-chronos2-meter"

    @Test func registeredWithMeterTargetsAndPinnedWeights() throws {
        let spec = try #require(ArenaRegistry.spec(Self.model))
        #expect(spec.targets == [.meterFiveHour, .meterSevenDay, .meterScoped])
        #expect(spec.children.isEmpty)
        #expect(spec.weights == [ChronosWeights.chronos2])
        #expect(spec.config["backend"]?.string == "chronos2")
        #expect(spec.config["weights"]?.string == ChronosWeights.chronos2)
        #expect(spec.config.table("context_steps").int("seven_day", 0) == 672)
        #expect(spec.config.table("context_steps").int("five_hour", 0) == 288)
        #expect(FMBackends.factories["chronos2"] != nil)
        for spec in ArenaRegistry.chronosModels {
            for w in spec.weights {
                let pins = try #require(ArenaWeightStore.pinned[w], "\(spec.name): \(w)")
                #expect(Set(pins.map(\.name)).isSuperset(of: ArenaWeightStore.required))
            }
        }
        // Not bundled: downloaded on first use.
        #expect(!FMWeights.bundled.contains(ChronosWeights.chronos2))
    }

    /// The pinned hashes are the files on this Mac (the local Hugging Face
    /// snapshot the arena scored); hashing 478 MB takes a second or two.
    @Test func pinsMatchTheLocalSnapshot() throws {
        guard let dir = ChronosTestWeights.url() else { return }
        for f in try #require(ArenaWeightStore.pinned[ChronosWeights.chronos2]) where ArenaWeightStore.required.contains(f.name) {
            // A Hugging Face snapshot holds symlinks into its blob store.
            let u = dir.appendingPathComponent(f.name).resolvingSymlinksInPath()
            #expect(try ArenaWeightStore.sha256(of: u) == f.sha256, "\(f.name)")
            let size = try FileManager.default.attributesOfItem(atPath: u.path)[.size] as? NSNumber
            #expect(size?.intValue == f.bytes, "\(f.name)")
        }
    }

    @Test func missingWeightsAreReportedNotCrashed() throws {
        let c = try ArenaFixtures.cases().cases[0]
        let runner = ArenaRunner(registry: ArenaRegistry.all, services: ArenaServices(weights: { _ in nil }))
        #expect(throws: ArenaError.weightsUnavailable(ChronosWeights.chronos2)) {
            try runner.forecast(model: Self.model, history: ArenaFixtures.history(c), request: ArenaFixtures.request(c))
        }
    }

    @Test func meterModelEndToEnd() throws {
        guard ChronosTestWeights.url() != nil else { print("\(Self.model): weights not on this Mac, skipped"); return }
        let cases = try ArenaFixtures.cases().cases
        let fm = try ArenaFixtures.model(ChronosNetworkTests.fixture)
        let runner = ArenaRunner(registry: ArenaRegistry.all, services: ChronosTestWeights.services())
        var worst = 0.0, worstRel = 0.0
        #expect(fm.outputs.count == 20)
        for out in fm.outputs {
            let c = try #require(cases.first { $0.id == out.case })
            let h = ArenaFixtures.history(c)
            let fc = try runner.forecast(model: Self.model, history: h, request: ArenaFixtures.request(c))
            let tf = try #require(fc.byKey[c.request.key])
            var cLast = 0.0
            // The intermediates first: the context and the meter now.
            if let d = out.detail, let ctx = d["context"]?.numbers {
                let s = FMSeries.meterSeries(h, account: c.inputs.account, windowKind: c.inputs.window_kind,
                                             scopeModel: c.inputs.scope_model, now: c.request.now)
                let step = Millis(d["step_ms"]?.number ?? 0)
                let grid = FMSeries.regularGrid(now: c.request.now, stepMs: step, n: ctx.count)
                let mine = FMSeries.resampleLast(times: s.times, values: s.cum, grid: grid)
                #expect(mine.count == ctx.count)
                #expect(zip(mine, ctx).allSatisfy { a, b in b.map { abs(a - $0) < 1e-6 } ?? a.isNaN }, "\(out.case) context")
                cLast = abs(ctx.last.flatMap { $0 } ?? 0)
            }
            let tol = 1e-3 * max(1, cLast + 100)
            for (li, lv) in out.levels.enumerated() {
                let got = tf.quantile(lv)
                #expect(got.count == out.quantiles[li].count)
                for (j, w) in out.quantiles[li].enumerated() {
                    let e = abs(got[j] - w)
                    worst = max(worst, e); worstRel = max(worstRel, e / tol)
                    #expect(e <= tol, "case \(out.case) level \(lv) grid \(j): \(got[j]) vs \(w)")
                }
            }
            for (j, w) in out.median.enumerated() { #expect(abs(tf.median[j] - w) <= tol, "case \(out.case) median \(j)") }
        }
        print("\(Self.model) end to end: \(fm.outputs.count) cases, worst |Δ| = \(worst) points (\(worstRel) of the tolerance)")
    }

    /// The scoped weekly meter takes the same path as the weekly one (its
    /// readings are `weekly_scoped` with a `scopeModel`).
    @Test func scopedMeterForecasts() throws {
        guard ChronosTestWeights.url() != nil else { return }
        let c = try #require(try ArenaFixtures.cases().cases.first { $0.request.target == "meter.seven_day" })
        let src = ArenaFixtures.history(c)
        let weekly = src.readings(account: c.inputs.account, windowKind: "seven_day")
        let id = ArenaMeterID(account: c.inputs.account, windowKind: "weekly_scoped", scopeModel: "Fable")
        let store = ArenaHistoryStore(meters: [id: weekly], spend: [:], tzOffsetMin: src.tzOffsetMin,
                                      dataStart: src.historyStart)
        let h = ArenaHistory(store: store, now: c.request.now, accounts: [c.inputs.account], start: src.start)
        let req = ArenaRunner.request(history: h, targets: [.meterScoped])
        let tr = try #require(req.targets.first)
        #expect(tr.cap == "Fable")
        let runner = ArenaRunner(registry: ArenaRegistry.all, services: ChronosTestWeights.services())
        let tf = try #require(try runner.forecast(model: Self.model, history: h, request: req).byKey[tr.key])
        #expect(tf.gridCount == tr.grid.count)
        let med = tf.median
        #expect(med.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 100 })
        #expect(zip(med, med.dropFirst()).allSatisfy { $0 <= $1 + 1e-9 })
    }
}

/// Wall time per Chronos-2 forecast on this Mac, for the meter shapes
/// `fm-chronos2-meter` uses: five-hour (288 steps of context, 60 to the
/// reset) and weekly (672 of context, 672 to the reset), with Accelerate
/// single-threaded and with its default threading; then the model through
/// the runner on a 120-day synthetic history (what a backfill does).
/// Opt-in (`PACER_CHRONOS_BENCH=1`), and meaningful only in a release build
/// (`swift test -c release -Xswiftc -enable-testing`).
///
/// Measured 2026-10-26 on Apple silicon, the machine shared with other
/// builds (load average 40-75; ms per forecast, one thread / default):
/// five-hour 13.5 / 13.0, weekly 23.6 / 18.0; through the runner on the
/// 120-day history 12.8 five-hour, 16.3 weekly. The encoder's matrix
/// products alone, timed back to back at the same shapes, took 10 and 18:
/// the rest of the forward pass is a few milliseconds. The heaviest load
/// seen tripled every number (36 and 49 single-threaded).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PACER_CHRONOS_BENCH"] != nil))
struct ChronosTimingTests {
    @Test func timings() throws {
        guard let p = try ChronosTestWeights.pipeline() else { print("Chronos-2 weights not here"); return }
        let be = Chronos2Backend(p)
        var lines: [String] = []
        for (label, t, h) in [("five-hour", 288, 60), ("weekly", 672, 672)] {
            let ctx = TimestralTimingTests.context(t, seed: 7)
            for single in [true, false] {
                FMBackends.setBLASThreading(singleThreaded: single)
                _ = try be.quantiles(context: [[ctx]], horizon: h)   // warm
                let n = 10
                let start = DispatchTime.now().uptimeNanoseconds
                for _ in 0..<n { _ = try be.quantiles(context: [[ctx]], horizon: h) }
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 / Double(n)
                lines.append(String(format: "chronos-2 %@ %@: %.1f ms/forecast", label, single ? "1 thread" : "default threads", ms))
            }
        }
        FMBackends.setBLASThreading(singleThreaded: false)

        let store = TimestralSyntheticHistory.store(days: 120)
        let runner = ArenaRunner(registry: ArenaRegistry.all, services: ChronosTestWeights.services())
        let last = store.meters.values.compactMap { $0.last?.tEvent }.max()!
        for target in [ArenaTarget.meterFiveHour, .meterSevenDay] {
            var n = 0, total = 0.0
            for i in 0..<24 {
                let now = last - Millis(i) * (30 * ArenaTime.day / 24) - 7 * ArenaTime.minute
                let h = ArenaHistory(store: store, now: now, accounts: ["A1"])
                let req = ArenaRunner.request(history: h, targets: [target])
                guard !req.targets.isEmpty else { continue }
                let t0 = DispatchTime.now().uptimeNanoseconds
                _ = try runner.forecast(model: "fm-chronos2-meter", history: h, request: req)
                total += Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                n += 1
            }
            lines.append(String(format: "fm-chronos2-meter %@ on a 120-day history: %.1f ms/forecast over %d cuts",
                                target.rawValue, total / Double(max(n, 1)), n))
        }
        print("Chronos-2 timings\n" + lines.joined(separator: "\n"))
    }
}
