import Foundation
import Testing
import SwiftData
@testable import PacerCore

/// The ports registered in `portModels` (naive-flat, port-engine-recent-rate,
/// port-engine-kalman-trend), the roster's rules for who can be picked, and
/// the names the sheet shows.
@Suite("Arena runtime: port models and the roster")
struct RuntimePortModelsTests {

    static func run(_ name: String, _ c: ArenaFixtures.Case) throws -> ArenaTargetForecast {
        let runner = ArenaRunner(registry: ArenaRegistry.portModels)
        let req = ArenaFixtures.request(c)
        let fc = try runner.forecast(model: name, history: ArenaFixtures.history(c), request: req)
        return try #require(fc.byKey[req.targets[0].key])
    }

    /// `kit/baselines.meter_flat` on every fixture case: the cycle's latest
    /// reading as read (never a running maximum), flat to the reset.
    @Test func naiveFlatHoldsTheCyclesLatestReading() throws {
        for c in try ArenaFixtures.cases().cases {
            let h = ArenaFixtures.history(c)
            let meter = ArenaMeterID(account: c.inputs.account, windowKind: c.inputs.window_kind,
                                     scopeModel: c.inputs.scope_model)
            let window: Millis = c.inputs.window_kind == "five_hour" ? 5 * ArenaTime.hour : 7 * ArenaTime.day
            let expected = h.readings(meter)
                .filter { r in r.active && r.tEvent <= h.now
                    && r.resetsAt.map { abs($0 - c.request.reset_at) * 2 < window } == true }
                .last?.utilPct ?? 0
            let fc = try Self.run("naive-flat", c)
            #expect(fc.median == Array(repeating: expected, count: c.request.grid.count), "case \(c.id)")
        }
    }

    /// The port-engine models draw exactly what the app draws for that
    /// method: the anchored, floored, capped, non-decreasing line, whose end
    /// is the engine's own `displayedAtReset`.
    @Test func portEngineModelsAreTheAppsMethods() throws {
        for (name, model) in [("port-engine-recent-rate", BurnTrajectory.RecentRate() as any BurnTrajectory.Model),
                              ("port-engine-kalman-trend", BurnTrajectory.KalmanTrend())] {
            var compared = 0
            for c in try ArenaFixtures.cases().cases {
                let h = ArenaFixtures.history(c)
                let meter = ArenaMeterID(account: c.inputs.account, windowKind: c.inputs.window_kind)
                let duration: TimeInterval = c.inputs.window_kind == "five_hour" ? 5 * 3600 : 7 * 86400
                let rows = h.readings(meter).compactMap { r -> (at: Date, usedPercentage: Double, resetsAt: Date)? in
                    guard let v = r.utilPct, let reset = r.resetsAt,
                          r.tEvent >= h.now - 32 * ArenaTime.day else { return nil }
                    return (ArenaTime.date(r.tEvent), v, ArenaTime.date(reset))
                }
                let fc = try Self.run(name, c).median
                #expect(fc == fc.sorted(), "\(name) case \(c.id): non-decreasing")
                let (current, _) = BurnTrajectory.segment(samples: rows, duration: duration, now: ArenaTime.date(h.now))
                guard let current, let proj = model.fit(current) else {
                    #expect(Set(fc).count == 1, "\(name) case \(c.id): held flat when the method declines")
                    continue
                }
                let shown = BurnTrajectory.displayedAtReset(proj, partial: current)
                #expect(abs(fc.last! - shown) < 1e-3, "\(name) case \(c.id)")
                #expect(fc.allSatisfy { $0 >= current.usedNow - 1e-9 && $0 <= 100 })
                compared += 1
            }
            #expect(compared > 5, "\(name) fitted too few cases to mean anything")
        }
    }

