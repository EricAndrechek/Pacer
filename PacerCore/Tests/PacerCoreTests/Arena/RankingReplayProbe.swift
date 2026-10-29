import Foundation
import Testing
@testable import PacerCore

/// A ranking change replayed on a real record, through the shipping ranking
/// (`EngineSelfEval.rankRL`): each finished cycle's moments are ranked from
/// the cycles before it only, at the point of the window the moment is at,
/// and the pick is scored on where the meter really ended. This is how the
/// disagreement filter (`EngineParams.rlDisagreementPoints`) was chosen.
///
/// Opt-in: `PACER_RL_REPLAY=<path>` names a tab-separated dump of the record
/// (surface, method, period key, bucket, predicted, truth: the columns of
/// `ZENGINEEVALOUTCOME`), which never leaves the Mac it came from.
/// `PACER_RL_REPLAY_THRESHOLDS=0,1,2` picks the thresholds (0: no filter).
@Suite("Ranking replay on a real record", .serialized)
struct RankingReplayProbe {

    struct Moment: Sendable { let surface: String; let period: String; let errors: [Double] }

    /// What the workers share, behind one lock.
    final class Shared: @unchecked Sendable {
        let lock = NSLock()
        var next = 0
        var results: [Moment] = []
        var changed: [Int]
        init(thresholds: Int) { changed = [Int](repeating: 0, count: thresholds) }
    }

