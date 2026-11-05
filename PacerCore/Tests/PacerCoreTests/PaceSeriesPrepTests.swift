import Foundation
import Testing
@testable import PacerCore
@testable import PacerUI

/// The pace card's per-window derivation moved out of its `body` into
/// `PaceSeriesPrep`, built off the main actor (#367). The plotted output must
/// not move by a single point, so `Legacy` below is the derivation exactly as
/// `PaceChartCard.columns(now:)` / `bucketed` / `fixedColumn` / `hasAnyReading`
/// did it in the body, and every case requires the two to be equal.
@Suite("Pace card series prep")
struct PaceSeriesPrepTests {

    // MARK: - The old in-body derivation, kept verbatim as the reference

    enum Legacy {
        struct Bucketed {
            var fiveHour: [LimitSamplePoint] = []
            var sevenDay: [LimitSamplePoint] = []
            var latest: LimitSamplePoint?
            var latestFiveHourAt: Date?
            var latestSevenDayAt: Date?

            var hasNoFiveHourWindow: Bool {
                guard let latest else { return false }
                let cutoff = latest.sampledAt.addingTimeInterval(-2)
                return LimitSamplePoint.hasNoFiveHourWindow(
                    hasFiveHour: (latestFiveHourAt ?? .distantPast) >= cutoff,
                    hasSevenDay: (latestSevenDayAt ?? .distantPast) >= cutoff)
            }
        }

        static func bucketed(_ fixed: [LimitSamplePoint]) -> Bucketed {
            var b = Bucketed()
            for s in fixed {
                if s.window == RateLimitWindowName.fiveHour {
                    b.fiveHour.append(s)
                    if s.sampledAt > (b.latestFiveHourAt ?? .distantPast) { b.latestFiveHourAt = s.sampledAt }
                } else if s.window == RateLimitWindowName.sevenDay {
                    b.sevenDay.append(s)
                    if s.sampledAt > (b.latestSevenDayAt ?? .distantPast) { b.latestSevenDayAt = s.sampledAt }
                }
                if s.sampledAt > (b.latest?.sampledAt ?? .distantPast) { b.latest = s }
            }
            return b
        }

        static func fixedColumn(_ samples: [LimitSamplePoint], duration: TimeInterval, now: Date) -> PaceSeriesPrep.Fixed {
            PaceSeriesPrep.Fixed(
                latest: samples.first,
                recentBurn: RecentBurn.percentPerHour(
                    readings: samples.map { .init(at: $0.sampledAt, percent: $0.usedPercentage, resetsAt: $0.resetsAt) },
                    now: now, duration: duration),
                baseChart: .cycle(fixed: samples, duration: duration, now: now))
        }

        static func derive(fixed: [LimitSamplePoint], scoped: [ScopedSamplePoint],
                           windows: [ScopedWindowRow], now: Date) -> PaceSeriesPrep {
            let b = bucketed(fixed)
            let pollGap = ReadingFreshness.typicalGap(readingTimes: fixed.map(\.sampledAt))
            var scopedOut: [PaceSeriesPrep.Scoped] = []
            for row in windows.latestBatch() {
                let duration = WindowSpec.scopedDuration(group: row.group)
                scopedOut.append(PaceSeriesPrep.Scoped(
                    row: row, duration: duration,
                    recentBurn: RecentBurn.percentPerHour(
                        readings: scoped.filter { $0.identity == row.identity }
                            .map { .init(at: $0.sampledAt, percent: $0.percent, resetsAt: $0.resetsAt) },
                        now: now, duration: duration),
                    baseChart: .cycle(scoped: row, history: scoped, duration: duration, now: now)))
            }
            return PaceSeriesPrep(
                preparedAt: now,
                newestFixedAt: fixed.first?.sampledAt,
                typicalPollGap: pollGap,
                hasNoFiveHourWindow: b.hasNoFiveHourWindow,
                hasReading: b.latest != nil || !windows.latestBatch().isEmpty,
                fiveHour: fixedColumn(b.fiveHour, duration: 5 * 3600, now: now),
                sevenDay: fixedColumn(b.sevenDay, duration: 7 * 86400, now: now),
                scoped: scopedOut)
        }
    }

    // MARK: - Fixtures

    /// Deterministic generator: SplitMix64.
    struct Rand {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    }

    static let now = Date(timeIntervalSince1970: 1_793_500_000)

    struct Account {
        var fixed: [LimitSamplePoint]
        var scoped: [ScopedSamplePoint]
        var windows: [ScopedWindowRow]
        var points: Int { fixed.count + scoped.count }
    }

