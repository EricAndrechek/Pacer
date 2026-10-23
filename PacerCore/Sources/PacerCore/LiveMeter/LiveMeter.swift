import Foundation

/// One turn's API-list spend, as the live meter reads it: when it landed,
/// which model, and what it cost under the cost mode the fit was made with.
public struct LiveSpend: Sendable, Equatable {
    public let at: Date
    public let model: String
    public let costUSD: Double

    public init(at: Date, model: String, costUSD: Double) {
        self.at = at
        self.model = model
        self.costUSD = costUSD
    }
}

/// The rates a `SpendMeterFit` row carries, decoded once: meter points per
/// API dollar for each fitted model, and the pooled factor for any model
/// without its own.
///
/// **No intercept.** The fit's intercept is usage off this Mac, averaged per
/// watched hour. Adding it between readings would make the meter climb while
/// nothing runs here; usage elsewhere arrives with the next real reading
/// instead (see `SpendMeterFit`). So this type does not carry it at all,
/// which makes adding it impossible rather than merely wrong.
public struct LiveMeterRates: Sendable, Equatable {
    public let modelRates: [String: Double]
    public let pooledRate: Double
    /// The local day the fit was made for, for the log line.
    public let fittedDay: String
    /// The fit's R² and the meter rise it saw, for `isStrong`. Rates built
    /// by hand (a test, a replay) default to strong.
    public let r2: Double
    public let totalRise: Double

    public init(modelRates: [String: Double], pooledRate: Double, fittedDay: String = "",
                r2: Double = 1, totalRise: Double = .infinity) {
        self.modelRates = modelRates
        self.pooledRate = pooledRate
        self.fittedDay = fittedDay
        self.r2 = r2
        self.totalRise = totalRise
    }

    public init(_ fit: SpendMeterFit) {
        self.init(modelRates: fit.modelRates, pooledRate: fit.pooledRate, fittedDay: fit.fittedDay,
                  r2: fit.r2, totalRise: fit.totalRise)
    }

    /// Good enough to show a live value from (`LiveMeter.minFitRise`).
    public var isStrong: Bool {
        totalRise >= LiveMeter.minFitRise && r2 >= LiveMeter.minFitR2
    }

    /// The model's own rate, else the pooled one, and which it was.
    ///
    /// A model's own rate of zero is kept: NNLS put it there because that
    /// model's spend did not move the meter, which is an answer, not a gap.
    func rate(for model: String) -> (rate: Double, own: Bool) {
        if let own = modelRates[model] { return (own, true) }
        return (pooledRate, false)
    }
}

/// What the meter reads now, estimated from the spend since its last
/// reading (#318). Never stored: not a `RateLimitSample`, not a
/// `UsageLimitSample`, not in the archive, the self-evaluation record or
/// `RecentBurn`, all of which learn from real readings.
public struct LiveMeterValue: Sendable, Equatable {

    /// Which rates priced the spend that was counted.
    public enum RateSource: String, Sendable {
        /// Every counted model had its own fitted rate.
        case perModel = "per-model"
        /// None did; all of it went at the pooled factor.
        case pooled
        /// Some of each.
        case mixed
        /// Nothing was spent since the reading, so no rate was used.
        case none
    }

    /// The live percentage in whole points: the reading plus the whole
    /// points the estimate has certainly added, capped at 100. What judges
    /// whole points (the `pacer` gate, threshold alerts, the drift log)
    /// reads this.
    public let percent: Double
    /// The same estimate before flooring: the reading, plus the carry, plus
    /// Σ rate × spend, never below the reading and capped at 100 (0 plus
    /// the spend after a reset). `shownPercent` is this to one decimal.
    public let exactPercent: Double
    /// The reading it started from.
    public let reading: MeterReading
    /// Points added to the reading: `percent` minus the reading, or minus 0
    /// after a reset.
    public let addedPoints: Double
    /// Σ rate × spend before flooring and capping, for the drift log.
    public let exactAdded: Double
    /// The counted spend, in API-list dollars.
    public let spendUSD: Double
    public let rateSource: RateSource
    /// The reading's cycle had reset by `asOf`, so the value restarted at 0.
    public let restarted: Bool
    /// The moment the value describes.
    public let asOf: Date
    /// Where inside its whole point the meter was estimated to sit at the
    /// reading (`LiveMeter.carry`); 0 after a reset.
    public let carry: Double

