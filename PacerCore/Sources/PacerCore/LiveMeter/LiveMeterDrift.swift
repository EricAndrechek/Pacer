import Foundation
import SwiftData

/// One `[LiveMeter]` log line per window at each new reading: what the live
/// meter showed the moment before the reading landed, against the reading
/// (#318). So drift between the estimate and the server shows in
/// `make logs` without anything stored: the live value is never a reading.
///
/// Built from the previous reading and the turns between it and the new
/// one, exactly as the snapshot built it then (`LiveMeterSource`). Windows
/// with no fit say nothing, and neither does a window where the meter did
/// not move and the live value agreed with it.
public enum LiveMeterDrift {

    /// `readings` are the new poll's: window key and percent. Reads only, on
    /// its own context, so call it off the main actor after the poll's save
    /// (the runaway guard's suspension, rare, is its one write).
    ///
    /// Per window it also says when the new reading is stale (the lag
    /// guard, `LiveMeter.heldTick`), and judges the estimate against it for
    /// the runaway guard (`LiveMeterRunaway`), which keeps judging a
    /// suspended window so the drift lines go on saying how it would have
    /// done.
    public static func log(container: ModelContainer, account: String, at: Date,
                           readings: [(key: String, percent: Double)],
                           runaway: LiveMeterRunaway = .shared) {
        let context = ModelContext(container)
        var source = LiveMeterSource(context: context)
        source.ignoresRunaway = true
        let windows = readings.compactMap { source.latestReading(account: account, window: $0.key, before: at) }
        guard !windows.isEmpty else { return }
        let values = source.values(account: account, windows: windows, now: at)
        let acct = String(account.suffix(4))
        for (key, percent) in readings {
            let held = source.held(account: account, window: key, through: at)
            if let held {
                Log.write("LiveMeter", String(format: "%@ %@: reading held at %@%% while spend implied +%.1f",
                                              acct, key, fmt(percent), held.implied))
            }
            guard let v = values[key] else { continue }
            let fittedDay = source.latestRates(account: account, window: key)?.fittedDay ?? ""
            let verdict = runaway.judge(context: context, account: account, window: key, fittedDay: fittedDay,
                                        shown: v.percent, reading: percent, readingIsStale: held != nil)
            if verdict == .suspendedNow {
                Log.write("LiveMeter", "\(acct) \(key): live value \(Int(LiveMeterRunaway.highBy))+ points over "
                          + "\(LiveMeterRunaway.consecutive) readings in a row; showing readings until the next daily fit")
                // The board rebuilt on this poll's write, before the
                // suspension existed: drop the value now, not at the next
                // scan cycle.
                Task { @MainActor in LiveMeterBoard.shared.refresh() }
            }
            // Only when there is something to compare: the meter moved, or
            // the live value disagreed with it. A busy account is read every
            // ~30 s, and a line for every poll that merely saw some spend was
            // hundreds an hour that each said "they agree".
            if !v.restarted, v.reading.percent == percent, v.percent == percent { continue }
            let suspended = verdict == .suspended || verdict == .suspendedNow ? " · suspended" : ""
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
    ///
    /// Bounded: one window's readings since `since` (the day's start) plus
    /// the carry's hour before it, and the account's turns over the same
    /// span; a busy account polled on nine logins is ~2,600 readings a day.
    static func agreement(context: ModelContext, account: String, window key: String,
                          since: Date, now: Date) -> Agreement? {
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
        var pairs = 0, within = 0
        for i in 1..<readings.count where readings[i].at >= since {
            let prev = readings[i - 1], next = readings[i]
            guard LiveMeter.sameCycle(prev, next, duration: latest.duration),
                  next.at.timeIntervalSince(prev.at) <= LiveMeter.maxReadingAge else { continue }
            let first = lowerBound(times, prev.at.addingTimeInterval(-LiveMeter.carryLookback))
            let history = Array(readings[first...(i - 1)])
            let slice = Array(spend[upperBound(spendTimes, history[0].at)..<upperBound(spendTimes, next.at)])
            guard let v = LiveMeter.estimate(history: history, duration: latest.duration, rates: rates,
                                             spend: slice, counts: counts, now: next.at),
                  v.spendUSD > 0 || next.percent != prev.percent else { continue }
            pairs += 1
            if abs(v.percent - next.percent) <= 1 { within += 1 }
        }
        guard pairs >= minAgreementPairs else { return nil }
        return Agreement(pairs: pairs, withinOne: within)
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
