import Foundation

// Timestral (Mistral AI's time-series forecaster), ported to Swift with
// Accelerate from its inference code: https://github.com/mistralai/timestral
// at commit a534bdbd244d64f3d9d743f46c7bf6fc330ed4ff (`src/timestral/`),
// vendored unchanged in `research/arena/kit/fm/_vendor/timestral/`.
//
//   Copyright Mistral AI. Licensed under the Apache License, Version 2.0
//   (research/arena/kit/fm/_vendor/timestral/LICENSE). This port is a
//   translation of that code into Swift: same computation, same names; the
//   attention masks are built directly rather than with torch ops, the two
//   symmetric-averaging passes run as one batch, and categorical covariates
//   are left out.
//
// The weights are Mistral AI's, under their Modified MIT licence, which must
// travel with every copy: `ArenaWeightStore` keeps the pinned `LICENSE`
// beside each `model.safetensors` + `config.json` (in the app bundle and in
// downloads alike).
//
// File by file: `config.py` → `TimestralConfig`; `layers.py`, `masks.py`,
// `model.py` → `TimestralNetwork`; `scaler.py` → `TimestralScaler`;
// `forecaster.py` → `TimestralForecaster`. Shapes follow the Python's
// packed layout: one row per variate of every series, `(R, N, D)` for `N`
// patches, stored row-major in flat `Float` buffers.

/// `config.py` `TimestralConfig`: the fields that change the forward pass.
public struct TimestralConfig: Sendable, Decodable, Equatable {
    public let patch_size: Int
    public let d_model: Int
    public let num_heads: Int
    public let mlp_hidden_dim: Int
    public let block_schedule: [String]
    public let quantile_knots: [Double]
    public let block_size: Int
    public let context_length: Int
    public var rope_theta: Double = 10000.0
    public var rope_partial_factor: Double = 0.5
    public var norm_eps: Double = 1e-6
    public var attn_bias: Bool = false
    public var mlp_bias: Bool = false
    public var time_attn_gate: String = "sdpa_sigmoid"
    public var variate_attn_gate: String = "sdpa_sigmoid"
    public var minimum_scale: Double = 1e-6
    public var use_asinh: Bool = true
    public var stabilize_with_global: Bool = false
    public var covariate_enabled: Bool = true
    public var split_context_horizon_attn: Bool = true
    public var attend_missing_patches: Bool = true
    public var quantile_width_factor: Double = 2.0

    enum CodingKeys: String, CodingKey {
        case patch_size, d_model, num_heads, mlp_hidden_dim, block_schedule, quantile_knots, block_size,
             context_length, rope_theta, rope_partial_factor, norm_eps, attn_bias, mlp_bias, time_attn_gate,
             variate_attn_gate, minimum_scale, use_asinh, stabilize_with_global, covariate_enabled,
             split_context_horizon_attn, attend_missing_patches, quantile_width_factor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        patch_size = try c.decode(Int.self, forKey: .patch_size)
        d_model = try c.decode(Int.self, forKey: .d_model)
        num_heads = try c.decode(Int.self, forKey: .num_heads)
        mlp_hidden_dim = try c.decode(Int.self, forKey: .mlp_hidden_dim)
        block_schedule = try c.decode([String].self, forKey: .block_schedule)
        quantile_knots = try c.decode([Double].self, forKey: .quantile_knots)
        block_size = try c.decode(Int.self, forKey: .block_size)
        context_length = try c.decode(Int.self, forKey: .context_length)
        rope_theta = try c.decodeIfPresent(Double.self, forKey: .rope_theta) ?? rope_theta
        rope_partial_factor = try c.decodeIfPresent(Double.self, forKey: .rope_partial_factor) ?? rope_partial_factor
        norm_eps = try c.decodeIfPresent(Double.self, forKey: .norm_eps) ?? norm_eps
        attn_bias = try c.decodeIfPresent(Bool.self, forKey: .attn_bias) ?? attn_bias
        mlp_bias = try c.decodeIfPresent(Bool.self, forKey: .mlp_bias) ?? mlp_bias
        time_attn_gate = try c.decodeIfPresent(String.self, forKey: .time_attn_gate) ?? time_attn_gate
        variate_attn_gate = try c.decodeIfPresent(String.self, forKey: .variate_attn_gate) ?? variate_attn_gate
        minimum_scale = try c.decodeIfPresent(Double.self, forKey: .minimum_scale) ?? minimum_scale
        use_asinh = try c.decodeIfPresent(Bool.self, forKey: .use_asinh) ?? use_asinh
        stabilize_with_global = try c.decodeIfPresent(Bool.self, forKey: .stabilize_with_global) ?? stabilize_with_global
        covariate_enabled = try c.decodeIfPresent(Bool.self, forKey: .covariate_enabled) ?? covariate_enabled
        split_context_horizon_attn = try c.decodeIfPresent(Bool.self, forKey: .split_context_horizon_attn) ?? split_context_horizon_attn
        attend_missing_patches = try c.decodeIfPresent(Bool.self, forKey: .attend_missing_patches) ?? attend_missing_patches
        quantile_width_factor = try c.decodeIfPresent(Double.self, forKey: .quantile_width_factor) ?? quantile_width_factor
        try validate()
    }

    func validate() throws {
        func fail(_ s: String) -> Error { ArenaError.invalid("Timestral config: \(s)") }
        guard d_model % num_heads == 0 else { throw fail("d_model \(d_model) not divisible by num_heads \(num_heads)") }
        guard rope_dim > 0, rope_dim % 2 == 0 else { throw fail("invalid rope_dim \(rope_dim)") }
        for k in block_schedule where Self.layerKindAxes[k] == nil { throw fail("unknown layer kind \(k)") }
        for g in [time_attn_gate, variate_attn_gate] where g != "none" && g != "sdpa_sigmoid" {
            throw fail("unknown attention gate \(g)")
        }
        guard quantile_knots.contains(0.5) else { throw fail("quantile_knots must contain 0.5") }
        guard zip(quantile_knots, quantile_knots.dropFirst()).allSatisfy({ $0 < $1 }) else {
            throw fail("quantile_knots must be increasing")
        }
        // The advancing refine frame needs it off (config.py raises too).
        guard !stabilize_with_global else { throw fail("stabilize_with_global is not supported") }
    }

    /// Ordered attention axes each layer kind runs before its MLP; true = time.
    public static let layerKindAxes: [String: [Bool]] = [
        "time": [true], "variate": [false], "time_variate": [true, false], "variate_time": [false, true],
    ]

    public var head_dim: Int { d_model / num_heads }
    /// Head dimensions rotated by RoPE (`int(head_dim * rope_partial_factor)`).
    public var rope_dim: Int { Int(Double(head_dim) * rope_partial_factor) }
    public var num_quantiles: Int { quantile_knots.count }
    public var median_index: Int { quantile_knots.firstIndex(of: 0.5)! }

    /// Whether the schedule can route a known covariate's future to the targets.
    public var supports_known_covariates: Bool {
        guard covariate_enabled else { return false }
        let ops = block_schedule.flatMap { Self.layerKindAxes[$0] ?? [] }
        for (i, isTime) in ops.enumerated() {
            let rest = ops[(i + 1)...]
            if isTime && rest.contains(true) && !rest.allSatisfy({ $0 }) { return true }
        }
        return false
    }

    public static func load(_ url: URL) throws -> TimestralConfig {
        try JSONDecoder().decode(TimestralConfig.self, from: Data(contentsOf: url))
    }
}
