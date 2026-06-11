import Foundation

/// Scores forecasters by **out-of-sample forecast error** — walk-forward,
/// not in-sample fit.
///
/// This is the crux of the tournament. A tempting-but-wrong score is how
/// well a method fits the curve it already saw (R²): optimizing that picks
/// the most *overfit* model, which forecasts worse. Instead each case is a
/// past cut-point where the forecaster saw only the data up to then; we score
/// its projection against what the period *actually* totalled. Same data the
/// manual before/afters used this whole time, just systematized.
public enum Backtester {

    /// One backtest case: an input as it would have looked at some past
    /// cut-point, paired with the period's realized total.
    public struct Case: Sendable {
        public let input: ForecastInput
        public let truth: Double
        public init(input: ForecastInput, truth: Double) {
            self.input = input
            self.truth = truth
        }
    }

    /// A forecaster's aggregate performance over the cases.
    public struct Score: Sendable, Equatable {
        public let id: String
        public let complexity: Int
        /// Median absolute percentage error over cases it could project
        /// (robust to the occasional wild miss). The primary ranking metric.
        public let medianAbsPctError: Double
        public let meanAbsPctError: Double
        /// Fraction of cases the forecaster produced a (non-nil) projection
        /// for. A method that only fires on 20% of cases isn't usable even if
        /// it's accurate when it does.
        public let coverage: Double
        /// Number of cases it scored on.
        public let scoredCount: Int
    }

    public static func score(forecasters: [any Forecaster], cases: [Case]) -> [Score] {
        forecasters.map { forecaster in
            var errors: [Double] = []
            for c in cases {
                guard c.truth > 0, let projection = forecaster.projectTotal(c.input) else { continue }
                errors.append(abs(projection - c.truth) / c.truth * 100)
            }
            let coverage = cases.isEmpty ? 0 : Double(errors.count) / Double(cases.count)
            return Score(
                id: forecaster.id,
                complexity: forecaster.complexity,
                medianAbsPctError: median(errors),
                meanAbsPctError: errors.isEmpty ? .infinity : errors.reduce(0, +) / Double(errors.count),
                coverage: coverage,
                scoredCount: errors.count
            )
        }
    }

    private static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return .infinity }
        let s = xs.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
}
