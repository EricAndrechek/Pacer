import Foundation
import SwiftData

/// The live meter at each new reading (#318): what it showed for each window
/// the moment before the reading landed, against the reading. The poll
/// measures it before its save (`measure`), keeps it beside the reading in
/// that same save (`LiveMeterOutcome`, #352), and after the save writes a
/// `[LiveMeter]` line per window with something to say (`log`), so drift
/// between the estimate and the server shows in `make logs` too.
///
/// Built from the previous reading and the turns between it and the new
/// one, exactly as the snapshot built it then (`LiveMeterSource`). Windows
/// with no fit keep nothing and say nothing; the log also skips a window
/// where the meter did not move and the live value agreed with it.
public enum LiveMeterDrift {

    /// One window's live meter at the instant a new reading of it lands.
    public struct Measurement: Sendable, Equatable {
        public let window: String
        /// The reading that is landing.
        public let reading: MeterReading
        /// The live value at `reading.at`, built on the reading before it:
        /// what a surface showed the moment before. Nil when there was none
        /// (no fit, a weak one, no reading before it within the hour).
        public let value: LiveMeterValue?
        /// Whether `reading` is in the cycle of the reading `value` was built
        /// on (`LiveMeter.sameCycle`, never `resetsAt ==`); nil without a
        /// value.
        public let sameCycle: Bool?
        /// The lag guard on `reading`: the points the spend implied while it
        /// held still (`LiveMeter.heldTick`). Nil when it is believed.
        public let readingHeldImplied: Double?
        /// The runaway guard's verdict on `reading`; nil without a value.
        public let runaway: LiveMeterRunaway.Verdict?
    }

    /// Measure a poll's new readings, all taken at `at`, before the save that
    /// writes them. Reads only, on a context of its own, so call it off the
    /// main actor; the runaway guard's suspension, rare, is its one write.
    ///
    /// These are the reads the drift log used to make after the save, moved
    /// in front of it so the record lands with the reading rather than in a
    /// second save. Nothing here needs the new reading in the store: the
    /// value is built on the reading before it, and the lag guard is handed
    /// the new one (`LiveMeterSource.held(account:latest:)`).
    ///
    /// Per window it also judges the new reading stale or not (the lag guard)
    /// and the estimate against it (the runaway guard, `LiveMeterRunaway`),
    /// which keeps judging a suspended window so the record and the drift
    /// lines go on saying how it would have done.
    public static func measure(container: ModelContainer, account: String, at: Date,
                               readings: [(key: String, reading: MeterReading)],
                               runaway: LiveMeterRunaway = .shared) -> [Measurement] {
        measure(source: LiveMeterSource(context: ModelContext(container)), account: account, at: at,
                readings: readings, runaway: runaway)
    }

