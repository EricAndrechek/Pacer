import Foundation

// Chronos-2 (Amazon's time-series foundation model), ported to Swift with
// Accelerate from its inference code: the `chronos-forecasting` package,
// version 2.3.2 (https://github.com/amazon-science/chronos-forecasting,
// `src/chronos/chronos2/` and `InstanceNorm`/`Patch` in `chronos_bolt.py`),
// the version the arena pins (`models/fm-chronos2-meter/model.toml` deps).
//
//   Copyright Amazon.com, Inc. or its affiliates. Licensed under the Apache
//   License, Version 2.0 (SPDX-License-Identifier: Apache-2.0). This port is
//   a translation of that code into Swift: same computation, same names;
//   training, fine-tuning, covariates and the long-horizon unrolling are left
//   out (no arena meter model reaches them).
//
// The weights (`amazon/chronos-2`) are Amazon's, under Apache-2.0 as the
// model card at the pinned revision states; `ArenaWeightStore` keeps that
// card (`README.md`, the repository has no separate LICENSE file) beside
// each downloaded `model.safetensors` + `config.json`.
//
// File by file: `config.py` → `ChronosConfig`; `layers.py` and `model.py`
// → `ChronosNetwork`; `pipeline.py` (`predict_quantiles` on a tensor) →
// `ChronosPipeline`; the arena's `Chronos2Backend` → `ChronosBackend`.

/// `config.py` `Chronos2CoreConfig` with its `Chronos2ForecastingConfig`
/// (`config.json` `chronos_config`): the fields that change the forward pass.
public struct ChronosConfig: Sendable, Decodable, Equatable {
    public let d_model: Int
    public let d_kv: Int
    public let d_ff: Int
    public let num_layers: Int
    public let num_heads: Int
    public var layer_norm_epsilon: Double = 1e-6
    public var feed_forward_proj: String = "relu"
    public var rope_theta: Double = 10000.0
    public let chronos_config: Forecasting

    public struct Forecasting: Sendable, Decodable, Equatable {
        public let context_length: Int
        public let input_patch_size: Int
        public let input_patch_stride: Int
        public let output_patch_size: Int
        public let quantiles: [Double]
        public var use_reg_token: Bool = false
        public var use_arcsinh: Bool = false
        public var max_output_patches: Int = 1
        /// Defaults to `context_length` (`Chronos2Model.__init__`).
        public var time_encoding_scale: Int?

        enum CodingKeys: String, CodingKey {
            case context_length, input_patch_size, input_patch_stride, output_patch_size, quantiles, use_reg_token,
                 use_arcsinh, max_output_patches, time_encoding_scale
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            context_length = try c.decode(Int.self, forKey: .context_length)
            input_patch_size = try c.decode(Int.self, forKey: .input_patch_size)
            input_patch_stride = try c.decode(Int.self, forKey: .input_patch_stride)
            output_patch_size = try c.decode(Int.self, forKey: .output_patch_size)
            quantiles = try c.decode([Double].self, forKey: .quantiles)
            use_reg_token = try c.decodeIfPresent(Bool.self, forKey: .use_reg_token) ?? use_reg_token
            use_arcsinh = try c.decodeIfPresent(Bool.self, forKey: .use_arcsinh) ?? use_arcsinh
            max_output_patches = try c.decodeIfPresent(Int.self, forKey: .max_output_patches) ?? max_output_patches
            time_encoding_scale = try c.decodeIfPresent(Int.self, forKey: .time_encoding_scale)
        }
    }

    enum CodingKeys: String, CodingKey {
        case d_model, d_kv, d_ff, num_layers, num_heads, layer_norm_epsilon, feed_forward_proj, rope_theta,
             chronos_config
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        d_model = try c.decode(Int.self, forKey: .d_model)
        d_kv = try c.decode(Int.self, forKey: .d_kv)
        d_ff = try c.decode(Int.self, forKey: .d_ff)
        num_layers = try c.decode(Int.self, forKey: .num_layers)
        num_heads = try c.decode(Int.self, forKey: .num_heads)
        layer_norm_epsilon = try c.decodeIfPresent(Double.self, forKey: .layer_norm_epsilon) ?? layer_norm_epsilon
        feed_forward_proj = try c.decodeIfPresent(String.self, forKey: .feed_forward_proj) ?? feed_forward_proj
        rope_theta = try c.decodeIfPresent(Double.self, forKey: .rope_theta) ?? rope_theta
        chronos_config = try c.decode(Forecasting.self, forKey: .chronos_config)
        try validate()
    }

    func validate() throws {
        func fail(_ s: String) -> Error { ArenaError.invalid("Chronos-2 config: \(s)") }
        let f = chronos_config
        // `Chronos2Model.__init__` asserts these; the patching here assumes
        // non-overlapping patches as well (`Patch` with stride == size).
        guard f.input_patch_size == f.output_patch_size else { throw fail("input and output patch sizes differ") }
        guard f.input_patch_stride == f.input_patch_size else { throw fail("overlapping patches are not ported") }
        // Only the activation the released checkpoint uses (`ACT2FN["relu"]`).
        guard feed_forward_proj == "relu" else { throw fail("feed_forward_proj \(feed_forward_proj) is not ported") }
        guard d_kv % 2 == 0, num_heads * d_kv > 0 else { throw fail("invalid head shape") }
        guard f.quantiles.contains(0.5) else { throw fail("quantiles must contain 0.5") }
        guard zip(f.quantiles, f.quantiles.dropFirst()).allSatisfy({ $0 < $1 }) else {
            throw fail("quantiles must be increasing")
        }
    }

    /// `n_heads * d_kv`, the attention's inner width.
    public var inner_dim: Int { num_heads * d_kv }
    public var num_quantiles: Int { chronos_config.quantiles.count }
    public var patch_size: Int { chronos_config.input_patch_size }
    public var time_encoding_scale: Int { chronos_config.time_encoding_scale ?? chronos_config.context_length }
    /// `Chronos2Pipeline.model_prediction_length`: what one forward pass covers.
    public var model_prediction_length: Int { chronos_config.max_output_patches * chronos_config.output_patch_size }

    public static func load(_ url: URL) throws -> ChronosConfig {
        try JSONDecoder().decode(ChronosConfig.self, from: Data(contentsOf: url))
    }
}
