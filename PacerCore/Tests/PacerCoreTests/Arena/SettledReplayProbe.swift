import Foundation
import Testing
@testable import PacerCore

/// The settled-moment rule (#374) replayed on a real record, through the
/// shipping ranking (`EngineSelfEval.rankRL`), with and without the readings
/// that tell a settled moment.
///
/// - Live: `PACER_RL_SETTLED_LIVE=<surface prefix>@<fraction>,…` ranks a
///   window's whole record at that point, as the engine would now.
/// - Walk-forward: each finished cycle's moments are ranked from the cycles
///   before it only, and the pick is scored on where the meter really ended,
///   at every moment (a live cycle cannot know it has settled) and at the
///   open ones.
///
/// Opt-in: `PACER_RL_SETTLED_REPLAY=<path>` names a tab-separated dump of the
/// record with the reading at each cut (surface, method, period key, bucket,
/// predicted, truth, reading; the reading empty when unknown), which never
/// leaves the Mac it came from.
@Suite("Settled moments replayed on a real record", .serialized)
struct SettledReplayProbe {

    struct Scored: Sendable { let surface: String; let period: String; let open: Bool; let errors: [Double] }

    final class Shared: @unchecked Sendable {
        let lock = NSLock()
        var next = 0
        var results: [Scored] = []
    }