    /// `measure` on a given source: a test pins its cost mode and prices.
    static func measure(source: LiveMeterSource, account: String, at: Date,
                        readings: [(key: String, reading: MeterReading)],
                        runaway: LiveMeterRunaway) -> [Measurement] {
        var source = source
        source.ignoresRunaway = true
        guard source.hasTables, !readings.isEmpty else { return [] }
        let previous = readings.compactMap { source.latestReading(account: account, window: $0.key, before: at) }
        let values = previous.isEmpty ? [:] : source.values(account: account, windows: previous, now: at)
        let byKey = Dictionary(previous.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        return readings.map { key, reading in
            let prev = byKey[key]
            // The new reading as the store is about to hold it. Its duration
            // and the model a cap names are the previous reading's: the same
            // window key is the same window.
            let held = prev.flatMap {
                source.held(account: account, latest: LiveMeterSource.Window(
                    key: key, duration: $0.duration, reading: reading,
                    capModelId: $0.capModelId, capModelName: $0.capModelName))
            }
            guard let prev, let v = values[key] else {
                return Measurement(window: key, reading: reading, value: nil, sameCycle: nil,
                                   readingHeldImplied: held?.implied, runaway: nil)
            }
            let verdict = runaway.judge(context: source.context, account: account, window: key,
                                        fittedDay: v.fittedDay, shown: v.percent, reading: reading.percent,
                                        readingIsStale: held != nil)
            if verdict == .suspendedNow {
                // The suspension is written before the poll's save, so the
                // board's rebuild on that write already leaves this window
                // out. This one covers a save that fails, which writes
                // nothing to rebuild on.
                Task { @MainActor in LiveMeterBoard.shared.refresh() }
            }
            return Measurement(window: key, reading: reading, value: v,
                               sameCycle: LiveMeter.sameCycle(prev.reading, reading, duration: prev.duration),
                               readingHeldImplied: held?.implied, runaway: verdict)
        }
    }

    /// The `[LiveMeter]` lines for one poll's measurements, written after its
    /// save. Reads nothing.
    public static func log(account: String, measurements: [Measurement]) {
        let acct = String(account.suffix(4))
        for m in measurements {
            let key = m.window, percent = m.reading.percent
            if let implied = m.readingHeldImplied {
                Log.write("LiveMeter", String(format: "%@ %@: reading held at %@%% while spend implied +%.1f",
                                              acct, key, fmt(percent), implied))
            }
            guard let v = m.value else { continue }
            if m.runaway == .suspendedNow {
                Log.write("LiveMeter", "\(acct) \(key): live value \(Int(LiveMeterRunaway.highBy))+ points over "
                          + "\(LiveMeterRunaway.consecutive) readings in a row; showing readings until the next daily fit")
            }
            // Only when there is something to compare: the meter moved, or
            // the live value disagreed with it. A busy account is read every
            // ~30 s, and a line for every poll that merely saw some spend was
            // hundreds an hour that each said "they agree". The record keeps
            // every one (`LiveMeterOutcome`).
            if !v.restarted, v.reading.percent == percent, v.percent == percent { continue }
            let suspended = m.runaway == .suspended || m.runaway == .suspendedNow ? " · suspended" : ""
            Log.write("LiveMeter", line(account: account, window: key, read: percent, live: v) + suspended)
        }
    }

    /// `8c95 five_hour: read 42% · live showed 41% (38% 4m ago +3, carry 0.40, $17.20 per-model) · -1`
    static func line(account: String, window: String, read: Double, live v: LiveMeterValue) -> String {
        // Built on the anchor: the reading itself, or the tick a stale one
        // held at (`LiveMeter.estimate`).
        let ago = Int(v.asOf.timeIntervalSince(v.anchor.at).rounded())
        let from = v.restarted
            ? "0% after the reset"
            : "\(fmt(v.anchor.percent))% \(ago >= 60 ? "\(ago / 60)m" : "\(ago)s") ago"
                + (v.heldImplied != nil ? " held" : "")
        return String(format: "%@ %@: read %@%% · live showed %@%% (%@ +%@, carry %.2f, $%.2f %@) · %+.0f",
                      String(account.suffix(4)), window, fmt(read), fmt(v.percent),
                      from, fmt(v.addedPoints), v.carry, v.spendUSD, v.rateSource.rawValue, v.percent - read)
    }

    private static func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}

// MARK: - How close it has been

public extension LiveMeterDrift {

    /// How often the live value just before a reading was within a point of
    /// it: what the drift log prints line by line, totalled.
    struct Agreement: Sendable, Equatable {
        /// Readings scored: the meter moved since the one before, or there
        /// was spend to add (the pairs the drift log has something to say
        /// about).
        public let pairs: Int
        /// Of those, the live value was at most a point off.
        public let withinOne: Int

        public var share: Double { pairs == 0 ? 0 : Double(withinOne) / Double(pairs) }
    }

    /// Too few to say anything: under this many scored readings, no line.
    static let minAgreementPairs = 5

    /// Today's agreement for one window, recomputed from today's readings and
    /// turns with the current fit, exactly as each drift line was built:
    /// every reading scored against the live value built on the one before
    /// it. Nothing is stored. Nil without a usable fit or enough readings.
    static func agreement(context: ModelContext, account: String, window key: String,
                          since: Date, now: Date) -> Agreement? {
        scored(context: context, account: account, window: key, from: since, now: now)
            .flatMap { agreement($0, since: since) }
    }

    /// The comparison sheet's chart and line, from one pass (#318).
    struct Review: Sendable, Equatable {
        /// Anthropic's readings since the chart's start.
        public let readings: [MeterReading]
        /// The live value just before each of those readings, built on the
        /// one before it: what the drift log prints, as a line. Its time is
        /// the reading's; `shown` the number a surface showed.
        public let estimates: [(at: Date, shown: Double)]
        public let agreement: Agreement?

        public static func == (a: Review, b: Review) -> Bool {
            a.readings == b.readings && a.agreement == b.agreement
                && a.estimates.map(\.at) == b.estimates.map(\.at)
                && a.estimates.map(\.shown) == b.estimates.map(\.shown)
        }
    }