    public init(percent: Double, reading: MeterReading, addedPoints: Double, exactAdded: Double,
                spendUSD: Double, rateSource: RateSource, restarted: Bool, asOf: Date,
                carry: Double = 0, exactPercent: Double? = nil) {
        self.percent = percent
        self.exactPercent = exactPercent ?? percent
        self.reading = reading
        self.addedPoints = addedPoints
        self.exactAdded = exactAdded
        self.spendUSD = spendUSD
        self.rateSource = rateSource
        self.restarted = restarted
        self.asOf = asOf
        self.carry = carry
    }

    /// Whether the number is an estimate rather than Anthropic's reading:
    /// spend since the reading moved it, or its window reset since.
    ///
    /// Not "the floored number differs from the reading". Spend that has not
    /// yet added a whole point is still an estimate of where the meter sits,
    /// and showing it as the bare reading would claim the server said so.
    /// Not "any spend" either: a model whose own fitted rate is zero adds
    /// nothing, and nothing moved the number off the reading. With nothing
    /// counted, the number is the reading, whole, whatever the carry says.
    public var isEstimate: Bool { restarted || exactAdded > 0 }

    /// The number a surface shows: the reading, whole, when this is not an
    /// estimate; else `exactPercent` cut (never rounded up) to one decimal,
    /// so its whole part is always `percent` and a shown "42.9%" is never a
    /// point the gate has not counted.
    public var shownPercent: Double {
        guard isEstimate else { return percent }
        return min(max(PacerMeterFormat.tenths(exactPercent), percent), percent + 0.9)
    }
}

/// The live meter's arithmetic (#318), pure and `Sendable`-only:
///
///     live % = last reading + floor(carry + Σ over models of rate × API $ since the reading)
///
/// capped at 100 and never below the reading.
///
/// **Floored, not rounded.** The server's meter is whole points, and an
/// estimate that rounds up shows a point the server has not reached yet: in
/// the lab replay over 41,940 busy pairs of readings, rounding made the shown
/// number step back down at the next reading 6.4% of the time against 1.3%
/// floored, for a mean error of 0.24 against 0.27.
///
/// **The carry** (`carry(readings:…)`) is where inside its whole point the
/// meter sat at the reading. Flooring from the bare whole-number reading
/// treats every reading as the bottom of its point, and that reads low: on
/// the owner's one-login account the drift log showed the floored value exact
/// 6 times in 21, a point low 13 times and never high.
///
/// **Resets.** When the reading's cycle has reset by `now` (its `resetsAt` is
/// past; compared as instants, never `resetsAt ==`), the value restarts at 0
/// plus the spend after the reset. More than one cycle later there is no
/// telling where the current one began, so there is no value. A reading with
/// no reset at 0% is the server saying no window is open: the next turn
/// opens one, and the ordinary rule (0 plus spend) already says so.
///
/// **No value** when there is no fit, the fit is weak
/// (`LiveMeterRates.isStrong`), or the reading is older than `maxReadingAge`:
/// callers show the reading.
public enum LiveMeter {

    /// The oldest reading a value is built on. The rates were fitted on
    /// pairs of readings under an hour apart (`SpendMeterFitter.maxPairGap`),
    /// and beyond that the poller has stopped, so usage elsewhere (which the
    /// fill cannot see) has had long enough to matter. It also bounds the
    /// source's spend read to an hour of turns.
    public static let maxReadingAge: TimeInterval = SpendMeterFitter.maxPairGap

