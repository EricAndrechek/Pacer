import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// The live meter (#318) replayed on a COPY of a real store. Opt-in:
///
///     mkdir -p /tmp/liveprobe && cp -c ~/Library/Group\ Containers/…/pacer.sqlite* /tmp/liveprobe/
///     PACER_LIVE_PROBE=/tmp/liveprobe/pacer.sqlite swift test --package-path PacerCore --filter LiveMeterProbe
///
/// The Swift side of `research/lab/tokens/live_meter.py`'s one-login replay
/// (section 3), on the same method:
///
/// 1. Take the account with the most readings of the window since
///    2026-09-01 and thin them to one per 5 minutes, which is what a
///    one-login user's Pacer reads (`OAuthPollScheduler.perTokenMinInterval`).
/// 2. Refit the rates each local day from the 14 days before it, on the
///    thinned readings, exactly as the daily job would (`SpendMeterFitter`).
/// 3. At every real reading that was thinned away, score what would have been
///    on screen against it: the last kept reading (today), and the live value
///    built on that reading from the turns since (`LiveMeter.value`).
///    Run twice: on the harness's readings (those with a reset; moments whose
///    kept reading is in another cycle left out, as the harness leaves them
///    out), and on every reading Pacer holds, the post-reset 0% ones and the
///    moments across a reset included.
/// 4. Band the moments by how fast the meter climbs: the harness's way
///    (rate × spend over the last 30 minutes) for parity, and the way the
///    `pacer` gate sees it (`RecentBurn` over the kept readings), which is
///    what the gate's padding is chosen from.
///
/// Also checks the cost basis: the turns priced the way `LiveMeterSource`
/// prices them, summed per hour, against `AccountHourlyAggregate`, which is
/// what the fit was made on. And times the snapshot's live reads per account.
///
/// Writes the day's fits into the copy (the live store is refused).
@Suite("Live meter replay probe", .enabled(if: ProcessInfo.processInfo.environment["PACER_LIVE_PROBE"] != nil))
struct LiveMeterProbe {

    /// The harness's `SINCE`: dense readings (many logins) from here on.
    /// `PACER_LIVE_PROBE_SPAN=2026-09-18T00:00:00Z...2026-10-20T22:34:07Z`
    /// scores another span (UTC instants), e.g. the frozen lab data's, whose
    /// readings before 09-18 the live table has handed to the archive.
    static let span: (since: Date, end: Date) = {
        let iso = ISO8601DateFormatter()
        guard let spec = ProcessInfo.processInfo.environment["PACER_LIVE_PROBE_SPAN"] else {
            return (iso.date(from: "2026-09-01T00:00:00Z")!, .distantFuture)
        }
        let parts = spec.components(separatedBy: "...")
        return (iso.date(from: parts[0])!, iso.date(from: parts[1])!)
    }()
    static var since: Date { span.since }
    /// Build the live value this many seconds before the moment it is scored
    /// at, as a snapshot that old would show it: `PACER_LIVE_PROBE_LAG=15`.
    static let lag: TimeInterval = ProcessInfo.processInfo.environment["PACER_LIVE_PROBE_LAG"]
        .flatMap(TimeInterval.init) ?? 0
    /// One reading per this many seconds: a one-login Pacer's poll while
    /// active. `PACER_LIVE_PROBE_THIN=600` replays the idle cadence.
    static let thin: TimeInterval = ProcessInfo.processInfo.environment["PACER_LIVE_PROBE_THIN"]
        .flatMap(TimeInterval.init) ?? 300

