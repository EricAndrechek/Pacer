import Foundation
import Testing
@testable import PacerCore

/// The pools (g2-08-fable-burst-mix, g2-07-opus-pool) over their real
/// simulation child and a stand-in for the Timestral child, registered under
/// the Timestral model's name ahead of the real registry (the runner keeps
/// the first spec of a name), so these tests do not depend on the network.
@Suite struct SimulationPoolTests {
    /// A Timestral stand-in that answers in quantiles, as a Swift FM port
    /// may: every level at `value`, so its paths are recognizable.
    final class StubFM: ArenaModel {
        static let value = 63.25
        init(context: ArenaContext) {}
        func fit(_ history: ArenaHistory) {}
        func forecast(_ request: ArenaRequest) -> ArenaForecast {
            ArenaForecast(byKey: Dictionary(uniqueKeysWithValues: request.targets.map { tr in
                let row = Array(repeating: Self.value, count: tr.grid.count)
                return (tr.key, ArenaTargetForecast(levels: [0.1, 0.5, 0.9], quantiles: [row, row, row]))
            }))
        }
    }

    final class Failing: ArenaModel {
        init(context: ArenaContext) {}
        func fit(_ history: ArenaHistory) {}
        func forecast(_ request: ArenaRequest) throws -> ArenaForecast { throw ArenaError.invalid("child down") }
    }

    static func runner(fm: Bool = true) -> ArenaRunner {
        let all: Set<ArenaTarget> = [.meterFiveHour, .meterSevenDay, .meterScoped]
        let stubs = ["fm-timestral-123m-meter", "fm-timestral-5m-meter"].map { name in
            fm ? ArenaModelSpec(name: name, targets: all) { StubFM(context: $0) }
               : ArenaModelSpec(name: name, targets: all) { Failing(context: $0) }
        }
        return ArenaRunner(registry: stubs + ArenaRegistry.simulationModels)
    }

    static func isStub(_ p: [Double]) -> Bool { p.allSatisfy { $0 == StubFM.value } }

    @Test func burstMixPoolsHalfAndHalfAndPinsTheHead() throws {
        let c = try #require(try ArenaFixtures.cases("cases-spend").cases.first { $0.id == "s04" })
        let r = Self.runner()
        let h = ArenaFixtures.history(c), req = ArenaFixtures.request(c)
        let key = c.request.key
        let mix = try #require(try r.forecast(model: G208FableBurstMix.name, history: h, request: req).byKey[key]?.paths)
        let burst = try #require(try r.forecast(model: G208FableBurst.name, history: h, request: req).byKey[key]?.paths)
        #expect(mix.count == 200)
        let head = c.request.grid.indices.filter { c.request.grid[$0] - c.request.now <= 3 * 60_000 }
        #expect(head.count == 4)
        // The first half: the burst model's paths, evenly spaced
        // (np.linspace(0, 199, 100).round()); the second half: the
        // stand-in's. Then every path's head is the burst model's path i
        // (the Python pins row i to burst row i, whichever path row i holds)
        // and the path is kept non-decreasing.
        for i in 0..<200 {
            var e = i < 100 ? burst[Int((Double(i) * 199 / 99).rounded(.toNearestOrEven))]
                            : Array(repeating: StubFM.value, count: c.request.grid.count)
            for g in head { e[g] = burst[i][g] }
            SimArrays.clipRunningMax(&e, lo: 0, hi: 100)
            #expect(mix[i] == e, "path \(i)")
        }
        #expect(mix.allSatisfy { p in zip(p, p.dropFirst()).allSatisfy { $0 <= $1 } })
    }

    @Test func burstMixStandsAloneWhenTheNetworkFails() throws {
        let c = try #require(try ArenaFixtures.cases("cases-spend").cases.first { $0.id == "s04" })
        let r = Self.runner(fm: false)
        let h = ArenaFixtures.history(c), req = ArenaFixtures.request(c)
        let mix = try #require(try r.forecast(model: G208FableBurstMix.name, history: h, request: req).byKey[c.request.key]?.paths)
        let burst = try #require(try r.forecast(model: G208FableBurst.name, history: h, request: req).byKey[c.request.key]?.paths)
        #expect(mix == burst)
    }

