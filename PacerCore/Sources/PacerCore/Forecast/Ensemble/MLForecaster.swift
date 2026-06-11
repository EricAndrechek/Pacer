import Foundation

/// Feature engineering for the machine-learning forecast candidate, and the
/// candidate itself. Both are pure and `CreateML`-free so they unit-test like
/// the rest of the ensemble; the actual on-device training lives behind
/// `#if canImport(CreateML)` in `CreateMLTrainer` and is injected as a
/// prediction closure.
///
/// The whole point of routing ML through the tournament: the trained model is
/// *just another candidate*. It only gets used for a user if it beats the
/// simple methods in the backtest — so ML can only help, never regress a
/// user's displayed numbers.
public enum MLFeatures {
    /// The model maps these features → the period total. Kept as an ordered
    /// list so training columns and prediction rows can't drift.
    public static let featureKeys = [
        "soFar",             // cumulative so far this period
        "elapsedFraction",   // 0…1 of the period's wall-clock elapsed
        "hourOfDay",         // 0…23 (intraday rhythm)
        "weekday",           // 1…7 (weekly rhythm)
        "recentRate",        // recent slope of the cumulative curve (per second)
        "avgRateProjection", // soFar / elapsedFraction — the pace baseline, handed
                             // to the model directly so a tree can correct it
    ]
    public static let targetKey = "total"

    /// Featurize one input for prediction.
    public static func features(for input: ForecastInput, recentWindow: TimeInterval = 3600) -> [String: Double] {
        let f = input.elapsedFraction
        let hour = Double(input.calendar.component(.hour, from: input.now))
        let weekday = Double(input.calendar.component(.weekday, from: input.now))
        let avgProj = f > 0.02 ? input.soFar / f : input.soFar
        return [
            "soFar": input.soFar,
            "elapsedFraction": f,
            "hourOfDay": hour,
            "weekday": weekday,
            "recentRate": recentRate(input, window: recentWindow),
            "avgRateProjection": avgProj,
        ]
    }

    /// Recent slope of the cumulative curve, value-units per second.
    static func recentRate(_ input: ForecastInput, window: TimeInterval) -> Double {
        guard let last = input.elapsed.last else { return 0 }
        let cutoff = input.now.addingTimeInterval(-window)
        let earlier = input.elapsed.last(where: { $0.at <= cutoff }) ?? input.elapsed.first
        guard let earlier, last.at > earlier.at else { return 0 }
        return (last.cumulative - earlier.cumulative) / last.at.timeIntervalSince(earlier.at)
    }

    /// Build `(features, target)` training rows by replaying each prior
    /// complete period at several cut fractions — so the model learns "given
    /// this much done by this point, the period totalled that." Each row's
    /// features see only the data up to its cut; the target is the realized
    /// total. This is what makes the learned model an out-of-sample forecaster.
    public static func trainingRows(
        from priors: [ForecastInput.PriorPeriod],
        periodLength: TimeInterval,
        cutFractions: [Double] = [0.3, 0.45, 0.6, 0.75, 0.9],
        calendar: Calendar
    ) -> [(features: [String: Double], target: Double)] {
        var rows: [(features: [String: Double], target: Double)] = []
        for prior in priors {
            let total = prior.total
            guard total > 0 else { continue }
            let end = prior.start.addingTimeInterval(periodLength)
            for cf in cutFractions {
                let now = prior.start.addingTimeInterval(periodLength * cf)
                let elapsed = prior.points.filter { $0.at <= now }
                guard !elapsed.isEmpty else { continue }
                let input = ForecastInput(
                    now: now, periodStart: prior.start, periodEnd: end,
                    calendar: calendar, elapsed: elapsed, priorPeriods: [])
                rows.append((features(for: input), total))
            }
        }
        return rows
    }
}

/// A forecaster backed by a trained regression model, supplied as a pure
/// prediction closure. The closure is injected (by `CreateMLTrainer` in
/// production, or a stub in tests), keeping this type free of any ML
/// framework so it stays pure and testable. Highest `complexity` in the
/// roster — the selector's prefer-simpler rule means it has to *clearly* win
/// to be chosen.
public struct RegressorForecaster: Forecaster {
    public let id: String
    public let complexity: Int
    private let predict: @Sendable ([String: Double]) -> Double?

    public init(
        id: String = "ml-regressor",
        complexity: Int = 5,
        predict: @escaping @Sendable ([String: Double]) -> Double?
    ) {
        self.id = id
        self.complexity = complexity
        self.predict = predict
    }

    public func projectTotal(_ input: ForecastInput) -> Double? {
        guard let value = predict(MLFeatures.features(for: input)) else { return nil }
        // A regression tree can extrapolate to nonsense on out-of-distribution
        // inputs; never project below what's already spent.
        return max(value, input.soFar)
    }
}
