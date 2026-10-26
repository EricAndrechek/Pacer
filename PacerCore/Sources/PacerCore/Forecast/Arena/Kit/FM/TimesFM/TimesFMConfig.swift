import Foundation

/// `timesfm_2p5_base.TimesFM_2p5_200M_Definition`: TimesFM 2.5's
/// architecture, from the checkpoint's `config.json` (the Hugging Face
/// `TimesFmModelForPrediction` keys), falling back to the Definition's
/// constants for a key the file does not carry. The Python module ignores
/// `config.json` and hard-codes the Definition; reading it here only lets a
/// different checkpoint fail loudly (every tensor is then loaded against
/// these shapes) instead of being misread.
public struct TimesFMConfig: Sendable, Equatable {
    public var contextLimit = 16_384           // context_length
    public var inputPatchLen = 32              // patch_length (p)
    public var outputPatchLen = 128            // horizon_length (o)
    public var outputQuantileLen = 1_024       // quantile_horizon_length (os)
    public var quantiles: [Double] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9]
    /// The quantile the decoder feeds back (index into the 10 outputs: 0 is
    /// the mean head, 1…9 the quantiles; 5 is the median).
    public var decodeIndex = 5
    public var modelDims = 1_280               // hidden_size (md)
    public var hiddenDims = 1_280              // intermediate_size
    public var numHeads = 16                   // num_attention_heads (h)
    public var numLayers = 20                  // num_hidden_layers (x)
    public var rmsEps = 1e-6

    public var headDim: Int { modelDims / numHeads }               // hd = 80
    /// Outputs per time step: the mean, then the quantiles (q = 10).
    public var numOutputs: Int { quantiles.count + 1 }
    /// Input patches per output patch (m = o / p = 4).
    public var patchesPerOutput: Int { outputPatchLen / inputPatchLen }

    public init() {}

    public static func load(_ url: URL) throws -> TimesFMConfig {
        let data = try Data(contentsOf: url)
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ArenaError.invalid("TimesFM config.json is not a JSON object")
        }
        var c = TimesFMConfig()
        func int(_ k: String, _ d: Int) -> Int { (j[k] as? NSNumber)?.intValue ?? d }
        c.contextLimit = int("context_length", c.contextLimit)
        c.inputPatchLen = int("patch_length", c.inputPatchLen)
        c.outputPatchLen = int("horizon_length", c.outputPatchLen)
        c.outputQuantileLen = int("quantile_horizon_length", c.outputQuantileLen)
        c.modelDims = int("hidden_size", c.modelDims)
        c.hiddenDims = int("intermediate_size", c.hiddenDims)
        c.numHeads = int("num_attention_heads", c.numHeads)
        c.numLayers = int("num_hidden_layers", c.numLayers)
        if let q = (j["quantiles"] as? [NSNumber])?.map(\.doubleValue) { c.quantiles = q }
        if let e = (j["rms_norm_eps"] as? NSNumber)?.doubleValue { c.rmsEps = e }
        if let hd = (j["head_dim"] as? NSNumber)?.intValue, hd != c.headDim {
            throw ArenaError.invalid("TimesFM config: head_dim \(hd) is not hidden_size / heads \(c.headDim)")
        }
        guard c.outputPatchLen % c.inputPatchLen == 0, c.modelDims % c.numHeads == 0, c.headDim % 2 == 0,
              c.decodeIndex < c.numOutputs else {
            throw ArenaError.invalid("TimesFM config: inconsistent sizes")
        }
        return c
    }
}
