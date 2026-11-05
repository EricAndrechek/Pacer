import Foundation
import Testing
@testable import PacerCore

/// `RecentBurn` replayed on a copy of a real store's readings (#339, #358).
/// Opt-in, and reads a CSV export, never the store:
///
///     sqlite3 -csv <copy of pacer.sqlite> "SELECT ZACCOUNTID, ZWINDOW,
///         ZSAMPLEDAT + 978307200, ZUSEDPERCENTAGE,
///         COALESCE(ZRESETSAT + 978307200, '') FROM ZRATELIMITSAMPLE" > /tmp/burn/readings.csv
///     PACER_BURN_REPLAY=/tmp/burn/readings.csv swift test --package-path PacerCore --filter RecentBurnReplay
///
/// One moment every 10 minutes along every account's 5-hour and weekly
/// readings, each scored against the climb the readings actually made over
/// the next half hour and the next two hours, inside one cycle. Three
/// estimators side by side:
///
/// - `legacy`, the rate as it was before #339: first-to-last over the half
///   hour, cycle membership anchored on the newest reading's reset alone;
/// - `half hour`, today's rate handed only the last half hour of readings:
///   the cycle fix (#339) and nothing else, since the ticks cannot reach
///   further back than what they are given;
/// - `6 h reach`, today's rate handed six hours of readings: what a shorter
///   `lookbackLimit` would have done;
/// - `shipped`, today's rate handed readings back to its `lookbackLimit`.
///
/// "Called 0 while rising" is a moment under 0.05%/h whose next stretch rose
/// by more than 0.5%/h: the weekly failure #358 is about.
@Suite("Recent burn replay probe", .enabled(if: ProcessInfo.processInfo.environment["PACER_BURN_REPLAY"] != nil))
struct RecentBurnReplayProbe {

    struct Series {
        let window: String
        let duration: TimeInterval
        var readings: [RecentBurn.Reading]
    }

    /// The rate as it was before #339, kept here as the reference.
    static func legacy(_ readings: [RecentBurn.Reading], now: Date, duration: TimeInterval) -> Double? {
        let cutoff = now.addingTimeInterval(-RecentBurn.defaultLookback)
        let sorted = readings.filter { $0.at >= cutoff }.sorted { $0.at < $1.at }
        guard let newest = sorted.last else { return nil }
        let anchor = newest.resetsAt
        let inCycle = sorted.filter { reading in
            guard let anchor else { return true }
            return RateLimitCycle.contains(sampleReset: reading.resetsAt, resets: anchor, duration: duration)
        }
        guard let first = inCycle.first, inCycle.count >= 2 else { return nil }
        let hours = newest.at.timeIntervalSince(first.at) / 3600
        guard hours > 1.0 / 3600 else { return nil }
        return (newest.percent - first.percent) / hours
    }

    struct Score {
        var moments = 0, negative = 0, zeroWhileRising = 0, rising = 0
        var risingError = 0.0, risingBias = 0.0, heldError = 0.0, heldMean = 0.0, held = 0

        mutating func add(_ estimate: Double, truth: Double) {
            moments += 1
            if estimate < 0 { negative += 1 }
            if truth > 0.5, estimate < RecentBurn.idleBelow { zeroWhileRising += 1 }
            if truth > 0 {
                rising += 1
                risingError += abs(estimate - truth)
                risingBias += estimate - truth
            } else {
                held += 1
                heldError += abs(estimate - truth)
                heldMean += estimate
            }
        }

        var line: String {
            String(format: "n %5d · negative %4d · called 0 while rising %5d of %5d · rising: error %.2f, bias %+.2f · held: mean %.3f",
                   moments, negative, zeroWhileRising, rising,
                   rising > 0 ? risingError / Double(rising) : 0, rising > 0 ? risingBias / Double(rising) : 0,
                   held > 0 ? heldMean / Double(held) : 0)
        }
    }

