import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// Which estimate between readings is least biased (#318 part B). Opt-in, on a
/// COPY of a real store, like `LiveMeterProbe`:
///
///     PACER_LIVE_PROBE=/path/to/copy/pacer.sqlite swift test --filter LiveMeterEstimatorProbe
///
/// The drift log on a one-login account showed the floored fill exact 6
/// times, a point low 13 times, 2–3 low twice and never high: flooring
/// `reading + k·spend` from a whole-number reading throws away where the meter
/// sat inside that point. Each candidate estimates that fraction (the carry)
/// at the reading and floors `reading + carry + k·spend`, or rounds:
///
/// - `floor`: no carry (part A). `floor+0.2`: a fixed nudge instead.
/// - `round`: no carry, the sum rounded.
/// - `tick-half`: at the reading where the meter last went up, half the spend
///   between the two polls (up to a point) had gone past the new whole point;
///   flat readings since add their spend, below a point.
/// - `interval-*`: `LiveMeter.carry` — the bounds on the true meter carried
///   from reading to reading — at the low end, the middle, and as shipped (a
///   quarter of the way up, movement at half weight).
/// - `bayes`: a 40-bin posterior of the fraction, carried with a 50% relative
///   rate error, at its 30th percentile.
///
/// Scored like `LiveMeterProbe`: one reading per 5 minutes kept, a fit per
/// day from the 14 before, every thinned-away reading scored against what
/// would be on screen, banded by the gate's burn. Plus the drift log's own
/// view: the value just before each kept reading with spend since the last,
/// against that reading, and how often the number steps back down at it.
@Suite("Live meter estimator probe", .enabled(if: ProcessInfo.processInfo.environment["PACER_LIVE_PROBE"] != nil))
struct LiveMeterEstimatorProbe {

    enum Estimator: String, CaseIterable {
        case floor, nudge = "floor+0.2", round, tickHalf = "tick-half",
             intervalLo = "interval-lo", intervalMid = "interval-mid", bayes = "bayes σ.5 q.3", shipped
    }