    @Test func disagreementFilter() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["PACER_RL_REPLAY"] else { return }
        let thresholds = (env["PACER_RL_REPLAY_THRESHOLDS"] ?? "0,0.5,1,2,3")
            .split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        var bySurface: [String: [EngineSelfEval.Record]] = [:]
        for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count == 6, let predicted = Double(f[4]), let truth = Double(f[5]) else { continue }
            bySurface[String(f[0]), default: []].append(
                .init(method: String(f[1]), bucket: String(f[3]), periodKey: String(f[2]),
                      predicted: predicted, truth: truth))
        }
        let complexity = RateLimitRoster.complexities(arena: .standard)
        let grading = EngineSelfEval.rlGrading

        // One job per (surface, cycle): rank each of its moments under every
        // threshold, from the cycles before it.
        struct Job: Sendable { let surface: String; let weekly: Bool; let prior: [EngineSelfEval.Record]
                     let moments: [(cut: Double, byMethod: [String: EngineSelfEval.Record])]
                     let candidates: Set<String> }
        var jobs: [Job] = []
        for (surface, all) in bySurface {
            let weekly = !surface.hasPrefix("rl-five_hour")
            let target: ArenaTarget = surface.hasPrefix("rl-five_hour") ? .meterFiveHour
                : surface.hasPrefix("rl-seven_day") ? .meterSevenDay : .meterScoped
            let candidates = Set(RateLimitRoster.engineIds + ArenaRoster.standard.specs(for: target).map(\.name))
            let rows = all.filter { candidates.contains($0.method) && grading.contains(bucket: $0.bucket) }
            let byPeriod = Dictionary(grouping: rows, by: \.periodKey)
            let periods = byPeriod.keys.sorted()
            let depth = EngineSelfEval.rlDepth(weekly: weekly)
            // Score from where the arena's grades begin: before that only
            // the engine's seven were graded, which says nothing about this.
            let arenaIds = candidates.subtracting(RateLimitRoster.engineIds)
            guard let firstArena = periods.firstIndex(where: { p in byPeriod[p]!.contains { arenaIds.contains($0.method) } })
            else { continue }
            for i in periods.indices where i >= firstArena + EngineSelfEval.rlMinPeriods(weekly: weekly) {
                let prior = periods[max(0, i - depth)..<i].flatMap { byPeriod[$0]! }
                let moments = Dictionary(grouping: byPeriod[periods[i]]!, by: \.bucket).compactMap { bucket, rs in
                    EngineSelfEval.rlCutFraction(bucket).flatMap { cut in
                        rs.first!.truth > 0 ? (cut, Dictionary(rs.map { ($0.method, $0) }, uniquingKeysWith: { a, _ in a })) : nil
                    }
                }
                jobs.append(Job(surface: surface, weekly: weekly, prior: prior, moments: moments, candidates: candidates))
            }
        }

        // Four workers: enough to finish in minutes, not the whole Mac.
        let shared = Shared(thresholds: thresholds.count)
        let work = jobs
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            while true {
                let j: Job? = shared.lock.withLock { () -> Job? in
                    guard shared.next < work.count else { return nil }
                    defer { shared.next += 1 }
                    return work[shared.next]
                }
                guard let j else { return }
                var out: [Moment] = []
                var flips = [Int](repeating: 0, count: thresholds.count)
                for m in j.moments {
                    let picks = thresholds.map { t in
                        EngineSelfEval.rankRL(j.prior, grading: grading, candidates: j.candidates, complexity: complexity,
                                              weekly: j.weekly, at: m.cut, depth: EngineSelfEval.rlDepth(weekly: j.weekly),
                                              tieRelative: EngineParams.current.rlTieRelative,
                                              disagreement: t > 0 ? t : nil).pick
                    }
                    // Only moments every variant's pick forecast, so each is
                    // scored on the same ones.
                    let errors = picks.compactMap { $0.flatMap { m.byMethod[$0] }.map { abs($0.predicted - $0.truth) } }
                    guard errors.count == thresholds.count else { continue }
                    for k in picks.indices where picks[k] != picks[0] { flips[k] += 1 }
                    out.append(Moment(surface: j.surface, period: m.byMethod.values.first!.periodKey, errors: errors))
                }
                shared.lock.withLock {
                    shared.results += out
                    for k in flips.indices { shared.changed[k] += flips[k] }
                }
            }
        }
        let results = shared.results, changed = shared.changed

        func kind(_ s: String) -> String {
            s.hasPrefix("rl-five_hour") ? "5-hour" : s.hasPrefix("rl-seven_day") ? "weekly" : "scoped weekly"
        }
        func account(_ s: String) -> String { String(s.split(separator: "#").last?.prefix(4) ?? "") }
        func report(_ label: String, _ ms: [Moment]) -> String {
            // A cycle's score is the mean over its moments; then the mean and
            // median over cycles, and the pooled mean over every moment.
            let cycles = Dictionary(grouping: ms, by: { $0.surface + "|" + $0.period }).values
            var lines = ["\(label): \(cycles.count) cycles, \(ms.count) moments"]
            for k in thresholds.indices {
                let perCycle = cycles.map { c in c.map { $0.errors[k] }.reduce(0, +) / Double(c.count) }
                let pooled = ms.map { $0.errors[k] }.reduce(0, +) / Double(max(1, ms.count))
                lines.append(String(format: "  threshold %-4@ cycle mean %.3f  cycle median %.3f  moment mean %.3f",
                                    thresholds[k] == 0 ? "off" : String(format: "%g", thresholds[k]),
                                    EngineSelfEval.mean(perCycle), EngineSelfEval.median(perCycle), pooled))
            }
            return lines.joined(separator: "\n")
        }
        var text: [String] = []
        for k in ["5-hour", "weekly", "scoped weekly"] {
            let ms = results.filter { kind($0.surface) == k }
            guard !ms.isEmpty else { continue }
            text.append(report(k, ms))
            for a in Set(ms.map { account($0.surface) }).sorted() {
                text.append(report("  \(k) · \(a)", ms.filter { account($0.surface) == a }))
            }
        }
        text.append("picks that differ from no filter, per threshold: \(zip(thresholds, changed).map { "\($0)=\($1)" })")
        let all = text.joined(separator: "\n")
        print(all)
        if let out = env["PACER_RL_REPLAY_OUT"] { try all.write(toFile: out, atomically: true, encoding: .utf8) }
    }
}