    @Test func opusPoolTakesTheConfiguredShareFromTheNetwork() throws {
        for id in ["c00", "c01"] {          // five-hour, seven-day: half each
            let c = try #require(try ArenaFixtures.cases().cases.first { $0.id == id })
            let fc = try Self.runner().forecast(model: G207OpusPool.name, history: ArenaFixtures.history(c),
                                                request: ArenaFixtures.request(c))
            let paths = try #require(fc.byKey[c.request.key]?.paths)
            #expect(paths.count == 200)
            #expect(paths.prefix(100).allSatisfy { !Self.isStub($0) }, "case \(id)")
            #expect(paths.suffix(100).allSatisfy(Self.isStub), "case \(id)")
        }
        // A scoped weekly cap: 60 % from the network. The fixtures hold no
        // scoped meter, so a weekly case's readings stand in for one.
        let c = try #require(try ArenaFixtures.cases().cases.first { $0.id == "c01" })
        let (h, req) = try Self.asScoped(c, cap: "Fable")
        let fc = try Self.runner().forecast(model: G207OpusPool.name, history: h, request: req)
        let paths = try #require(fc.byKey[req.targets[0].key]?.paths)
        #expect(paths.count == 200)
        #expect(paths.filter(Self.isStub).count == 120)
        #expect(paths.prefix(80).allSatisfy { !Self.isStub($0) })
    }

    @Test func opusPoolStandsAloneWhenTheNetworkFails() throws {
        let c = try #require(try ArenaFixtures.cases().cases.first { $0.id == "c03" })
        let r = Self.runner(fm: false)
        let h = ArenaFixtures.history(c), req = ArenaFixtures.request(c)
        let pool = try #require(try r.forecast(model: G207OpusPool.name, history: h, request: req).byKey[c.request.key]?.paths)
        let sim = try #require(try r.forecast(model: G207OpusLimit.name, history: h, request: req).byKey[c.request.key]?.paths)
        #expect(pool == sim)
    }

    /// Both pools end to end over the real registry: the real Timestral
    /// children, when their weights are on this Mac (skipped otherwise).
    @Test func poolsRunWithTheRealTimestralChildren() throws {
        for (pool, size, cases, ids) in [(G208FableBurstMix.name, "123m", "cases-spend", ["s04", "s10"]),
                                         (G207OpusPool.name, "5m", "cases", ["c00", "c01"])] {
            guard let id = TimestralTestWeights.ids[size], TimestralTestWeights.url(id) != nil else {
                print("\(pool): Timestral-\(size) weights not on this Mac, skipped")
                continue
            }
            for cid in ids {
                let c = try #require(try ArenaFixtures.cases(cases).cases.first { $0.id == cid })
                let h = ArenaFixtures.history(c), req = ArenaFixtures.request(c)
                let log = LogBox()
                let services = ArenaServices(weights: { TimestralTestWeights.url($0) }, log: { log.add("\($0): \($1)") })
                let runner = ArenaRunner(registry: ArenaRegistry.all, services: services)
                var paths: [[Double]] = []
                let ms = try SimulationTimingTests.ms {
                    paths = try #require(try runner.forecast(model: pool, history: h, request: req).byKey[c.request.key]?.paths)
                }
                let sim = pool == G207OpusPool.name ? G207OpusLimit.name : G208FableBurst.name
                let alone = try #require(try runner.forecast(model: sim, history: h, request: req).byKey[c.request.key]?.paths)
                print(String(format: "\(pool) \(cid) with Timestral-\(size): %.0f ms, logs \(log.lines)", ms))
                #expect(log.lines.isEmpty, "\(log.lines)")
                #expect(paths.count == 200)
                let monotone = paths.allSatisfy { p in zip(p, p.dropFirst()).allSatisfy { $0 <= $1 } && p.allSatisfy { $0 >= 0 && $0 <= 100 } }
                if pool == G208FableBurstMix.name {
                    #expect(monotone, "the mix keeps every path in [0, 100] and non-decreasing")
                } else {
                    // The opus pool stacks its children's paths as they are, and
                    // g2-07's can fall: a re-base drops a path to 0 mid-cycle.
                    #expect(paths.allSatisfy { p in p.allSatisfy { $0 >= 0 && $0 <= 100 } })
                    if !monotone { print("\(pool) \(cid): some paths fall (g2-07's re-base hazard)") }
                }
                #expect(paths != alone, "the network's paths are in the pool")
            }
        }
    }

    final class LogBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [String] = []
        func add(_ s: String) { lock.lock(); _lines.append(s); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
    }

    static func asScoped(_ c: ArenaFixtures.Case, cap: String) throws -> (ArenaHistory, ArenaRequest) {
        let base = ArenaFixtures.history(c)
        let id = ArenaMeterID(account: c.inputs.account, windowKind: "weekly_scoped", scopeModel: cap)
        let rows = base.readings(account: c.inputs.account, windowKind: c.inputs.window_kind)
        let store = ArenaHistoryStore(meters: [id: rows], spend: [:], tzOffsetMin: c.inputs.tz_offset_min,
                                      dataStart: c.inputs.history_start)
        let h = ArenaHistory(store: store, now: c.request.now, accounts: [c.inputs.account], start: c.inputs.history_start)
        let tr = try #require(ArenaRunner.targetRequest(history: h, meter: id))
        return (h, ArenaRequest(now: h.now, accounts: h.accounts, targets: [tr]))
    }
}