    @Test func replaysOneLogin() async throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PACER_LIVE_PROBE"]!)
        try #require(!url.standardizedFileURL.path.contains("/Group Containers/"),
                     "point PACER_LIVE_PROBE at a copy, not the live store")
        let container = try ModelContainer(for: Schema(PacerStore.allModelTypes),
                                           configurations: ModelConfiguration(url: url))
        try await Task.detached {
            let context = ModelContext(container)
            let pricing = PricingTable.Snapshot(pricingByModel: [:],
                                                ledger: try PriceLedgerStore.load(context: context))
            let mode = try Self.costBasis(container: container, pricing: pricing)
            for key in [RateLimitWindowName.fiveHour, RateLimitWindowName.sevenDay] {
                // The harness's data: readings with no reset are not in it
                // (`rate_samples_by_account` reads `ZRESETSAT IS NOT NULL`).
                try Self.replay(window: key, container: container, storeURL: url, mode: mode,
                                pricing: pricing, everyReading: false)
                // What Pacer actually holds: the post-reset 0% readings too,
                // and every moment scored, resets and new windows included.
                try Self.replay(window: key, container: container, storeURL: url, mode: mode,
                                pricing: pricing, everyReading: true)
            }
            try await Self.timeSnapshotReads(container: container, mode: mode, pricing: pricing)
        }.value
    }

    // MARK: - Cost basis

    /// Price the busiest account's turns since `since` per hour under each
    /// mode and compare with the hourly rollup the fit reads. Returns the
    /// mode that matches.
    static func costBasis(container: ModelContainer, pricing: PricingTable.Snapshot) throws -> CostMode {
        let context = ModelContext(container)
        let account = try busiestAccount(window: RateLimitWindowName.fiveHour, context: context,
                                         storeURL: container.configurations.first!.url).id
        // Whole local days from the first after `since`, to whole hours the
        // rollup has settled, so both sides cover exactly the same buckets.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let from = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: since))!
        let until = calendar.dateInterval(of: .hour, for: Date().addingTimeInterval(-2 * 3600))!.start
        var priced: [CostMode: [String: Double]] = [:]
        var turns = 0
        try ModelWalk.forEach(FetchDescriptor<TokenSample>(
            predicate: #Predicate { $0.accountId == account && $0.sampledAt >= from && $0.sampledAt < until },
            sortBy: [SortDescriptor(\.sampledAt)]), in: container) { s in
            turns += 1
            let key = "\(s.date)|\(calendar.component(.hour, from: s.sampledAt))|\(s.model)"
            for mode in [CostMode.auto, .calculate] {
                priced[mode, default: [:]][key, default: 0] += CostCalculator.cost(s, mode: mode, snapshot: pricing)
            }
        }
        let startKey = TokenSample.formatDate(from)
        let rollup = try context.fetch(FetchDescriptor<AccountHourlyAggregate>(
            predicate: #Predicate { $0.accountId == account && $0.date >= startKey }))
        var stored: [String: Double] = [:]
        let endKey = TokenSample.formatDate(until)
        let endHour = calendar.component(.hour, from: until)
        for row in rollup where row.date < endKey || (row.date == endKey && row.hour < endHour) {
            stored["\(row.date)|\(row.hour)|\(row.model)"] = row.totalCostUSD
        }
        let total = stored.values.reduce(0, +)
        var best = CostMode.auto
        var bestDiff = Double.infinity
        for mode in [CostMode.auto, .calculate] {
            let p = priced[mode] ?? [:]
            let keys = Set(p.keys).union(stored.keys)
            let diff = keys.reduce(0.0) { $0 + abs((p[$1] ?? 0) - (stored[$1] ?? 0)) }
            let worst = keys.map { abs((p[$0] ?? 0) - (stored[$0] ?? 0)) }.max() ?? 0
            print(String(format: "cost basis (%@): %d turns, %d hour×model buckets, rollup $%.2f, priced $%.2f, Σ|diff| $%.6f (%.4f%%), worst bucket $%.6f",
                         mode.rawValue, turns, keys.count, total, p.values.reduce(0, +), diff,
                         100 * diff / max(total, 1e-9), worst))
            if diff < bestDiff { bestDiff = diff; best = mode }
        }
        print("cost basis: the rollup matches \(best.rawValue)")
        return best
    }

    // MARK: - Replay

    static func busiestAccount(window: String, context: ModelContext,
                               storeURL: URL) throws -> (id: String, readings: [MeterReading]) {
        let accounts = try context.fetch(FetchDescriptor<Account>()).map(\.id)
            .filter { $0 != AccountDailyAggregate.unattributedKey }.sorted()
        var best: (id: String, readings: [MeterReading], dense: Int)?
        for a in accounts {
            let rows = RawLimitReader.rateRows(storeURL: storeURL, account: a,
                                               since: since.addingTimeInterval(-15 * 86_400)) ?? []
            let readings = rows.filter { $0.window == window }
                .map { MeterReading(at: $0.at, percent: $0.usedPercentage, resetsAt: $0.resetsAt) }
                .sorted { ($0.at, $0.percent) < ($1.at, $1.percent) }
            let dense = readings.filter { $0.at >= since }.count
            if dense > (best?.dense ?? -1) { best = (a, readings, dense) }
        }
        let found = try #require(best)
        return (found.id, found.readings)
    }

    struct Moment {
        let truth: Double
        let hold: Double
        let live: Double
        /// The harness's burn: rate × spend over the last 30 minutes × 2.
        let spendBurn: Double
        /// What the gate sees: `RecentBurn` over the kept readings.
        let gateBurn: Double?
        let liveAge: TimeInterval
    }

    static func replay(window key: String, container: ModelContainer, storeURL: URL,
                       mode: CostMode, pricing: PricingTable.Snapshot, everyReading: Bool) throws {
        let started = Date()
        let context = ModelContext(container)
        let duration = PaceMath.windowDuration(for: key)!
        let (account, all) = try busiestAccount(window: key, context: context, storeURL: storeURL)
        let readings = (everyReading ? all : all.filter { $0.resetsAt != nil }).filter { $0.at <= span.end }
        guard let last = readings.last else { return }

        // 1. Thin to one per 5 minutes.
        var keep = [Bool](repeating: false, count: readings.count)
        var lastKept = -Double.infinity
        for (i, r) in readings.enumerated() where r.at.timeIntervalSince1970 - lastKept >= thin {
            keep[i] = true
            lastKept = r.at.timeIntervalSince1970
        }
        let kept = readings.indices.filter { keep[$0] }.map { readings[$0] }
        let keptTimes = kept.map(\.at)

        // 2. A fit per local day, from the 14 days before it.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let fromKey = TokenSample.formatDate(since.addingTimeInterval(-15 * 86_400))
        let hourly = try context.fetch(FetchDescriptor<AccountHourlyAggregate>(
            predicate: #Predicate { $0.accountId == account && $0.date >= fromKey }))
            .map { HourlySpend(date: $0.date, hour: $0.hour, model: $0.model, costUSD: $0.totalCostUSD) }
        var rates: [String: LiveMeterRates] = [:]
        var day = calendar.startOfDay(for: since)
        var pooled: [Double] = []
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
                pooled.append(fit.pooledRate)
            }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }

        // Turns, priced the way `LiveMeterSource` prices them.
        var spend: [LiveSpend] = []
        let spendFrom = since.addingTimeInterval(-86_400)
        try ModelWalk.forEach(FetchDescriptor<TokenSample>(
            predicate: #Predicate { $0.accountId == account && $0.sampledAt >= spendFrom },
            sortBy: [SortDescriptor(\.sampledAt)]), in: container) { s in
            spend.append(LiveSpend(at: s.sampledAt, model: s.model,
                                   costUSD: CostCalculator.cost(s, mode: mode, snapshot: pricing)))
        }
        let spendTimes = spend.map(\.at)
        // The same read through the source itself, on one hour, so the
        // probe's pricing is the shipped pricing, not a copy of it.
        if let end = spendTimes.last {
            let mine = spend.filter { $0.at > end.addingTimeInterval(-3600) && $0.at <= end }
            let source = LiveMeterSource(context: context, mode: mode, pricing: pricing)
                .spend(account: account, after: end.addingTimeInterval(-3600), through: end) ?? []
            #expect(source == mine)
        }

        // 3. Score every thinned-away reading.
        var moments: [Moment] = []
        var noFit = 0, otherCycle = 0, noValue = 0
        for (i, d) in readings.enumerated() where !keep[i] && d.at >= since {
            guard let j = lastIndex(keptTimes, atOrBefore: d.at) else { continue }
            let k = kept[j]
            if !everyReading {
                guard let r = d.resetsAt, let kr = k.resetsAt,
                      RateLimitCycle.contains(sampleReset: r, resets: kr, duration: duration)
                else { otherCycle += 1; continue }
            } else if let r = d.resetsAt, let kr = k.resetsAt, d.at < kr,
                      !RateLimitCycle.contains(sampleReset: r, resets: kr, duration: duration) {
                // A later cycle before the kept one's reset: not a state the
                // meter can be in, so not one to score.
                otherCycle += 1
                continue
            }
            let todayKey = TokenSample.formatDate(d.at)
            guard let dayRates = rates[todayKey] else {
                noFit += 1
                moments.append(Moment(truth: d.percent, hold: k.percent, live: k.percent,
                                      spendBurn: 0, gateBurn: nil, liveAge: 0))
                continue
            }
            let asOf = max(k.at, d.at.addingTimeInterval(-lag))
            let slice = Array(spend[upperBound(spendTimes, k.at)..<upperBound(spendTimes, asOf)])
            let value = LiveMeter.value(reading: k, duration: duration, rates: dayRates,
                                        spend: slice, now: asOf)
            if value == nil { noValue += 1 }
            let recent = spend[upperBound(spendTimes, d.at.addingTimeInterval(-1800))..<upperBound(spendTimes, d.at)]
            let burn = 2 * recent.reduce(0.0) { $0 + dayRates.rate(for: $1.model).rate * $1.costUSD }
            let gateReadings = kept[lowerBound(keptTimes, d.at.addingTimeInterval(-1800))...j]
                .map { RecentBurn.Reading(at: $0.at, percent: $0.percent, resetsAt: $0.resetsAt) }
            moments.append(Moment(
                truth: d.percent, hold: k.percent, live: value?.percent ?? k.percent,
                spendBurn: burn,
                gateBurn: RecentBurn.percentPerHour(readings: Array(gateReadings), now: d.at, duration: duration),
                liveAge: d.at.timeIntervalSince(k.at)))
        }

        let elapsed = Date().timeIntervalSince(started)
        print(String(format: "\n=== %@ · %@ · account %@ · %d readings since %@, %d kept at one per %.0f min · %d fits, pooled median %.3f pts/$ · %.1f s",
                     key, everyReading ? "every reading Pacer holds" : "the harness's readings (reset set)",
                     String(account.suffix(4)), readings.filter { $0.at >= since }.count,
                     "2026-09-01", kept.filter { $0.at >= since }.count, thin / 60, rates.count,
                     median(pooled), elapsed))
        print("    \(moments.count) moments scored; left out: \(otherCycle) in another cycle; \(noFit) with no fit that day (shown as the reading); \(noValue) with no live value")

        print("    by the harness's burn (rate × spend over the last 30 min):")
        for (name, sel) in [("any time", { (_: Moment) in true }),
                            ("20+ points/h", { (m: Moment) in m.spendBurn >= 20 }),
                            ("40+ points/h", { (m: Moment) in m.spendBurn >= 40 })] as [(String, (Moment) -> Bool)] {
            line(name, moments.filter(sel))
        }
        print("    by the gate's burn (RecentBurn over the kept readings), the padding's bands:")
        for (name, sel) in [("no burn", { (m: Moment) in m.gateBurn == nil }),
                            ("under 20/h", { (m: Moment) in m.gateBurn.map { $0 < 20 } ?? false }),
                            ("20–40/h", { (m: Moment) in m.gateBurn.map { $0 >= 20 && $0 < 40 } ?? false }),
                            ("40–60/h", { (m: Moment) in m.gateBurn.map { $0 >= 40 && $0 < 60 } ?? false }),
                            ("60+/h", { (m: Moment) in m.gateBurn.map { $0 >= 60 } ?? false })] as [(String, (Moment) -> Bool)] {
            line(name, moments.filter(sel), shortfall: true)
        }
    }

    static func line(_ name: String, _ ms: [Moment], shortfall: Bool = false) {
        guard ms.count >= 20 else {
            print("      \(name): \(ms.count) moments (too few)")
            return
        }
        let eh = ms.map { abs($0.truth - $0.hold) }
        let el = ms.map { abs($0.truth - $0.live) }
        let high = ms.filter { $0.live > $0.truth }.count
        var text = String(format: "      %-13@ n=%6d  today: 2+ behind %4.1f%%, mean %.2f, p95 %.0f  |  live: 2+ off %4.1f%%, mean %.2f, p95 %.0f, high %.1f%%",
                          name as NSString, ms.count,
                          100 * Double(eh.filter { $0 >= 2 }.count) / Double(ms.count), mean(eh), quantile(eh, 0.95),
                          100 * Double(el.filter { $0 >= 2 }.count) / Double(ms.count), mean(el), quantile(el, 0.95),
                          100 * Double(high) / Double(ms.count))
        if shortfall {
            // What the gate pads for: the live value under the truth.
            let short = ms.map { $0.truth - $0.live }
            let oldShort = ms.map { $0.truth - $0.hold }
            text += String(format: "\n%@shortfall (truth − live) p90 %.2f p95 %.2f p99 %.2f max %.0f · hold's p95 %.2f p99 %.2f",
                           String(repeating: " ", count: 22) as NSString,
                           quantile(short, 0.90), quantile(short, 0.95), quantile(short, 0.99), short.max() ?? 0,
                           quantile(oldShort, 0.95), quantile(oldShort, 0.99))
        }
        print(text)
    }

    // MARK: - The snapshot's live reads, timed

    /// Run the daily fit on the copy, then the snapshot's limit read for
    /// every account at the copy's newest turn, and print each live value
    /// beside its reading with what the reads cost.
    static func timeSnapshotReads(container: ModelContainer, mode: CostMode,
                                  pricing: PricingTable.Snapshot) async throws {
        let worker = SpendMeterFitWorker(modelContainer: container)
        let fits = try await worker.refit(now: Date())
        print(String(format: "\n=== the daily fit on the copy: %d fitted in %.0f ms", fits.fitted.count, fits.elapsed * 1000))
        let context = ModelContext(container)
        let accounts = try context.fetch(FetchDescriptor<Account>()).map(\.id)
            .filter { $0 != AccountDailyAggregate.unattributedKey }.sorted()
        let now = Date()
        print("=== the snapshot's limit read per account, live values included")
        for account in accounts {
            let started = Date()
            let limits = PacerSnapshotBuilder.limits(context: ModelContext(container), limitAccount: account,
                                                     engineScope: .account(account), now: now)
            let ms = Date().timeIntervalSince(started) * 1000
            let text = limits.all.map { w in
                let age = w.sampleAgeSeconds.map { "\($0)s old" } ?? "?"
                guard let live = w.livePercentage else {
                    return String(format: "%@ %.0f%% (%@, no live value)", w.identity, w.usedPercent, age)
                }
                return String(format: "%@ %.0f%% (%@) → live %.0f%% (+%.0f)",
                              w.identity, w.usedPercent, age, live, w.liveAddedPoints ?? 0)
            }.joined(separator: "; ")
            print(String(format: "    %@: %@ · %.1f ms", String(account.suffix(4)), text, ms))
        }
    }

    // MARK: - Helpers

    /// Index of the last time ≤ `t`.
    static func lastIndex(_ times: [Date], atOrBefore t: Date) -> Int? {
        let i = upperBound(times, t)
        return i > 0 ? i - 1 : nil
    }

    /// First index with time > `t`.
    static func upperBound(_ times: [Date], _ t: Date) -> Int {
        var lo = 0, hi = times.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// First index with time ≥ `t`.
    static func lowerBound(_ times: [Date], _ t: Date) -> Int {
        var lo = 0, hi = times.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    static func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }

    static func median(_ xs: [Double]) -> Double { quantile(xs, 0.5) }

    /// numpy's default (linear) quantile.
    static func quantile(_ xs: [Double], _ q: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let pos = q * Double(s.count - 1)
        let lo = Int(pos.rounded(.down)), hi = min(s.count - 1, lo + 1)
        return s[lo] + (s[hi] - s[lo]) * (pos - Double(lo))
    }
}