    static func load(_ path: String) throws -> [String: [EngineSelfEval.Record]] {
        var bySurface: [String: [EngineSelfEval.Record]] = [:]
        for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count == 7, let predicted = Double(f[4]), let truth = Double(f[5]) else { continue }
            bySurface[String(f[0]), default: []].append(
                .init(method: String(f[1]), bucket: String(f[3]), periodKey: String(f[2]),
                      predicted: predicted, truth: truth, reading: Double(f[6])))
        }
        return bySurface
    }

    static func candidates(_ surface: String) -> Set<String> {
        let target: ArenaTarget = surface.hasPrefix("rl-five_hour") ? .meterFiveHour
            : surface.hasPrefix("rl-seven_day") ? .meterSevenDay : .meterScoped
        return Set(RateLimitRoster.engineIds + ArenaRoster.standard.specs(for: target).map(\.name))
    }

    static func blind(_ rows: [EngineSelfEval.Record]) -> [EngineSelfEval.Record] {
        rows.map { .init(method: $0.method, bucket: $0.bucket, periodKey: $0.periodKey, predicted: $0.predicted,
                         truth: $0.truth) }
    }

    static func rank(_ rows: [EngineSelfEval.Record], surface: String, at x: Double?) -> EngineSelfEval.RLRanking {
        let weekly = !surface.hasPrefix("rl-five_hour")
        let p = EngineParams.current
        return EngineSelfEval.rankRL(rows, candidates: candidates(surface),
                                     complexity: RateLimitRoster.complexities(arena: .standard), weekly: weekly,
                                     at: x, depth: EngineSelfEval.rlDepth(weekly: weekly),
                                     tieRelative: p.rlTieRelative > 0 ? p.rlTieRelative : nil,
                                     disagreement: p.rlDisagreementPoints > 0 ? p.rlDisagreementPoints : nil)
    }

    @Test func settledMoments() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["PACER_RL_SETTLED_REPLAY"] else { return }
        let bySurface = try Self.load(path)
        var text: [String] = []

        for spec in (env["PACER_RL_SETTLED_LIVE"] ?? "").split(separator: ",") {
            let parts = spec.split(separator: "@")
            guard parts.count == 2, let x = Double(parts[1]),
                  let surface = bySurface.keys.first(where: { $0.hasPrefix(String(parts[0])) }) else { continue }
            let rows = bySurface[surface]!.filter { EngineSelfEval.rlGrading.contains(bucket: $0.bucket) }
            for (label, r) in [("without readings", Self.rank(Self.blind(rows), surface: surface, at: x)),
                               ("with readings", Self.rank(rows, surface: surface, at: x))] {
                text.append("\(parts[0]) at \(x), \(label): pick \(r.pick ?? "none")"
                            + ", ranked at \(r.at.map { "\($0)" } ?? "every cut")"
                            + ", span \(r.span?.cycles ?? 0) cycles")
                for s in r.ranked.prefix(10) {
                    text.append(String(format: "    %-36@ %6.2f", s.method, s.typicalAbsError ?? .nan))
                }
            }
        }

        // Walk-forward: one job per (surface, cycle) with readings.
        struct Job: Sendable { let surface: String; let prior: [EngineSelfEval.Record]
                     let moments: [(cut: Double, open: Bool, byMethod: [String: EngineSelfEval.Record])] }
        var jobs: [Job] = []
        for (surface, all) in bySurface where !surface.hasPrefix("rl-scoped") {
            let weekly = !surface.hasPrefix("rl-five_hour")
            let rows = all.filter { Self.candidates(surface).contains($0.method)
                && EngineSelfEval.rlGrading.contains(bucket: $0.bucket) }
            let byPeriod = Dictionary(grouping: rows, by: \.periodKey)
            let periods = byPeriod.keys.sorted()
            let depth = EngineSelfEval.rlDepth(weekly: weekly)
            for i in periods.indices where i >= EngineSelfEval.rlMinPeriods(weekly: weekly) {
                let mine = byPeriod[periods[i]]!
                guard mine.contains(where: { $0.reading != nil }) else { continue }
                let prior = periods[max(0, i - depth)..<i].flatMap { byPeriod[$0]! }
                let moments = Dictionary(grouping: mine, by: \.bucket).compactMap { bucket, rs in
                    EngineSelfEval.rlCutFraction(bucket).flatMap { cut -> (Double, Bool, [String: EngineSelfEval.Record])? in
                        guard let reading = rs.compactMap(\.reading).first, rs[0].truth > 0 else { return nil }
                        return (cut, !EngineSelfEval.isSettled(reading: reading, truth: rs[0].truth),
                                Dictionary(rs.map { ($0.method, $0) }, uniquingKeysWith: { a, _ in a }))
                    }
                }
                jobs.append(Job(surface: surface, prior: prior, moments: moments))
            }
        }
        let shared = Shared()
        let work = jobs
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            while true {
                let j: Job? = shared.lock.withLock { () -> Job? in
                    guard shared.next < work.count else { return nil }
                    defer { shared.next += 1 }
                    return work[shared.next]
                }
                guard let j else { return }
                let blind = Self.blind(j.prior)
                var out: [Scored] = []
                for m in j.moments {
                    let picks = [Self.rank(blind, surface: j.surface, at: m.cut).pick,
                                 Self.rank(j.prior, surface: j.surface, at: m.cut).pick]
                    let errors = picks.compactMap { $0.flatMap { m.byMethod[$0] }.map { abs($0.predicted - $0.truth) } }
                    guard errors.count == picks.count else { continue }
                    out.append(Scored(surface: j.surface, period: m.byMethod.values.first!.periodKey, open: m.open,
                                      errors: errors))
                }
                shared.lock.withLock { shared.results += out }
            }
        }
        func kind(_ s: String) -> String { s.hasPrefix("rl-five_hour") ? "5-hour" : "weekly" }
        func account(_ s: String) -> String { String(s.split(separator: "#").last?.prefix(4) ?? "") }
        func line(_ label: String, _ ms: [Scored]) -> String {
            let cycles = Dictionary(grouping: ms, by: { $0.surface + "|" + $0.period }).values
            func perCycle(_ k: Int) -> Double {
                EngineSelfEval.mean(cycles.map { c in c.map { $0.errors[k] }.reduce(0, +) / Double(c.count) })
            }
            let open = ms.filter(\.open)
            func openMean(_ k: Int) -> Double { open.map { $0.errors[k] }.reduce(0, +) / Double(max(1, open.count)) }
            return String(format: "%@: %d cycles, %d moments (%d open) | pick's miss, cycle mean: off %.3f, on %.3f"
                          + " | open moments: off %.3f, on %.3f",
                          label, cycles.count, ms.count, open.count, perCycle(0), perCycle(1), openMean(0), openMean(1))
        }
        for k in ["5-hour", "weekly"] {
            let ms = shared.results.filter { kind($0.surface) == k }
            guard !ms.isEmpty else { continue }
            text.append(line(k, ms))
            for a in Set(ms.map { account($0.surface) }).sorted() {
                text.append(line("  \(k) · \(a)", ms.filter { account($0.surface) == a }))
            }
        }
        let all = text.joined(separator: "\n")
        print(all)
        if let out = env["PACER_RL_SETTLED_REPLAY_OUT"] { try all.write(toFile: out, atomically: true, encoding: .utf8) }
    }
}