    /// One account's poll instants over the last eight days, every `step`
    /// seconds with jitter, oldest first. Every window of a poll is written
    /// under the same instant, as the poller does; now and then two lanes
    /// land together and an instant repeats.
    static func timeline(step: TimeInterval, rand: inout Rand) -> [Date] {
        var out: [Date] = []
        var t = now.addingTimeInterval(-8 * 86400)
        while t <= now {
            out.append(t)
            if rand.unit() < 0.03 { out.append(t) }
            t = t.addingTimeInterval(step * (0.8 + 0.4 * rand.unit()))
        }
        out.append(now)
        return out
    }

    /// One window's readings at `times`, newest first. Usage climbs within a
    /// cycle and drops at each reset, and every reading's `resets_at` carries
    /// the server's millisecond jitter (rule 9), so the cycle filter is
    /// exercised. `idleAfter` leaves the reset unanchored from then on (an
    /// idle window).
    static func readings(times: [Date], duration: TimeInterval, firstReset: Date,
                         rand: inout Rand, idleAfter: Date? = nil) -> [(at: Date, pct: Double, resets: Date?)] {
        var out: [(Date, Double, Date?)] = []
        var reset = firstReset
        var pct = 3.0
        for t in times {
            while t >= reset {
                reset = reset.addingTimeInterval(duration)
                pct = 0
            }
            pct = min(100, pct + rand.unit() * 0.4)
            let jitter = (rand.unit() - 0.5) * 0.004
            let idle = idleAfter.map { t > $0 } ?? false
            out.append((t, (pct * 10).rounded() / 10, idle ? nil : reset.addingTimeInterval(jitter)))
        }
        return out.reversed()
    }

    /// The card's load shape: fixed 5-hour over 12 hours, 7-day over 8 days,
    /// scoped over 8 days, all newest first. `scopedIds` are model-scoped
    /// weekly identities. `hasFiveHour == false` is an Ultra account.
    static func account(seed: UInt64, step: TimeInterval, scopedIds: [String],
                        hasFiveHour: Bool = true) -> Account {
        var rand = Rand(state: seed)
        let times = timeline(step: step, rand: &rand)
        var fixed: [LimitSamplePoint] = []
        if hasFiveHour {
            let recent = times.filter { $0 >= now.addingTimeInterval(-12 * 3600) }
            fixed += readings(times: recent, duration: 5 * 3600,
                              firstReset: now.addingTimeInterval(-10.3 * 3600), rand: &rand)
                .map { LimitSamplePoint(sampledAt: $0.at, window: "five_hour", usedPercentage: $0.pct, resetsAt: $0.resets) }
        }
        fixed += readings(times: times, duration: 7 * 86400,
                          firstReset: now.addingTimeInterval(-3 * 86400 + 1234), rand: &rand)
            .map { LimitSamplePoint(sampledAt: $0.at, window: "seven_day", usedPercentage: $0.pct, resetsAt: $0.resets) }
        // Stable on ties, like the loader's merge: 5-hour before 7-day.
        fixed = fixed.enumerated().sorted {
            $0.element.sampledAt != $1.element.sampledAt ? $0.element.sampledAt > $1.element.sampledAt : $0.offset < $1.offset
        }.map(\.element)

        var scoped: [ScopedSamplePoint] = []
        var windows: [ScopedWindowRow] = []
        for (i, id) in scopedIds.enumerated() {
            let rows = readings(times: times, duration: 7 * 86400,
                                firstReset: now.addingTimeInterval(-Double(4 - i) * 86400 + 777), rand: &rand,
                                idleAfter: i == 1 ? now.addingTimeInterval(-3600) : nil)
            scoped += rows.map { ScopedSamplePoint(sampledAt: $0.at, identity: id, percent: $0.pct, resetsAt: $0.resets) }
            // The newest few polls as whole rows, as the loader's
            // `fetchLimit = 120` batch read returns them.
            for r in rows.prefix(3) {
                let label = id.split(separator: "|").dropFirst().first.map(String.init) ?? id
                windows.append(ScopedWindowRow(identity: id, label: label, group: "weekly", percent: r.pct,
                                               resetsAt: r.resets, severity: i == 1 ? "warning" : "normal",
                                               isActive: i == 0, sampledAt: r.at))
            }
        }
        // A limit the server stopped sending a day ago: history, but not in
        // the latest batch, so no column.
        let goneTimes = times.enumerated().filter { $0.offset % 3 == 0 }.map(\.element)
            .filter { $0 < now.addingTimeInterval(-86400) }
        let gone = readings(times: goneTimes, duration: 7 * 86400,
                            firstReset: now.addingTimeInterval(-5 * 86400), rand: &rand)
        scoped += gone.map { ScopedSamplePoint(sampledAt: $0.at, identity: "weekly_scoped|Gone|", percent: $0.pct, resetsAt: $0.resets) }
        if let g = gone.first {
            windows.append(ScopedWindowRow(identity: "weekly_scoped|Gone|", label: "Gone", group: "weekly",
                                           percent: g.pct, resetsAt: g.resets, severity: "normal",
                                           isActive: false, sampledAt: g.at))
        }
        scoped = scoped.enumerated().sorted {
            $0.element.sampledAt != $1.element.sampledAt ? $0.element.sampledAt > $1.element.sampledAt : $0.offset < $1.offset
        }.map(\.element)
        windows.sort { $0.sampledAt > $1.sampledAt }
        return Account(fixed: fixed, scoped: scoped, windows: windows)
    }