    /// Most points per line the chart is handed: a weekly window's day of
    /// readings on a busy account is ~2,900.
    static let reviewPointCap = 720

    /// The readings since `chartFrom` against the live estimate just before
    /// each, and today's agreement, recomputed on demand from the store with
    /// the current fit, in one pass. Nothing is stored. Nil without a strong
    /// fit or two readings.
    ///
    /// Bounded like `agreement`: one window's readings from the earlier of
    /// the two starts plus the carry's hour before it, and the account's
    /// turns over that span. Call it off the main actor.
    static func review(context: ModelContext, account: String, window key: String,
                       chartFrom: Date, agreementSince: Date, now: Date) -> Review? {
        guard let s = scored(context: context, account: account, window: key,
                             from: min(chartFrom, agreementSince), now: now) else { return nil }
        let readings = s.readings.filter { $0.at >= chartFrom }
        let estimates = s.pairs.filter { $0.next.at >= chartFrom }.map { ($0.next.at, $0.value.shownPercent) }
        return Review(readings: thinned(readings, cap: reviewPointCap),
                      estimates: thinned(estimates, cap: reviewPointCap),
                      agreement: agreement(s, since: agreementSince))
    }

    /// Every reading since `from`, each paired with the live value built on
    /// the one before it at its instant, as the drift log built it.
    private struct Scored {
        let readings: [MeterReading]
        let pairs: [(prev: MeterReading, next: MeterReading, value: LiveMeterValue)]
    }

    private static func scored(context: ModelContext, account: String, window key: String,
                               from since: Date, now: Date) -> Scored? {
        let source = LiveMeterSource(context: context)
        guard let latest = source.latestReading(account: account, window: key),
              let rates = source.latestRates(account: account, window: key), rates.isStrong
        else { return nil }
        let from = since.addingTimeInterval(-LiveMeter.carryLookback)
        let readings = source.readings(account: account, window: key, from: from, through: now, limit: 20_000)
        guard readings.count >= 2,
              let spend = source.spend(account: account, after: from, through: now,
                                       limit: LiveMeterSource.sampleFetchLimit * 5)
        else { return nil }
        let counts = SpendMeterFitter.capCounts(modelId: latest.capModelId, displayName: latest.capModelName)
        let times = readings.map(\.at)
        let spendTimes = spend.map(\.at)
        var pairs: [(prev: MeterReading, next: MeterReading, value: LiveMeterValue)] = []
        for i in 1..<readings.count where readings[i].at >= since {
            let prev = readings[i - 1], next = readings[i]
            guard LiveMeter.sameCycle(prev, next, duration: latest.duration),
                  next.at.timeIntervalSince(prev.at) <= LiveMeter.maxReadingAge else { continue }
            let first = lowerBound(times, prev.at.addingTimeInterval(-LiveMeter.carryLookback))
            let history = Array(readings[first...(i - 1)])
            let slice = Array(spend[upperBound(spendTimes, history[0].at)..<upperBound(spendTimes, next.at)])
            guard let v = LiveMeter.estimate(history: history, duration: latest.duration, rates: rates,
                                             spend: slice, counts: counts, now: next.at) else { continue }
            pairs.append((prev, next, v))
        }
        return Scored(readings: readings.filter { $0.at >= since }, pairs: pairs)
    }

    /// Scored only where the drift log has something to say: the meter moved
    /// since the reading before, or there was spend to add.
    private static func agreement(_ s: Scored, since: Date) -> Agreement? {
        var pairs = 0, within = 0
        for p in s.pairs where p.next.at >= since
            && (p.value.spendUSD > 0 || p.next.percent != p.prev.percent) {
            pairs += 1
            if abs(p.value.percent - p.next.percent) <= 1 { within += 1 }
        }
        guard pairs >= minAgreementPairs else { return nil }
        return Agreement(pairs: pairs, withinOne: within)
    }

    /// At most `cap` of `items`, evenly through them, the last always kept.
    static func thinned<T>(_ items: [T], cap: Int) -> [T] {
        guard items.count > cap, cap > 1 else { return items }
        let step = Double(items.count - 1) / Double(cap - 1)
        return (0..<cap).map { items[Int((Double($0) * step).rounded())] }
    }

    /// First index with time ≥ `t`.
    private static func lowerBound(_ times: [Date], _ t: Date) -> Int {
        var lo = 0, hi = times.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// First index with time > `t`.
    private static func upperBound(_ times: [Date], _ t: Date) -> Int {
        var lo = 0, hi = times.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