    @Test func compareEstimators() async throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PACER_LIVE_PROBE"]!)
        try #require(!url.standardizedFileURL.path.contains("/Group Containers/"),
                     "point PACER_LIVE_PROBE at a copy, not the live store")
        let container = try ModelContainer(for: Schema(PacerStore.allModelTypes),
                                           configurations: ModelConfiguration(url: url))
        try await Task.detached {
            let context = ModelContext(container)
            let pricing = PricingTable.Snapshot(pricingByModel: [:],
                                                ledger: try PriceLedgerStore.load(context: context))
            for key in [RateLimitWindowName.fiveHour, RateLimitWindowName.sevenDay] {
                try Self.compare(window: key, container: container, storeURL: url, pricing: pricing)
            }
        }.value
    }

    /// What the app's board and the comparison sheet's agreement line cost
    /// on the copy, at the copy's newest reading: every account's live
    /// values (fits, an hour of readings per window, the turns since), and
    /// today's agreement for each account's 5-hour window.
    @Test func boardAndAgreementCost() async throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PACER_LIVE_PROBE"]!)
        try #require(!url.standardizedFileURL.path.contains("/Group Containers/"),
                     "point PACER_LIVE_PROBE at a copy, not the live store")
        let container = try ModelContainer(for: Schema(PacerStore.allModelTypes),
                                           configurations: ModelConfiguration(url: url))
        try await Task.detached {
            let context = ModelContext(container)
            var newest = FetchDescriptor<RateLimitSample>(sortBy: [SortDescriptor(\.sampledAt, order: .reverse)])
            newest.fetchLimit = 1
            let now = try #require(try context.fetch(newest).first?.sampledAt).addingTimeInterval(60)
            for pass in 1...3 {
                let started = Date()
                let board = LiveMeterBoard.build(container: container, now: now)
                let ms = Date().timeIntervalSince(started) * 1000
                let text = board.keys.sorted().map { a in
                    a.suffix(4) + ": " + board[a]!.keys.sorted().map { k in
                        let v = board[a]![k]!
                        return String(format: "%@ %.0f→%.0f (carry %.2f)", k, v.reading.percent, v.percent, v.carry)
                    }.joined(separator: ", ")
                }.joined(separator: " | ")
                print(String(format: "board build %d: %.1f ms · %@", pass, ms, text))
            }
            let accounts = try context.fetch(FetchDescriptor<Account>()).map(\.id).sorted()
            for a in accounts {
                let started = Date()
                let agreement = LiveMeterDrift.agreement(
                    context: ModelContext(container), account: a, window: RateLimitWindowName.fiveHour,
                    since: Calendar.current.startOfDay(for: now), now: now)
                print(String(format: "agreement %@: %@ · %.1f ms", String(a.suffix(4)),
                             agreement.map { "\($0.withinOne) of \($0.pairs) within a point" } ?? "none",
                             Date().timeIntervalSince(started) * 1000))
            }
        }.value
    }

    struct Scored {
        let truth: Double
        let shown: [Estimator: Double]
        let burn: Double?
    }

    static func compare(window key: String, container: ModelContainer, storeURL: URL,
                        pricing: PricingTable.Snapshot) throws {
        let context = ModelContext(container)
        let duration = PaceMath.windowDuration(for: key)!
        let since = LiveMeterProbe.since
        let (account, all) = try LiveMeterProbe.busiestAccount(window: key, context: context, storeURL: storeURL)
        let readings = all.filter { $0.at <= LiveMeterProbe.span.end }
        guard let last = readings.last else { return }

        var keep = [Bool](repeating: false, count: readings.count)
        var lastKept = -Double.infinity
        for (i, r) in readings.enumerated() where r.at.timeIntervalSince1970 - lastKept >= LiveMeterProbe.thin {
            keep[i] = true
            lastKept = r.at.timeIntervalSince1970
        }
        let kept = readings.indices.filter { keep[$0] }.map { readings[$0] }
        let keptTimes = kept.map(\.at)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let fromKey = TokenSample.formatDate(since.addingTimeInterval(-15 * 86_400))
        let hourly = try context.fetch(FetchDescriptor<AccountHourlyAggregate>(
            predicate: #Predicate { $0.accountId == account && $0.date >= fromKey }))
            .map { HourlySpend(date: $0.date, hour: $0.hour, model: $0.model, costUSD: $0.totalCostUSD) }
        var rates: [String: LiveMeterRates] = [:]
        var day = calendar.startOfDay(for: since)
        while day <= last.at {
            let span = SpendMeterFitter.span(endingAtStartOf: day, calendar: calendar)
            let lo = span.start.addingTimeInterval(-SpendMeterFitter.maxPairGap)
            let hi = span.end.addingTimeInterval(SpendMeterFitter.maxPairGap)
            let a = TokenSample.formatDate(span.start), b = TokenSample.formatDate(span.end)
            if case .fitted(let fit) = SpendMeterFitter.fit(
                accountId: account, window: key, duration: duration,
                readings: kept.filter { $0.at >= lo && $0.at < hi },
                spend: hourly.filter { $0.date >= a && $0.date <= b },
                span: span, timeZone: .current) {
                let dayKey = TokenSample.formatDate(day)
                rates[dayKey] = LiveMeterRates(modelRates: fit.modelRates, pooledRate: fit.pooledRate,
                                               fittedDay: dayKey)
            }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }

        var spend: [LiveSpend] = []
        let spendFrom = since.addingTimeInterval(-86_400)
        try ModelWalk.forEach(FetchDescriptor<TokenSample>(
            predicate: #Predicate { $0.accountId == account && $0.sampledAt >= spendFrom },
            sortBy: [SortDescriptor(\.sampledAt)]), in: container) { s in
            spend.append(LiveSpend(at: s.sampledAt, model: s.model,
                                   costUSD: CostCalculator.cost(s, mode: .auto, snapshot: pricing)))
        }
        let spendTimes = spend.map(\.at)
        func slice(after a: Date, through b: Date) -> [LiveSpend] {
            Array(spend[LiveMeterProbe.upperBound(spendTimes, a)..<LiveMeterProbe.upperBound(spendTimes, b)])
        }
        func points(_ r: LiveMeterRates, after a: Date, through b: Date) -> Double {
            slice(after: a, through: b).reduce(0.0) { $0 + r.rate(for: $1.model).rate * $1.costUSD }
        }

        // The carry at every kept reading, per candidate.
        var carry: [Estimator: [Double]] = [:]
        for e in Estimator.allCases { carry[e] = [Double](repeating: 0, count: kept.count) }
        let bins = 40
        let uniform = [Double](repeating: 1.0 / Double(bins), count: bins)
        var posterior = uniform
        let nodes: [(z: Double, w: Double)] = [(-2, 0.054), (-1, 0.244), (0, 0.404), (1, 0.244), (2, 0.054)]
        var riseSum = 0.0, movedSum = 0.0
        for j in kept.indices {
            let r = kept[j], p = r.percent
            guard let dayRates = rates[TokenSample.formatDate(r.at)] else { continue }
            // The shipped carry and its two siblings, from the hour before.
            let low = LiveMeterProbe.lowerBound(keptTimes, r.at.addingTimeInterval(-LiveMeter.carryLookback))
            let history = Array(kept[min(low, j)...j])
            let hs = slice(after: history[0].at, through: r.at)
            carry[.shipped]![j] = LiveMeter.carry(readings: history, duration: duration, rates: dayRates, spend: hs)
            carry[.intervalLo]![j] = LiveMeter.carry(readings: history, duration: duration, rates: dayRates,
                                                     spend: hs, position: 0, movedWeight: 1)
            carry[.intervalMid]![j] = LiveMeter.carry(readings: history, duration: duration, rates: dayRates,
                                                      spend: hs, position: 0.5, movedWeight: 1)
            let chained = j > 0 && LiveMeter.sameCycle(kept[j - 1], r, duration: duration)
                && r.at.timeIntervalSince(kept[j - 1].at) <= SpendMeterFitter.maxPairGap && p >= kept[j - 1].percent
            let moved = chained ? points(dayRates, after: kept[j - 1].at, through: r.at) : 0
            if chained, moved > 0.05 {
                riseSum += p - kept[j - 1].percent
                movedSum += moved
            }
            // Tick-anchored.
            if chained {
                carry[.tickHalf]![j] = p > kept[j - 1].percent
                    ? min(moved, 1) / 2 : min(carry[.tickHalf]![j - 1] + moved, 0.99)
            }
            // Bayes.
            if chained {
                let prevP = kept[j - 1].percent
                var next = [Double](repeating: 0, count: bins)
                for (b, x) in posterior.enumerated() where x > 0 {
                    let f = (Double(b) + 0.5) / Double(bins)
                    for n in nodes {
                        let t = prevP + f + moved * max(0, 1 + 0.5 * n.z) - p
                        guard t >= 0, t < 1 else { continue }
                        next[min(bins - 1, Int(t * Double(bins)))] += x * n.w
                    }
                }
                let total = next.reduce(0, +)
                posterior = total > 0 ? next.map { $0 / total } : uniform
            } else {
                posterior = uniform
            }
            var acc = 0.0, q = 1 - 1e-6
            for (b, x) in posterior.enumerated() {
                if acc + x >= 0.3 { q = (Double(b) + (0.3 - acc) / max(x, 1e-12)) / Double(bins); break }
                acc += x
            }
            carry[.bayes]![j] = q
        }

        func shown(_ e: Estimator, j: Int, at t: Date, rates dayRates: LiveMeterRates) -> Double {
            let k = kept[j]
            guard let v = LiveMeter.value(reading: k, duration: duration, rates: dayRates,
                                          spend: slice(after: k.at, through: t), now: t) else { return k.percent }
            if v.restarted { return v.percent }
            func capped(_ added: Double) -> Double { max(k.percent, min(100, k.percent + max(0, added))) }
            switch e {
            case .floor: return v.percent
            case .nudge: return capped((v.exactAdded + 0.2).rounded(.down))
            case .round: return capped(v.exactAdded.rounded())
            default: return capped((carry[e]![j] + v.exactAdded + 1e-9).rounded(.down))
            }
        }

        // Moments: every thinned-away reading.
        var moments: [Scored] = []
        for (i, d) in readings.enumerated() where !keep[i] && d.at >= since {
            guard let j = LiveMeterProbe.lastIndex(keptTimes, atOrBefore: d.at),
                  let dayRates = rates[TokenSample.formatDate(d.at)] else { continue }
            let k = kept[j]
            if let r = d.resetsAt, let kr = k.resetsAt, d.at < kr,
               !RateLimitCycle.contains(sampleReset: r, resets: kr, duration: duration) { continue }
            var s: [Estimator: Double] = [:]
            for e in Estimator.allCases { s[e] = shown(e, j: j, at: d.at, rates: dayRates) }
            let gate = kept[min(j, LiveMeterProbe.lowerBound(keptTimes, d.at.addingTimeInterval(-1800)))...j]
                .map { RecentBurn.Reading(at: $0.at, percent: $0.percent, resetsAt: $0.resetsAt) }
            moments.append(Scored(truth: d.percent, shown: s,
                                  burn: RecentBurn.percentPerHour(readings: Array(gate), now: d.at, duration: duration)))
        }
        // The drift log's view: the value just before each kept reading.
        var pairs: [Scored] = []
        for j in kept.indices.dropLast() where kept[j + 1].at >= since {
            let next = kept[j + 1]
            guard let dayRates = rates[TokenSample.formatDate(next.at)],
                  points(dayRates, after: kept[j].at, through: next.at) > 0 else { continue }
            if let r = next.resetsAt, let kr = kept[j].resetsAt, next.at < kr,
               !RateLimitCycle.contains(sampleReset: r, resets: kr, duration: duration) { continue }
            let t = next.at.addingTimeInterval(-0.001)
            var s: [Estimator: Double] = [:]
            for e in Estimator.allCases { s[e] = shown(e, j: j, at: t, rates: dayRates) }
            let gate = kept[min(j, LiveMeterProbe.lowerBound(keptTimes, next.at.addingTimeInterval(-1800)))...j]
                .map { RecentBurn.Reading(at: $0.at, percent: $0.percent, resetsAt: $0.resetsAt) }
            pairs.append(Scored(truth: next.percent, shown: s,
                                burn: RecentBurn.percentPerHour(readings: Array(gate), now: t, duration: duration)))
        }

        print(String(format: "\nrise over busy pairs: %.0f points read against %.0f predicted (ratio %.2f)",
                     riseSum, movedSum, riseSum / max(movedSum, 1e-9)))
        print("=== \(key) · account \(account.suffix(4)) · \(moments.count) moments, \(pairs.count) busy pairs (one reading per \(Int(LiveMeterProbe.thin / 60)) min)")
        let bands: [(String, (Double?) -> Bool)] = [
            ("any", { _ in true }),
            ("under 20/h", { $0.map { $0 < 20 } ?? false }),
            ("20–40/h", { $0.map { $0 >= 20 && $0 < 40 } ?? false }),
            ("40+/h", { $0.map { $0 >= 40 } ?? false }),
        ]
        for (name, sel) in bands {
            let ms = moments.filter { sel($0.burn) }
            let ps = pairs.filter { sel($0.burn) }
            guard ms.count >= 20 else { continue }
            print("  \(name): \(ms.count) moments, \(ps.count) pairs")
            for e in Estimator.allCases {
                let err = ms.map { $0.shown[e]! - $0.truth }
                let abs = err.map(Swift.abs)
                let pe = ps.map { $0.shown[e]! - $0.truth }
                func pct(_ n: Int, _ of: Int) -> Double { of == 0 ? 0 : 100 * Double(n) / Double(of) }
                print(String(format: "    %-13@ mean|err| %.3f  bias %+.3f  2+ off %4.1f%%  high %4.1f%%  |  at the next reading: exact %5.1f%%  1 low %5.1f%%  2+ low %4.1f%%  steps down %4.1f%%",
                             e.rawValue as NSString, LiveMeterProbe.mean(abs), LiveMeterProbe.mean(err),
                             pct(abs.filter { $0 >= 2 }.count, abs.count),
                             pct(err.filter { $0 > 0 }.count, err.count),
                             pct(pe.filter { $0 == 0 }.count, pe.count),
                             pct(pe.filter { $0 == -1 }.count, pe.count),
                             pct(pe.filter { $0 <= -2 }.count, pe.count),
                             pct(pe.filter { $0 > 0 }.count, pe.count)))
            }
        }
    }
}

/// How weak a fit can be before its live value is worse than the reading
/// (#318 part B). Opt-in on a store copy, like the probes above.
///
/// Strong fits are the norm for the fixed windows (14 days, hundreds of
/// points of rise, R² over 0.9), so weak ones are made on purpose: the same
/// replay with the fit's span cut to 2, 3 and 7 days, which lowers the rise
/// and the R² the way a quiet fortnight or a new login does. The scoped
/// per-model caps (the Fable weekly) are fitted the ordinary way: they are
/// the weak fits that exist. Every thinned-away reading where the live value
/// added spend is scored against the held reading, bucketed by the day's
/// fit's total rise and R².
@Suite("Live meter weak-fit probe", .enabled(if: ProcessInfo.processInfo.environment["PACER_LIVE_PROBE"] != nil))
struct LiveMeterWeakFitProbe {

    struct Moment {
        let rise: Double
        let r2: Double
        let truth: Double
        let hold: Double
        let live: Double
    }

    @Test func weakFits() async throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PACER_LIVE_PROBE"]!)
        try #require(!url.standardizedFileURL.path.contains("/Group Containers/"),
                     "point PACER_LIVE_PROBE at a copy, not the live store")
        let container = try ModelContainer(for: Schema(PacerStore.allModelTypes),
                                           configurations: ModelConfiguration(url: url))
        try await Task.detached {
            let context = ModelContext(container)
            let pricing = PricingTable.Snapshot(pricingByModel: [:],
                                                ledger: try PriceLedgerStore.load(context: context))
            let accounts = try context.fetch(FetchDescriptor<Account>()).map(\.id)
                .filter { $0 != AccountDailyAggregate.unattributedKey }.sorted()
            var all: [Moment] = []
            var scoped: [Moment] = []
            for account in accounts {
                let since = LiveMeterProbe.since.addingTimeInterval(-15 * 86_400)
                let rows = RawLimitReader.rateRows(storeURL: url, account: account, since: since) ?? []
                for key in [RateLimitWindowName.fiveHour, RateLimitWindowName.sevenDay] {
                    let readings = rows.filter { $0.window == key }
                        .map { MeterReading(at: $0.at, percent: $0.usedPercentage, resetsAt: $0.resetsAt) }
                        .sorted { ($0.at, $0.percent) < ($1.at, $1.percent) }
                    for days in [2, 3, 7, 14] {
                        all += try Self.replay(account: account, window: key, readings: readings,
                                               duration: PaceMath.windowDuration(for: key)!, spanDays: days,
                                               counts: nil, container: container, pricing: pricing)
                    }
                }
                let srows = RawLimitReader.scopedRows(storeURL: url, account: account, since: since) ?? []
                let ids = Set(srows.filter { ($0.modelId ?? $0.modelDisplayName ?? "").isEmpty == false }.map(\.identity))
                for id in ids.sorted() {
                    let mine = srows.filter { $0.identity == id }
                    let readings = mine.map { MeterReading(at: $0.at, percent: $0.usedPercentage, resetsAt: $0.resetsAt) }
                        .sorted { ($0.at, $0.percent) < ($1.at, $1.percent) }
                    let counts = SpendMeterFitter.capCounts(
                        modelId: mine.last { $0.modelId?.isEmpty == false }?.modelId,
                        displayName: mine.last { $0.modelDisplayName?.isEmpty == false }?.modelDisplayName)
                    let m = try Self.replay(account: account, window: id, readings: readings,
                                            duration: WindowSpec.scopedDuration(group: mine.last?.group ?? ""),
                                            spanDays: 14, counts: counts, container: container, pricing: pricing)
                    print("scoped \(id) · \(account.suffix(4)): \(readings.count) readings, \(m.count) busy moments")
                    scoped += m
                }
            }
            Self.report("fixed windows, spans 2–14 days", all)
            Self.report("scoped per-model caps, 14 days", scoped)
        }.value
    }

    static func report(_ title: String, _ ms: [Moment]) {
        print("\n=== \(title): \(ms.count) moments where the live value added spend")
        func line(_ name: String, _ sel: (Moment) -> Bool) {
            let xs = ms.filter(sel)
            guard !xs.isEmpty else { print("  \(name): none"); return }
            let h = xs.map { abs($0.truth - $0.hold) }
            let l = xs.map { abs($0.truth - $0.live) }
            func pct(_ n: Int) -> Double { 100 * Double(n) / Double(xs.count) }
            print(String(format: "  %-22@ n=%6d  held mean|err| %.3f, 2+ %4.1f%%  |  live mean|err| %.3f, 2+ %4.1f%%, high %4.1f%%, worse than held %4.1f%%",
                         name as NSString, xs.count, LiveMeterProbe.mean(h), pct(h.filter { $0 >= 2 }.count),
                         LiveMeterProbe.mean(l), pct(l.filter { $0 >= 2 }.count),
                         pct(xs.filter { $0.live > $0.truth }.count),
                         pct(xs.indices.filter { l[$0] > h[$0] }.count)))
        }
        for (lo, hi) in [(0.0, 10.0), (10, 20), (20, 40), (40, 80), (80, 160), (160, 1e9)] {
            line("rise \(Int(lo))–\(hi > 1e8 ? "" : String(Int(hi)))", { $0.rise >= lo && $0.rise < hi })
        }
        for (lo, hi) in [(-1e9, 0.5), (0.5, 0.7), (0.7, 0.8), (0.8, 0.9), (0.9, 2.0)] {
            line(String(format: "R² %.1f–%.1f", max(lo, 0), min(hi, 1)), { $0.r2 >= lo && $0.r2 < hi })
        }
        for (rise, r2) in [(20.0, 0.0), (40, 0), (20, 0.5), (20, 0.7), (40, 0.7), (40, 0.8)] {
            line(String(format: "kept: rise≥%.0f R²≥%.1f", rise, r2), { $0.rise >= rise && $0.r2 >= r2 })
            line(String(format: "cut:  rise<%.0f or R²<%.1f", rise, r2), { $0.rise < rise || $0.r2 < r2 })
        }
    }

    static func replay(account: String, window key: String, readings all: [MeterReading],
                       duration: TimeInterval, spanDays: Int, counts: (@Sendable (String) -> Bool)?,
                       container: ModelContainer, pricing: PricingTable.Snapshot) throws -> [Moment] {
        let context = ModelContext(container)
        let since = LiveMeterProbe.since
        let readings = all.filter { $0.at <= LiveMeterProbe.span.end }
        guard let last = readings.last, readings.count > 50 else { return [] }
        var keep = [Bool](repeating: false, count: readings.count)
        var lastKept = -Double.infinity
        for (i, r) in readings.enumerated() where r.at.timeIntervalSince1970 - lastKept >= LiveMeterProbe.thin {
            keep[i] = true
            lastKept = r.at.timeIntervalSince1970
        }
        let kept = readings.indices.filter { keep[$0] }.map { readings[$0] }
        let keptTimes = kept.map(\.at)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let fromKey = TokenSample.formatDate(since.addingTimeInterval(-15 * 86_400))
        let hourly = try context.fetch(FetchDescriptor<AccountHourlyAggregate>(
            predicate: #Predicate { $0.accountId == account && $0.date >= fromKey }))
            .filter { counts?($0.model) ?? true }
            .map { HourlySpend(date: $0.date, hour: $0.hour, model: $0.model, costUSD: $0.totalCostUSD) }
        var fits: [String: (rates: LiveMeterRates, rise: Double, r2: Double)] = [:]
        var day = calendar.startOfDay(for: since)
        while day <= last.at {
            let end = calendar.startOfDay(for: day)
            let span = DateInterval(start: calendar.date(byAdding: .day, value: -spanDays, to: end)!, end: end)
            let lo = span.start.addingTimeInterval(-SpendMeterFitter.maxPairGap)
            let hi = span.end.addingTimeInterval(SpendMeterFitter.maxPairGap)
            let a = TokenSample.formatDate(span.start), b = TokenSample.formatDate(span.end)
            if case .fitted(let fit) = SpendMeterFitter.fit(
                accountId: account, window: key, duration: duration,
                readings: kept.filter { $0.at >= lo && $0.at < hi },
                spend: hourly.filter { $0.date >= a && $0.date <= b },
                span: span, timeZone: .current, counts: counts) {
                fits[TokenSample.formatDate(day)] = (LiveMeterRates(modelRates: fit.modelRates, pooledRate: fit.pooledRate),
                                                     fit.totalRise, fit.r2)
            }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        guard !fits.isEmpty else { return [] }
        var spend: [LiveSpend] = []
        let spendFrom = since.addingTimeInterval(-86_400)
        try ModelWalk.forEach(FetchDescriptor<TokenSample>(
            predicate: #Predicate { $0.accountId == account && $0.sampledAt >= spendFrom },
            sortBy: [SortDescriptor(\.sampledAt)]), in: container) { s in
            spend.append(LiveSpend(at: s.sampledAt, model: s.model,
                                   costUSD: CostCalculator.cost(s, mode: .auto, snapshot: pricing)))
        }
        let spendTimes = spend.map(\.at)
        var out: [Moment] = []
        for (i, d) in readings.enumerated() where !keep[i] && d.at >= since {
            guard let j = LiveMeterProbe.lastIndex(keptTimes, atOrBefore: d.at),
                  let fit = fits[TokenSample.formatDate(d.at)] else { continue }
            let k = kept[j]
            if let r = d.resetsAt, let kr = k.resetsAt, d.at < kr,
               !RateLimitCycle.contains(sampleReset: r, resets: kr, duration: duration) { continue }
            let lowJ = LiveMeterProbe.lowerBound(keptTimes, k.at.addingTimeInterval(-LiveMeter.carryLookback))
            let history = Array(kept[min(lowJ, j)...j])
            let carry = LiveMeter.carry(
                readings: history, duration: duration, rates: fit.rates,
                spend: Array(spend[LiveMeterProbe.upperBound(spendTimes, history[0].at)..<LiveMeterProbe.upperBound(spendTimes, k.at)]),
                counts: counts)
            let slice = Array(spend[LiveMeterProbe.upperBound(spendTimes, k.at)..<LiveMeterProbe.upperBound(spendTimes, d.at)])
            guard let v = LiveMeter.value(reading: k, duration: duration, rates: fit.rates, spend: slice,
                                          counts: counts, carry: carry, now: d.at),
                  v.spendUSD > 0 else { continue }
            out.append(Moment(rise: fit.rise, r2: fit.r2, truth: d.percent, hold: k.percent, live: v.percent))
        }
        return out
    }
}
