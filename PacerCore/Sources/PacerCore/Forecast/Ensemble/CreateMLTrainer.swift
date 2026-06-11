#if canImport(CreateML)
import Foundation
import TabularData
import CreateML

/// On-device training for the ML forecast candidate, using Apple's Create ML
/// (`MLBoostedTreeRegressor`). macOS only — guarded by `canImport(CreateML)`,
/// so on any platform without it the roster simply has no ML candidate and
/// nothing breaks.
///
/// Training happens off the render path (on the scan tick); the result is a
/// pure `(features) -> Double?` closure handed to a `RegressorForecaster`, so
/// the rest of the ensemble never sees a Create ML type. The selector decides
/// whether the trained model actually earns a spot — it only gets used if it
/// beats the simple methods in the backtest.
public enum CreateMLTrainer {

    /// Train a boosted-tree regressor on `(features, target)` rows and return
    /// a prediction closure, or `nil` if there's too little data or training
    /// throws. `minRows` guards against fitting noise on a thin history.
    public static func trainedPredictor(
        rows: [(features: [String: Double], target: Double)],
        minRows: Int = 30
    ) -> (@Sendable ([String: Double]) -> Double?)? {
        guard rows.count >= minRows else { return nil }

        var training = DataFrame()
        for key in MLFeatures.featureKeys {
            training.append(column: Column(name: key, contents: rows.map { $0.features[key] ?? 0 }))
        }
        training.append(column: Column(name: MLFeatures.targetKey, contents: rows.map { $0.target }))

        guard let regressor = try? MLBoostedTreeRegressor(
            trainingData: training, targetColumn: MLFeatures.targetKey
        ) else { return nil }

        // CreateML/CoreML models aren't Sendable, but inference is read-only
        // and we call it serially (on the scan tick / cached selection), so an
        // unchecked box is a sound, pragmatic way to satisfy the Sendable
        // `Forecaster`.
        let box = RegressorBox(regressor)
        return { features in
            var row = DataFrame()
            for key in MLFeatures.featureKeys {
                row.append(column: Column(name: key, contents: [features[key] ?? 0]))
            }
            guard let predictions = try? box.regressor.predictions(from: row) else { return nil }
            return predictions.assumingType(Double.self).first ?? nil
        }
    }
}

private final class RegressorBox: @unchecked Sendable {
    let regressor: MLBoostedTreeRegressor
    init(_ regressor: MLBoostedTreeRegressor) { self.regressor = regressor }
}
#endif
