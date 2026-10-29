import Foundation

/// `models/g1-01-sonnet-calstack/model.py`: a stack of the calibrated
/// Timestral-123M (`g1-01-sonnet-calibrate123`) and TimesFM 2.5
/// (`fm-timesfm25-meter`). Two architectures (Mistral's and Google's) whose
/// errors should be partly independent, so a CRPS-minimizing stack can beat
/// either alone.
///
/// `kit/ml/combine.Combiner` with the stack rule: per kind of meter, the
/// simplex weights minimizing the discounted CRPS of the mixture over the
/// children's scored backtests, shrunk toward equal (`shrink`), then the
/// children's paths pooled as a mixture.
public final class CalstackModel: KitMLCombiner {
    override public class var rule: String { "stack" }
    override public class var defaultPool: String { "mixture" }

    override public func weightsFor(_ kind: String, _ tr: ArenaTargetRequest, _ children: [String],
                                    _ paths: [[[Double]]], now: Millis) -> [Double] {
        let groups = ledger.scored(kind, before: now)
        return KitMLCombine.stackWeights(groups, children, pool: poolKind, halfLife: halfLife(kind),
                                         shrink: cfg.double("shrink", 0.15))
    }
}
