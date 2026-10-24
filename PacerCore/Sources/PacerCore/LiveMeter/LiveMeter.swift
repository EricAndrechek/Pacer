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

    public init(modelRates: [String: Double], pooledRate: Double, fittedDay: String = "") {
        self.modelRates = modelRates
        self.pooledRate = pooledRate
        self.fittedDay = fittedDay
    }

    public init(_ fit: SpendMeterFit) {
        self.init(modelRates: fit.modelRates, pooledRate: fit.pooledRate, fittedDay: fit.fittedDay)
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

    /// The live percentage: whole points above the reading, capped at 100.
    public let percent: Double
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

    public init(percent: Double, reading: MeterReading, addedPoints: Double, exactAdded: Double,
                spendUSD: Double, rateSource: RateSource, restarted: Bool, asOf: Date) {
        self.percent = percent
        self.reading = reading
        self.addedPoints = addedPoints
        self.exactAdded = exactAdded
        self.spendUSD = spendUSD
        self.rateSource = rateSource
        self.restarted = restarted
        self.asOf = asOf
    }
}

/// The live meter's arithmetic (#318), pure and `Sendable`-only:
///
///     live % = last reading + floor(Σ over models of rate × API $ since the reading)
///
/// capped at 100 and never below the reading.
///
/// **Floored, not rounded.** The server's meter is whole points, and an
/// estimate that rounds up shows a point the server has not reached yet: in
/// the lab replay over 41,940 busy pairs of readings, rounding made the shown
/// number step back down at the next reading 6.4% of the time against 1.3%
/// floored, for a mean error of 0.24 against 0.27.
///
/// **Resets.** When the reading's cycle has reset by `now` (its `resetsAt` is
/// past; compared as instants, never `resetsAt ==`), the value restarts at 0
/// plus the spend after the reset. More than one cycle later there is no
/// telling where the current one began, so there is no value. A reading with
/// no reset at 0% is the server saying no window is open: the next turn
/// opens one, and the ordinary rule (0 plus spend) already says so.
///
/// **No value** when there is no fit yet or the reading is older than
/// `maxReadingAge`: callers show the reading.
public enum LiveMeter {

    /// The oldest reading a value is built on. The rates were fitted on
    /// pairs of readings under an hour apart (`SpendMeterFitter.maxPairGap`),
    /// and beyond that the poller has stopped, so usage elsewhere (which the
    /// fill cannot see) has had long enough to matter. It also bounds the
    /// source's spend read to an hour of turns.
    public static let maxReadingAge: TimeInterval = SpendMeterFitter.maxPairGap

    /// `<synthetic>` turns are Claude Code's own bookkeeping, never billed
    /// (AGENTS.md rule 2).
    static let syntheticModel = "<synthetic>"

    /// Float sums of fractions like 0.1 can land a hair under a whole
    /// point; this keeps 2.9999999999 from flooring to 2.
    static let floorTolerance = 1e-9

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

    /// The live value at `now`, or nil when there is none to show.
    ///
    /// `spend` may hold any turns (the source passes everything since the
    /// earliest start among an account's windows); only those after the
    /// start and at or before `now`, on a model `counts` accepts, are added.
    /// `counts` is `SpendMeterFitter.capCounts` for a per-model cap, nil for
    /// an account-wide window.
    public static func value(
        reading: MeterReading, duration: TimeInterval, rates: LiveMeterRates?,
        spend: [LiveSpend], counts: (@Sendable (String) -> Bool)? = nil,
        now: Date, maxReadingAge: TimeInterval = maxReadingAge
    ) -> LiveMeterValue? {
        guard let rates else { return nil }
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

        let points = (exact + floorTolerance).rounded(.down)
        let percent: Double
        if start.restarted {
            percent = min(100, max(0, points))
        } else {
            // A reading at or over 100 stays as it is; nothing here may move
            // it down.
            percent = max(start.base, min(100, start.base + max(0, points)))
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
            restarted: start.restarted, asOf: now)
    }
}