    static func load(_ path: String) throws -> [Series] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var byKey: [String: Series] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5, let at = Double(f[2]), let percent = Double(f[3]) else { continue }
            let duration: TimeInterval
            switch f[1] {
            case RateLimitWindowName.fiveHour: duration = 5 * 3600
            case RateLimitWindowName.sevenDay: duration = 7 * 86400
            default: continue
            }
            let reading = RecentBurn.Reading(at: Date(timeIntervalSince1970: at), percent: percent,
                                             resetsAt: Double(f[4]).map(Date.init(timeIntervalSince1970:)))
            byKey["\(f[0])|\(f[1])", default: Series(window: f[1], duration: duration, readings: [])]
                .readings.append(reading)
        }
        return byKey.keys.sorted().compactMap { key in
            guard var s = byKey[key] else { return nil }
            s.readings.sort { ($0.at, $0.percent) < ($1.at, $1.percent) }
            return s
        }
    }

    /// First index whose reading is at or after `t`.
    static func lowerBound(_ times: [Date], _ t: Date) -> Int {
        var lo = 0, hi = times.count
        while lo < hi { let mid = (lo + hi) / 2; if times[mid] < t { lo = mid + 1 } else { hi = mid } }
        return lo
    }

    @Test func replaysEveryAccount() throws {
        let series = try Self.load(ProcessInfo.processInfo.environment["PACER_BURN_REPLAY"]!)
        try #require(!series.isEmpty)
        let step: TimeInterval = 600
        for window in [RateLimitWindowName.fiveHour, RateLimitWindowName.sevenDay] {
            for horizon in [1800.0, 7200.0] {
                var scores: [String: Score] = ["legacy": .init(), "half hour": .init(),
                                               "6 h reach": .init(), "shipped": .init()]
                var shippedDiffersFromHalfHour = 0
                for s in series where s.window == window {
                    let times = s.readings.map(\.at)
                    let limit = RecentBurn.lookbackLimit(duration: s.duration)
                    guard let firstAt = times.first, let lastAt = times.last else { continue }
                    var t = firstAt.addingTimeInterval(limit)
                    while t < lastAt.addingTimeInterval(-horizon) {
                        defer { t = t.addingTimeInterval(step) }
                        let i = Self.lowerBound(times, t.addingTimeInterval(0.001))   // readings at or before t
                        guard i > 0, t.timeIntervalSince(times[i - 1]) < 900 else { continue }
                        let j = Self.lowerBound(times, t.addingTimeInterval(horizon + 0.001))
                        let future = Array(s.readings[(i - 1)..<j])
                        // Only a stretch inside one cycle has a climb to score against.
                        guard let a = future.first, let b = future.last, b.at > a.at,
                              RecentBurn.currentCycle(future, duration: s.duration).count == future.count
                        else { continue }
                        let truth = (b.percent - a.percent) / (b.at.timeIntervalSince(a.at) / 3600)
                        let deep = Array(s.readings[Self.lowerBound(times, t.addingTimeInterval(-limit))..<i])
                        let shallow = Array(s.readings[Self.lowerBound(
                            times, t.addingTimeInterval(-RecentBurn.defaultLookback))..<i])
                        let sixHours = Array(s.readings[Self.lowerBound(
                            times, t.addingTimeInterval(-min(limit, 6 * 3600)))..<i])
                        let old = Self.legacy(deep, now: t, duration: s.duration)
                        let six = RecentBurn.percentPerHour(readings: sixHours, now: t, duration: s.duration)
                        let half = RecentBurn.percentPerHour(readings: shallow, now: t, duration: s.duration)
                        let new = RecentBurn.percentPerHour(readings: deep, now: t, duration: s.duration)
                        // Score the moments all three answer, so the rows compare.
                        guard let old, let half, let six, let new else { continue }
                        scores["legacy"]!.add(old, truth: truth)
                        scores["half hour"]!.add(half, truth: truth)
                        scores["6 h reach"]!.add(six, truth: truth)
                        scores["shipped"]!.add(new, truth: truth)
                        if abs(new - half) > 1e-9 { shippedDiffersFromHalfHour += 1 }
                    }
                }
                print("\n=== \(window), scored against the next \(Int(horizon / 60)) minutes")
                for name in ["legacy", "half hour", "6 h reach", "shipped"] {
                    print("    \(name.padding(toLength: 10, withPad: " ", startingAt: 0)) \(scores[name]!.line)")
                }
                print("    shipped differs from half hour at \(shippedDiffersFromHalfHour) moments")
            }
        }
    }
}