    /// The four-account store the issue measured: one account of ~27.5k
    /// points, three of ~3.6k, 38k in all, twelve windows (one account is
    /// Ultra, so it has no 5-hour column). The big account's second scoped
    /// window has gone idle (no reset anchored for the last hour).
    static let store: [Account] = [
        account(seed: 1, step: 84, scopedIds: ["weekly_scoped|Fable|", "weekly_scoped|Opus|"]),
        account(seed: 2, step: 450, scopedIds: ["weekly_scoped|Fable|"]),
        account(seed: 3, step: 450, scopedIds: ["weekly_scoped|Fable|"]),
        account(seed: 4, step: 440, scopedIds: ["weekly_scoped|Fable|"], hasFiveHour: false),
    ]

    static func expectSame(_ a: Account, now: Date, sourceLocation: SourceLocation = #_sourceLocation) {
        let legacy = Legacy.derive(fixed: a.fixed, scoped: a.scoped, windows: a.windows, now: now)
        let prep = PaceSeriesPrep.prepare(fixed: a.fixed, scoped: a.scoped, windows: a.windows, now: now)
        #expect(prep == legacy, sourceLocation: sourceLocation)
        // Field by field too, so a failure says where.
        #expect(prep.fiveHour == legacy.fiveHour, sourceLocation: sourceLocation)
        #expect(prep.sevenDay == legacy.sevenDay, sourceLocation: sourceLocation)
        #expect(prep.scoped == legacy.scoped, sourceLocation: sourceLocation)
        #expect(prep.typicalPollGap == legacy.typicalPollGap, sourceLocation: sourceLocation)
        #expect(prep.hasNoFiveHourWindow == legacy.hasNoFiveHourWindow, sourceLocation: sourceLocation)
        #expect(prep.hasReading == legacy.hasReading, sourceLocation: sourceLocation)
    }

    // MARK: - Equality with the old derivation

    @Test func theStoreTheIssueMeasured() {
        #expect(Self.store.map(\.points).reduce(0, +) > 37_000)
        #expect(Self.store[0].points > 27_000)
        for a in Self.store { Self.expectSame(a, now: Self.now) }
    }

    /// The clock moves the tail and empties the burn rate's half hour; the
    /// line between the readings stays the same.
    @Test func atEveryClockTheCardDrawsAt() {
        let big = Self.store[0]
        for offset: TimeInterval in [0, 30, 59, 61, 45 * 60, 3 * 3600] {
            Self.expectSame(big, now: Self.now.addingTimeInterval(offset))
        }
    }

    /// The decimated line itself, for the 27k-point account: the case the
    /// cap exists for, with the 7-day cycle reset inside the eight days.
    @Test func aDecimatedLineWithAResetInside() throws {
        let big = Self.store[0]
        let prep = PaceSeriesPrep.prepare(fixed: big.fixed, scoped: big.scoped, windows: big.windows, now: Self.now)
        let week = try #require(prep.sevenDay.baseChart)
        let raw = big.fixed.filter { $0.window == "seven_day" && $0.sampledAt >= week.cycleStart }.count
        #expect(raw > PaceChartView.Data.plotPointCap)
        #expect(week.points.count <= PaceChartView.Data.plotPointCap + 3)
        // The line starts after the reset: nothing from the previous cycle.
        #expect(week.points.allSatisfy { $0.time >= week.cycleStart })
        #expect(big.fixed.contains { $0.window == "seven_day" && $0.sampledAt < week.cycleStart })
        let legacy = Legacy.derive(fixed: big.fixed, scoped: big.scoped, windows: big.windows, now: Self.now)
        #expect(week.points == legacy.sevenDay.baseChart?.points)
    }

