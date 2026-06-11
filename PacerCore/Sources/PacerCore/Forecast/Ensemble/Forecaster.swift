import Foundation

/// A candidate predictor in the forecast tournament.
///
/// The lesson from the predictions redesign (`docs/predictions-redesign.md`):
/// no single projection method wins everywhere — naive beat the fancy
/// estimator for end-of-day/monthly, profiles beat naive, the estimator beat
/// linear for the 7-day window. Rather than hand-pick one method per surface,
/// the ensemble runs *every* candidate against the user's own realized
/// history (`Backtester`) and lets `ForecastSelector` pick the current winner
/// per surface — automatically, per-user, and re-evaluated as behavior drifts.
///
/// A `Forecaster` is a pure function from a `ForecastInput` (the period so far
/// + prior complete periods) to a projected end-of-period total. Keeping it
/// pure and value-typed means the whole tournament unit-tests like the rest
/// of `Forecast/`, and a future on-device ML model (Create ML / Core ML) can
/// join as just another candidate that only gets used if it *wins* the
/// backtest — so ML can only ever help, never regress a user's numbers.
public protocol Forecaster: Sendable {
    /// Stable identifier, persisted as the selected method per surface.
    var id: String { get }
    /// Lower = simpler. The selector breaks near-ties toward the simpler
    /// model (Occam's selection — a strong defense against overfitting the
    /// choice to backtest noise).
    var complexity: Int { get }
    /// Project the end-of-period total, or `nil` when this method can't run on
    /// the given input (too few samples, no prior periods, etc.). Returning
    /// `nil` lowers the forecaster's *coverage* in the backtest rather than
    /// scoring a bogus value.
    func projectTotal(_ input: ForecastInput) -> Double?
}

/// Everything a forecaster might need to project one period's total: the
/// current (partial) period as a cumulative series, plus prior *complete*
/// periods for the methods that learn a shape/seasonality. Value-agnostic —
/// `cumulative` is dollars for cost forecasts, but the math doesn't care.
public struct ForecastInput: Sendable {
    /// One cumulative observation within a period.
    public struct Point: Sendable, Equatable {
        public let at: Date
        /// Cumulative value since the period's start.
        public let cumulative: Double
        public init(at: Date, cumulative: Double) {
            self.at = at
            self.cumulative = cumulative
        }
    }

    /// A prior, complete period — its cumulative series and when it began.
    /// Assumed the same nominal length as the current period.
    public struct PriorPeriod: Sendable {
        public let start: Date
        public let points: [Point]
        public init(start: Date, points: [Point]) {
            self.start = start
            self.points = points
        }
        /// The period's realized total (last cumulative point).
        public var total: Double { points.last?.cumulative ?? 0 }
    }

    public let now: Date
    public let periodStart: Date
    public let periodEnd: Date
    public let calendar: Calendar
    /// Cumulative observations in the current period, time-ordered, last ≤ now.
    public let elapsed: [Point]
    /// Prior complete periods, oldest → newest.
    public let priorPeriods: [PriorPeriod]

    public init(
        now: Date,
        periodStart: Date,
        periodEnd: Date,
        calendar: Calendar = .current,
        elapsed: [Point],
        priorPeriods: [PriorPeriod]
    ) {
        self.now = now
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.calendar = calendar
        self.elapsed = elapsed
        self.priorPeriods = priorPeriods
    }

    /// Cumulative value so far this period.
    public var soFar: Double { elapsed.last?.cumulative ?? 0 }
    public var elapsedSeconds: TimeInterval { now.timeIntervalSince(periodStart) }
    public var totalSeconds: TimeInterval { periodEnd.timeIntervalSince(periodStart) }
    public var remainingSeconds: TimeInterval { max(0, periodEnd.timeIntervalSince(now)) }
    /// Fraction of the period's wall-clock elapsed (0…1).
    public var elapsedFraction: Double {
        totalSeconds > 0 ? min(1, max(0, elapsedSeconds / totalSeconds)) : 1
    }
}