    /// A fit that saw less rise than this, or explains less of it than
    /// `minFitR2`, shows the reading rather than a live value.
    ///
    /// From the weak-fit replay on the owner's store (`LiveMeterWeakFitProbe`:
    /// the fixed windows refitted on 2, 3, 7 and 14 days to make weak fits on
    /// purpose, plus the per-model caps as they are). Below 20 points of rise
    /// or R² 0.5, the live value ran above the next reading in 7.7% of the
    /// moments it added anything, and was further off than the held reading
    /// in 6.9%; above both, in 1.8% and 1.2%. The Fable weekly cap's fits
    /// (R² 0.15–0.75 on 8–12 points in 14 days) are under it, so that cap
    /// shows its reading.
    public static let minFitRise = 20.0
    public static let minFitR2 = 0.5

    /// `<synthetic>` turns are Claude Code's own bookkeeping, never billed
    /// (AGENTS.md rule 2).
    static let syntheticModel = "<synthetic>"

    /// Float sums of fractions like 0.1 can land a hair under a whole
    /// point; this keeps 2.9999999999 from flooring to 2.
    static let floorTolerance = 1e-9

    /// How far before the reading `carry` looks: the pair gap the rates were
    /// fitted on, past which two readings say nothing about each other.
    public static let carryLookback: TimeInterval = SpendMeterFitter.maxPairGap

    /// `carry`'s two settings, chosen on the one-login replay
    /// (`LiveMeterEstimatorProbe`); see `carry`.
    public static let carryPosition = 0.25
    public static let carryMovedWeight = 0.5

    /// The instant spend starts counting from, and the level it adds to:
    /// the reading, or 0 at its cycle's reset. Nil when more than one cycle
    /// has passed. The source fetches from the earliest of these.
    public static func start(reading: MeterReading, duration: TimeInterval,
                             now: Date) -> (from: Date, base: Double, restarted: Bool)? {
        guard let reset = reading.resetsAt, reset <= now else {
            return (reading.at, reading.percent, false)
        }
        guard now < reset.addingTimeInterval(duration) else { return nil }
        // A reading taken after its own reset is a stale answer about the
        // window that ended; count from the reading rather than before it.
        return (max(reset, reading.at), 0, true)
    }

    /// Where inside its whole point the meter sat at the last of `readings`,
    /// in `[0, 1)`.
    ///
    /// Each reading says the true meter is in `[p, p + 1)`, and the spend
    /// between two readings says how far it moved. Carried from reading to
    /// reading the two narrow the range: a reading that ticks up after a lot
    /// of spend has only just crossed into its point; one that holds still
    /// while spend piles up is near the top of it. The carry is a quarter of
    /// the way up that range.
    ///
    /// The movement counts at half weight, because the rates are noisy at a
    /// five-minute scale. On the one-login replay the spend predicted 1,838
    /// points of 5-hour rise against 1,805 read, so the rates are not biased,
    /// but carried at full weight their noise pushed even the low end of the
    /// range over the next reading, and back down, in 9.6% of busy readings.
    /// At half weight and a quarter of the way up, the value just before a
    /// reading matched it 70% of the time against 64% floored, and stepped
    /// down at it 5.4% of the time against 3.1%. Rounding (71%, 13%), the
    /// middle of the range (68%, 17%) and a posterior carried with the
    /// rates' error (72%, 9%) were about as exact and stepped down two to
    /// three times as often.
    ///
    /// `readings` ascending, ending with the reading the value starts from;
    /// `spend` the turns since the first of them. A reset, a lowered
    /// reading, a gap over an hour, or a range the spend jumps clean past
    /// starts over at `[p, p + 1)`: the meter moved for reasons the spend
    /// here cannot see (another device), and only the reading is known.
    public static func carry(readings: [MeterReading], duration: TimeInterval, rates: LiveMeterRates,
                             spend: [LiveSpend], counts: (@Sendable (String) -> Bool)? = nil,
                             position: Double = carryPosition,
                             movedWeight: Double = carryMovedWeight) -> Double {
        guard let last = readings.last else { return 0 }
        var lo = 0.0, hi = 1.0
        var index = 0
        for (i, r) in readings.enumerated() {
            let p = r.percent
            var moved: Double?
            if i > 0 {
                let prev = readings[i - 1]
                var sum = 0.0
                while index < spend.count, spend[index].at <= prev.at { index += 1 }
                while index < spend.count, spend[index].at <= r.at {
                    let s = spend[index]
                    index += 1
                    guard s.costUSD > 0, s.model != syntheticModel, counts?(s.model) ?? true else { continue }
                    sum += rates.rate(for: s.model).rate * s.costUSD
                }
                if sameCycle(prev, r, duration: duration),
                   r.at.timeIntervalSince(prev.at) <= SpendMeterFitter.maxPairGap, p >= prev.percent {
                    moved = sum * movedWeight
                }
            }
            if let moved, lo + moved < p + 1, hi + moved > p {
                lo = max(lo + moved, p)
                hi = min(hi + moved, p + 1)
            } else {
                lo = p
                hi = p + 1
            }
        }
        return min(max(0, lo + position * (hi - lo) - last.percent), 1 - 1e-6)
    }