    @Test func scopedColumnsInLatestBatchOrder() {
        let big = Self.store[0]
        let prep = PaceSeriesPrep.prepare(fixed: big.fixed, scoped: big.scoped, windows: big.windows, now: Self.now)
        #expect(prep.scoped.map(\.row.identity) == big.windows.latestBatch().map(\.identity))
        #expect(!prep.scoped.contains { $0.row.identity == "weekly_scoped|Gone|" })
        // The idle one (no reset anchored) has no line; the other has one.
        #expect(prep.scoped.map { $0.baseChart != nil } == [true, false])
    }

    @Test func anUltraAccountHasNoFiveHourWindow() {
        let ultra = Self.store[3]
        let prep = PaceSeriesPrep.prepare(fixed: ultra.fixed, scoped: ultra.scoped, windows: ultra.windows, now: Self.now)
        #expect(prep.hasNoFiveHourWindow)
        #expect(prep.fiveHour.latest == nil)
        Self.expectSame(ultra, now: Self.now)
    }

    /// An idle window (no reset anchored) and an account with nothing loaded.
    @Test func idleAndEmpty() {
        let idle = Self.store[0].scoped.filter { $0.identity == "weekly_scoped|Fable|" }
        let rows = Self.store[0].windows.filter { $0.identity == "weekly_scoped|Fable|" }
            .map { ScopedWindowRow(identity: $0.identity, label: $0.label, group: $0.group, percent: $0.percent,
                                   resetsAt: nil, severity: $0.severity, isActive: $0.isActive, sampledAt: $0.sampledAt) }
        Self.expectSame(Account(fixed: [], scoped: idle, windows: rows), now: Self.now)
        Self.expectSame(Account(fixed: [], scoped: [], windows: []), now: Self.now)
        let empty = PaceSeriesPrep.prepare(fixed: [], scoped: [], windows: [], now: Self.now)
        #expect(!empty.hasReading)
    }

    // MARK: - Bench (PACER_BENCH=1 swift test --filter PaceSeriesPrepTests)

    /// Old: what every body pass did on the main thread (the derivation for
    /// each account, plus `hasAnyReading`'s bucketing of the first). New: the
    /// same values built once, off the main actor; the body then only looks
    /// them up.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PACER_BENCH"] != nil))
    func bench() {
        let clock = ContinuousClock()
        func ms(_ d: Duration) -> Double {
            Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }
        func median(_ v: [Double]) -> Double { let s = v.sorted(); return s[s.count / 2] }
        let runs = Int(ProcessInfo.processInfo.environment["PACER_BENCH_RUNS"] ?? "") ?? 15
        var legacy: [Double] = [], prep: [Double] = []
        var sink = 0
        for i in 0..<runs {
            let now = Self.now.addingTimeInterval(Double(i))
            let a = clock.measure {
                for acct in Self.store {
                    let d = Legacy.derive(fixed: acct.fixed, scoped: acct.scoped, windows: acct.windows, now: now)
                    sink &+= d.sevenDay.baseChart?.points.count ?? 0
                }
                sink &+= Legacy.bucketed(Self.store[0].fixed).latest == nil ? 0 : 1
            }
            let b = clock.measure {
                for acct in Self.store {
                    let d = PaceSeriesPrep.prepare(fixed: acct.fixed, scoped: acct.scoped, windows: acct.windows, now: now)
                    sink &+= d.sevenDay.baseChart?.points.count ?? 0
                }
            }
            legacy.append(ms(a)); prep.append(ms(b))
        }
        let points = Self.store.map(\.points).reduce(0, +)
        let windows = Self.store.map { a -> Int in
            let p = PaceSeriesPrep.prepare(fixed: a.fixed, scoped: a.scoped, windows: a.windows, now: Self.now)
            return (p.hasNoFiveHourWindow ? 1 : 2) + p.scoped.count
        }.reduce(0, +)
        #if DEBUG
        let config = "debug"
        #else
        let config = "release"
        #endif
        print("[bench] pace card prep (\(config)), \(points) points, \(Self.store.count) accounts, \(windows) windows, "
              + "\(runs) runs: old in-body derivation median \(String(format: "%.1f", median(legacy))) ms "
              + "(max \(String(format: "%.1f", legacy.max() ?? 0))), "
              + "new prep median \(String(format: "%.1f", median(prep))) ms "
              + "(max \(String(format: "%.1f", prep.max() ?? 0))) [sink \(sink)]")
        #expect(sink > 0)
    }
}