    @Test func helpersAreNeverPickable() {
        let roster = ArenaRoster(registry: ArenaRegistry.portModels + [
            ArenaModelSpec(name: "fm-timestral-5m-spend", targets: [.meterFiveHour]) { NaiveFlat(context: $0) },
            ArenaModelSpec(name: "quiet-helper", targets: [.meterFiveHour], config: ["selectable": false]) {
                NaiveFlat(context: $0)
            },
            ArenaModelSpec(name: "five-only", targets: [.meterFiveHour]) { NaiveFlat(context: $0) },
        ])
        #expect(roster.selectableIds == ["naive-flat", "five-only"])
        #expect(!ArenaRoster.isSelectable(ArenaModelSpec(name: "port-live-meter", targets: [.meterFiveHour]) {
            NaiveFlat(context: $0)
        }))
        #expect(roster.specs(for: .meterSevenDay).map(\.name) == ["naive-flat"])
        #expect(roster.registry.count == 6)   // helpers still reachable as children
    }

    @Test func windowsMapToArenaMeters() {
        let five = ArenaWindowBinding.make(account: "a", window: .fixed(.fiveHour))
        #expect(five?.target == .meterFiveHour && five?.cap == nil)
        #expect(ArenaWindowBinding.make(account: "a", window: .fixed(.sevenDay))?.target == .meterSevenDay)
        let fable = WindowSpec.scoped(identity: "weekly_scoped|claude-fable|", group: "weekly", label: "Fable",
                                      modelId: "claude-fable", modelDisplayName: "Fable", surface: nil)
        let b = ArenaWindowBinding.make(account: "a", window: fable)
        #expect(b?.target == .meterScoped && b?.cap == "Fable")
        #expect(b?.meter == ArenaMeterID(account: "a", windowKind: "weekly_scoped", scopeModel: "Fable"))
        // A per-surface session cap has no arena meter.
        let session = WindowSpec.scoped(identity: "session||claude_code", group: "session", label: "Code",
                                        modelId: nil, modelDisplayName: nil, surface: "claude_code")
        #expect(ArenaWindowBinding.make(account: "a", window: session) == nil)
        let roster = ArenaRoster(registry: ArenaRegistry.portModels)
        #expect(RateLimitRoster.ids(window: .fixed(.fiveHour), arena: roster)
                == RateLimitRoster.engineIds + ["naive-flat"])
        #expect(RateLimitRoster.ids(window: session, arena: roster) == RateLimitRoster.engineIds)
        #expect(RateLimitRoster.complexities(arena: roster)["naive-flat"] == 1)
        #expect(RateLimitRoster.complexities(arena: roster)["kalman-trend"] == 5)
    }

    /// No arena model reaches the sheet as its folder name.
    @Test func arenaModelsHaveNames() {
        let expected: [String: String] = [
            "naive-flat": "Stays where it is",
            "spend-decay-30m": "Recent spend, fading (30 min)",
            "calib-spend-decay-6h": "Recent spend, fading (6 hr), calibrated range",
            "fm-timestral-5m-meter": "Pretrained network (5M)",
            "fm-timestral-123m-meter": "Pretrained network (123M)",
            "g2-01-haiku-weekly-209m": "Pretrained network (209M)",
            "g1-10-fable-analog": "Past moments like now",
            "calib-g1-10-fable-analog": "Past moments like now, calibrated range",
            "g2-08-fable-burst": "Bursts of use, simulated",
            "g2-04-opus-fable-mix": "Several forecasters, blended",
            "g2-06-opus-fmgate2": "Networks, gated by record",
            "g1-08-opus-fm": "Pretrained networks, combined",
            "g2-05-sonnet-final": "Several forecasters, blended",
            "port-engine-kalman-trend": "Smoothed trend (Kalman filter)",
            "g1-10-fable-mix": "Past moments, blended",
            "g2-07-opus-limit": "Your habits near the limit",
            "g2-07-opus-pool": "Habits near the limit, blended",
            "g2-08-fable-burst-mix": "Bursts of use, blended",
            "g2-01-haiku-weekly-209m-extended": "Pretrained network (209M, two weeks)",
            "struct-timestral-28m": "Spend forecast, converted (28M)",
        ]
        for (id, name) in expected {
            #expect(BurnTrajectory.displayName(id) == name, "\(id)")
            #expect(BurnTrajectory.summary(id) != nil, "\(id)")
        }
        // The engine's own names are untouched.
        #expect(BurnTrajectory.displayName("recent-rate") == "Latest pace, held")
        #expect(BurnTrajectory.howItWorks("recent-rate", windowDuration: 5 * 3600)?.contains("hour") == true)
    }
}