    /// Whether two consecutive readings are of one window: never across a
    /// reset that had passed by the later one, and never from a null reset
    /// (no window open) to an anchored one (the first turn opened a new one).
    static func sameCycle(_ a: MeterReading, _ b: MeterReading, duration: TimeInterval) -> Bool {
        if let reset = a.resetsAt, reset <= b.at { return false }
        switch (a.resetsAt, b.resetsAt) {
        case let (x?, y?): return RateLimitCycle.contains(sampleReset: x, resets: y, duration: duration)
        case (nil, nil): return true
        default: return false
        }
    }

    /// The live value at `now`, or nil when there is none to show.
    ///
    /// `spend` may hold any turns (the source passes everything since the
    /// earliest start among an account's windows); only those after the
    /// start and at or before `now`, on a model `counts` accepts, are added.
    /// `counts` is `SpendMeterFitter.capCounts` for a per-model cap, nil for
    /// an account-wide window. `carry` is `carry(readings:…)` for this
    /// reading; 0 floors from the bottom of the reading's point.
    public static func value(
        reading: MeterReading, duration: TimeInterval, rates: LiveMeterRates?,
        spend: [LiveSpend], counts: (@Sendable (String) -> Bool)? = nil,
        carry: Double = 0,
        now: Date, maxReadingAge: TimeInterval = maxReadingAge
    ) -> LiveMeterValue? {
        guard let rates, rates.isStrong else { return nil }
        guard now.timeIntervalSince(reading.at) <= maxReadingAge else { return nil }
        guard let start = start(reading: reading, duration: duration, now: now) else { return nil }

        var exact = 0.0
        var spent = 0.0
        var ownSpend = 0.0
        var pooledSpend = 0.0
        for s in spend where s.at > start.from && s.at <= now && s.costUSD > 0 {
            guard s.model != syntheticModel, counts?(s.model) ?? true else { continue }
            let (rate, own) = rates.rate(for: s.model)
            exact += rate * s.costUSD
            spent += s.costUSD
            if own { ownSpend += s.costUSD } else { pooledSpend += s.costUSD }
        }

        // After a reset there is no point for the meter to sit inside.
        let carried = start.restarted ? 0 : min(max(0, carry), 1 - 1e-6)
        let points = (carried + exact + floorTolerance).rounded(.down)
        let percent: Double, exactPercent: Double
        if start.restarted {
            percent = min(100, max(0, points))
            exactPercent = min(100, max(0, exact + floorTolerance))
        } else {
            // A reading at or over 100 stays as it is; nothing here may move
            // it down.
            percent = max(start.base, min(100, start.base + max(0, points)))
            exactPercent = max(start.base, min(100, start.base + carried + max(0, exact) + floorTolerance))
        }
        let source: LiveMeterValue.RateSource
        switch (ownSpend > 0, pooledSpend > 0) {
        case (true, true): source = .mixed
        case (true, false): source = .perModel
        case (false, true): source = .pooled
        case (false, false): source = .none
        }
        return LiveMeterValue(
            percent: percent, reading: reading, addedPoints: percent - start.base,
            exactAdded: exact, spendUSD: spent, rateSource: source,
            restarted: start.restarted, asOf: now, carry: carried, exactPercent: exactPercent)
    }
}
