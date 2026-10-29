import Accelerate
import Foundation

/// `layers.py` + `masks.py` + `model.py`: the Timestral network and its
/// single-block forecast primitive, on the CPU in float32 with Accelerate.
///
/// The model normalizes each row causally per patch, embeds patches from
/// `[values, missing]` channels, runs a time/variate transformer over
/// `[Enc ; Dec]` tokens (context patches followed by learned forecast-query
/// tokens), and reads quantiles for every horizon time step from the
/// decoder tokens. The attention masks (`build_forecast_time_mask`,
/// `build_two_stream_time_mask`, `build_two_stream_variate_mask`,
/// `group_first_observed_patch`) are computed here from the observation
/// mask: the reason this is a hand port rather than a Core ML conversion
/// (their boolean indexing and `torch.unique` do not trace).
///
/// Thread-safe: weights are read-only, and each call takes its own scratch
/// buffers from a small pool (so a backfill reuses them instead of
/// allocating per forecast).
public final class TimestralNetwork: @unchecked Sendable {
    struct Linear {
        let w: UnsafePointer<Float>   // [out, in], nn.Linear's layout
        let b: UnsafePointer<Float>?
        let inp: Int
        let out: Int
    }

    struct ResidualBlock {
        let hidden: Linear, output: Linear, residual: Linear
    }

    struct Attention {
        let isTime: Bool
        let qkv: Linear
        let o: Linear
        let gate: Linear?
    }

    struct Block {
        let attnNorms: [UnsafePointer<Float>]
        let attns: [Attention]
        let mlpNorm: UnsafePointer<Float>
        let w12: Linear
        let w3: Linear
    }

    public let config: TimestralConfig
    public let parameterCount: Int
    let file: SafeTensors
    let patchProj: ResidualBlock
    let forecastQuery: UnsafePointer<Float>
    let layers: [Block]
    let outNorm: UnsafePointer<Float>
    let head: ResidualBlock
    /// SinCosRoPE's table: `head_dim / 2` entries, zero past `rope_dim / 2`
    /// (the identity rotation for the unrotated dimensions).
    let invFreq: [Float]
    private let pool = WorkspacePool()

    /// Loads `config.json` and `model.safetensors` from `directory` (strict:
    /// every tensor the network needs must be there with its exact shape).
    public init(directory: URL) throws {
        let config = try TimestralConfig.load(directory.appendingPathComponent("config.json"))
        let file = try SafeTensors(url: directory.appendingPathComponent("model.safetensors"))
        self.config = config
        self.file = file
        let d = config.d_model, ps = config.patch_size
        func lin(_ name: String, _ inp: Int, _ out: Int, bias: Bool) throws -> Linear {
            Linear(w: try file.floats("\(name).weight", shape: [out, inp]),
                   b: bias ? try file.floats("\(name).bias", shape: [out]) : nil, inp: inp, out: out)
        }
        func res(_ name: String, _ inp: Int, _ hid: Int, _ out: Int, bias: Bool) throws -> ResidualBlock {
            ResidualBlock(hidden: try lin("\(name).hidden_layer", inp, hid, bias: bias),
                          output: try lin("\(name).output_layer", hid, out, bias: bias),
                          residual: try lin("\(name).residual_layer", inp, out, bias: bias))
        }
        patchProj = try res("representation.patch_proj", 2 * ps, 4 * d, d, bias: true)
        forecastQuery = try file.floats("representation.forecast_query", shape: [d])
        var blocks: [Block] = []
        for (i, kind) in config.block_schedule.enumerated() {
            let p = "transformer.layers.\(i)"
            let axes = TimestralConfig.layerKindAxes[kind] ?? []
            var norms: [UnsafePointer<Float>] = [], attns: [Attention] = []
            for (j, isTime) in axes.enumerated() {
                norms.append(try file.floats("\(p).attn_norms.\(j).scale", shape: [d]))
                let gated = (isTime ? config.time_attn_gate : config.variate_attn_gate) == "sdpa_sigmoid"
                attns.append(Attention(
                    isTime: isTime,
                    qkv: try lin("\(p).attns.\(j).wQKV", d, 3 * d, bias: config.attn_bias),
                    o: try lin("\(p).attns.\(j).wO", d, d, bias: config.attn_bias),
                    gate: gated ? try lin("\(p).attns.\(j)._gate", d, d, bias: config.attn_bias) : nil))
            }
            blocks.append(Block(attnNorms: norms, attns: attns,
                                mlpNorm: try file.floats("\(p).mlp_norm.scale", shape: [d]),
                                w12: try lin("\(p).mlp.w12", d, 2 * config.mlp_hidden_dim, bias: config.mlp_bias),
                                w3: try lin("\(p).mlp.w3", config.mlp_hidden_dim, d, bias: config.mlp_bias)))
        }
        layers = blocks
        outNorm = try file.floats("transformer.out_norm.scale", shape: [d])
        head = try res("head.projection", d, 4 * d, ps * config.num_quantiles, bias: false)
        // `_build_inv_freq`, in float32 as torch computes it.
        let hd = config.head_dim, rd = config.rope_dim
        var inv = [Float](repeating: 0, count: hd / 2)
        for k in 0..<(rd / 2) {
            inv[k] = 1.0 / powf(Float(config.rope_theta), Float(2 * k) / Float(rd))
        }
        invFreq = inv
        parameterCount = file.entries.values.reduce(0) { $0 + $1.count }
    }

    // MARK: - Single-block forecasts (`TimestralModel.predict_block`)

    public static let roleTarget = 0, rolePastCov = 1, roleKnownCov = 2

    /// `predict_block`: forecast one block of `horizonPatches` patches after a
    /// packed context. `inputs`/`observed` are `(R, T)`, T a multiple of the
    /// patch size; `groupIds` `(R,)`. With covariate roles (and the known
    /// future over the block, `(R, h·ps)`), the window path. Returns
    /// raw-space quantiles `(R, h·ps, Q)`, non-decreasing along Q.
    func predictBlock(inputs: [Float], observed: [Bool], rows: Int, groupIds: [Int], horizonPatches h: Int,
                      roleIds: [Int]? = nil, knownFuture: [Float]? = nil, knownFutureMask: [Bool]? = nil) -> [Float] {
        let ps = config.patch_size
        let t = inputs.count / rows
        if roleIds == nil || !config.covariate_enabled || roleIds!.allSatisfy({ $0 == Self.roleTarget }) {
            return predictContextOnly(inputs: inputs, observed: observed, rows: rows, t: t, groupIds: groupIds, h: h)
        }
        let hl = h * ps
        let kf = knownFuture ?? [Float](repeating: 0, count: rows * hl)
        let kfm = knownFutureMask ?? [Bool](repeating: false, count: rows * hl)
        var full = [Float](), fullObs = [Bool]()
        full.reserveCapacity(rows * (t + hl)); fullObs.reserveCapacity(rows * (t + hl))
        for r in 0..<rows {
            full.append(contentsOf: inputs[(r * t)..<((r + 1) * t)]); full.append(contentsOf: kf[(r * hl)..<((r + 1) * hl)])
            fullObs.append(contentsOf: observed[(r * t)..<((r + 1) * t)]); fullObs.append(contentsOf: kfm[(r * hl)..<((r + 1) * hl)])
        }
        return predictWindow(inputs: full, observed: fullObs, rows: rows, w: t + hl, groupIds: groupIds, h: h,
                             roleIds: roleIds!)
    }

    /// `_predict_context_only`: encoder over the context, `h` forecast-query
    /// tokens after it.
    func predictContextOnly(inputs: [Float], observed: [Bool], rows: Int, t: Int, groupIds: [Int], h: Int) -> [Float] {
        let c = config, ps = c.patch_size
        precondition(t % ps == 0 && h >= 1 && groupIds.count == rows)
        let ll = t / ps, s = ll + h
        var loc = [Float](repeating: 0, count: rows * t), scale = loc, scaled = loc
        scaleRows(inputs, observed, rows: rows, t: t, scaled: &scaled, loc: &loc, scale: &scale)

        // Masks and positions, from the observation mask only.
        let obsPerPatch = Self.obsPerPatch(observed, rows: rows, n: ll, ps: ps)
        let keyValid = Self.encKeyValidity(obsPerPatch, rows: rows, n: ll, attendMissing: c.attend_missing_patches)
        let timeMask = Self.forecastTimeMask(contextLen: ll, horizon: h, keyValid: keyValid, rows: rows)
        let variateMask = Self.twoStreamVariateMask(groupIds: groupIds, encKeyValid: keyValid, rows: rows, nEnc: ll,
                                                    nDec: h, targetRows: nil, bidirectionalRows: nil)
        let firstObs = Self.groupFirstObservedPatch(obsPerPatch, rows: rows, n: ll, groupIds: groupIds)
        var positions = [Int](repeating: 0, count: rows * s)
        for r in 0..<rows { for p in 0..<s { positions[r * s + p] = p - firstObs[r] } }

        return pool.with { ws in
            let d = c.d_model
            let x = ws.buf(.x, rows * s * d)
            embed(scaled, observed, rows: rows, t: t, into: x, seq: s, ws: ws)
            for r in 0..<rows {
                for p in ll..<s { (x + (r * s + p) * d).update(from: forecastQuery, count: d) }
            }
            transformer(x, rows: rows, seq: s, timeMask: timeMask, variateMask: variateMask, positions: positions, ws: ws)
            return headQuantiles(x, rows: rows, seq: s, decFrom: ll, decCount: h, ws: ws) { r in
                (loc[r * t + (ll - 1) * ps], scale[r * t + (ll - 1) * ps])
            }
        }
    }

    /// `_predict_window`: with covariates, the encoder runs over context
    /// plus horizon, so known-future values are keys. Target and past-only
    /// rows keep a blank horizon; the masks keep target information out of
    /// covariate rows and any row's future out of the targets.
    func predictWindow(inputs: [Float], observed: [Bool], rows: Int, w: Int, groupIds: [Int], h: Int,
                       roleIds: [Int]) -> [Float] {
        let c = config, ps = c.patch_size
        precondition(w % ps == 0 && h >= 1 && h <= c.block_size)
        let n = w / ps, ll = n - h
        precondition(ll >= 1, "context must have at least one patch")
        let targetRows = roleIds.map { $0 == Self.roleTarget }
        let knownRows = roleIds.map { $0 == Self.roleKnownCov }

        var loc = [Float](repeating: 0, count: rows * w), scale = loc, scaled = loc
        scaleRows(inputs, observed, rows: rows, t: w, scaled: &scaled, loc: &loc, scale: &scale)
        // `_known_cov_scaling`: known-future rows use non-causal whole-row
        // statistics; indicator rows skip the asinh squash.
        for r in 0..<rows where knownRows[r] {
            let st = inputs.withUnsafeBufferPointer { ib in
                observed.withUnsafeBufferPointer { ob in
                    TimestralScaler.instanceNormStats(ib.baseAddress! + r * w, ob.baseAddress! + r * w, n: w,
                                                      minimumScale: c.minimum_scale)
                }
            }
            for i in 0..<w {
                var v = TimestralScaler.affineAsinh(inputs[r * w + i], loc: st.loc, scale: st.scale,
                                                    observed: observed[r * w + i], useAsinh: false)
                if c.use_asinh && observed[r * w + i] && !st.isBinary { v = asinhf(v) }
                scaled[r * w + i] = v; loc[r * w + i] = st.loc; scale[r * w + i] = st.scale
            }
        }

        let obsPerPatch = Self.obsPerPatch(observed, rows: rows, n: n, ps: ps)
        let keyValid = Self.encKeyValidity(obsPerPatch, rows: rows, n: n, attendMissing: c.attend_missing_patches)
        let fullMask = Self.twoStreamTimeMask(minContext: ll, n: n, blockSize: c.block_size, keyValid: keyValid,
                                              rows: rows, bidirectionalRows: knownRows)
        let fullVariate = Self.twoStreamVariateMask(groupIds: groupIds, encKeyValid: keyValid, rows: rows, nEnc: n,
                                                    nDec: n, targetRows: targetRows, bidirectionalRows: knownRows)
        let firstObs = Self.groupFirstObservedPatch(obsPerPatch, rows: rows, n: n, groupIds: groupIds)
        // The Python runs a decoder token for every patch of the window, but
        // only the horizon's `h` are active: an inactive one attends only to
        // itself, no active token or encoder token attends to it (the time
        // mask needs both decoder ends active; the variate mask mixes one
        // slot, whose tokens are all inactive or all active), and the head
        // reads only the horizon's. So they are left out: the same outputs,
        // bit for bit in exact arithmetic, for n + h tokens instead of 2n.
        let full = 2 * n
        let keep = Array(0..<n) + Array((n + ll)..<full)
        let s = keep.count
        var timeMask = [Float](repeating: Self.blocked, count: rows * s * s)
        for r in 0..<rows {
            for (i, ki) in keep.enumerated() {
                for (j, kj) in keep.enumerated() { timeMask[(r * s + i) * s + j] = fullMask[(r * full + ki) * full + kj] }
            }
        }
        let variateMask = fullVariate.map { fv in
            keep.flatMap { k in fv[(k * rows * rows)..<((k + 1) * rows * rows)] }
        }
        var positions = [Int](repeating: 0, count: rows * s)
        for r in 0..<rows { for (i, k) in keep.enumerated() { positions[r * s + i] = (k < n ? k : k - n) - firstObs[r] } }

        return pool.with { ws in
            let d = c.d_model
            let x = ws.buf(.x, rows * s * d)
            embed(scaled, observed, rows: rows, t: w, into: x, seq: s, ws: ws)
            for r in 0..<rows {
                for p in n..<s { (x + (r * s + p) * d).update(from: forecastQuery, count: d) }
            }
            transformer(x, rows: rows, seq: s, timeMask: timeMask, variateMask: variateMask, positions: positions, ws: ws)
            return headQuantiles(x, rows: rows, seq: s, decFrom: n, decCount: h, ws: ws) { r in
                (loc[r * w + (ll - 1) * ps], scale[r * w + (ll - 1) * ps])
            }
        }
    }

    /// `TimestralModel.scale`: causal per-patch normalization of packed rows.
    func scaleRows(_ inputs: [Float], _ observed: [Bool], rows: Int, t: Int,
                   scaled: inout [Float], loc: inout [Float], scale: inout [Float]) {
        let c = config
        inputs.withUnsafeBufferPointer { ib in
            observed.withUnsafeBufferPointer { ob in
                loc.withUnsafeMutableBufferPointer { lb in
                    scale.withUnsafeMutableBufferPointer { sb in
                        for r in 0..<rows {
                            TimestralScaler.causalPatchLocScale(ib.baseAddress! + r * t, ob.baseAddress! + r * t, t: t,
                                                                patchSize: c.patch_size, minimumScale: c.minimum_scale,
                                                                loc: lb.baseAddress! + r * t, scale: sb.baseAddress! + r * t)
                        }
                    }
                }
            }
        }
        for i in 0..<(rows * t) {
            scaled[i] = TimestralScaler.affineAsinh(inputs[i], loc: loc[i], scale: scale[i], observed: observed[i],
                                                    useAsinh: c.use_asinh)
        }
    }

    // MARK: - Layers

    /// `PatchRepresentation.forward`: `[values, missing]` per patch through
    /// the patch ResidualBlock, into the first `t / ps` tokens of each row.
    private func embed(_ scaled: [Float], _ observed: [Bool], rows: Int, t: Int,
                       into x: UnsafeMutablePointer<Float>, seq: Int, ws: Workspace) {
        let ps = config.patch_size, d = config.d_model, n = t / ps
        let m = rows * n
        let inp = ws.buf(.embedIn, m * 2 * ps)
        for r in 0..<rows {
            for p in 0..<n {
                let dst = inp + (r * n + p) * 2 * ps
                for i in 0..<ps {
                    let k = r * t + p * ps + i
                    dst[i] = scaled[k]
                    dst[ps + i] = observed[k] ? 0 : 1
                }
            }
        }
        let out = ws.buf(.embedOut, m * d)
        residualBlock(patchProj, inp, m, out, ws: ws)
        for r in 0..<rows {
            (x + r * seq * d).update(from: out + r * n * d, count: n * d)
        }
    }

    /// `ResidualBlock.forward`: `output(silu(hidden(x))) + residual(x)`.
    private func residualBlock(_ b: ResidualBlock, _ x: UnsafePointer<Float>, _ m: Int,
                               _ y: UnsafeMutablePointer<Float>, ws: Workspace) {
        let hid = ws.buf(.resHidden, m * b.hidden.out)
        Self.linear(b.hidden, x, m, hid)
        Self.silu(hid, m * b.hidden.out, ws: ws)
        Self.linear(b.output, hid, m, y)
        let r = ws.buf(.resResidual, m * b.residual.out)
        Self.linear(b.residual, x, m, r)
        vDSP_vadd(y, 1, r, 1, y, 1, vDSP_Length(m * b.residual.out))
    }

    /// `Transformer.forward` (with its RoPE tables and final norm), in place.
    private func transformer(_ x: UnsafeMutablePointer<Float>, rows: Int, seq: Int, timeMask: [Float],
                             variateMask: [Float]?, positions: [Int], ws: Workspace) {
        let c = config, d = c.d_model, hd = c.head_dim, half = hd / 2
        let m = rows * seq
        // SinCosRoPE: freqs = position · inv_freq (float32), emb = [freqs, freqs].
        let cosT = ws.buf(.cos, m * hd), sinT = ws.buf(.sin, m * hd)
        for i in 0..<m {
            let pos = Float(positions[i])
            for k in 0..<half {
                let f = invFreq[k] * pos
                let cv = cosf(f), sv = sinf(f)
                cosT[i * hd + k] = cv; cosT[i * hd + half + k] = cv
                sinT[i * hd + k] = sv; sinT[i * hd + half + k] = sv
            }
        }
        let xn = ws.buf(.xn, m * d)
        for layer in layers {
            for (norm, attn) in zip(layer.attnNorms, layer.attns) {
                rmsNorm(x, m, norm, xn)
                if attn.isTime {
                    timeAttention(attn, xn, rows: rows, seq: seq, mask: timeMask, cos: cosT, sin: sinT, residual: x, ws: ws)
                } else {
                    variateAttention(attn, xn, rows: rows, seq: seq, mask: variateMask, residual: x, ws: ws)
                }
            }
            rmsNorm(x, m, layer.mlpNorm, xn)
            mlp(layer, xn, m, residual: x, ws: ws)
        }
        rmsNorm(x, m, outNorm, x)
    }

    /// `RMSNorm`: `x · rsqrt(mean(x²) + eps) · scale`, per token.
    private func rmsNorm(_ x: UnsafePointer<Float>, _ m: Int, _ w: UnsafePointer<Float>, _ y: UnsafeMutablePointer<Float>) {
        let d = config.d_model
        let eps = Float(config.norm_eps)
        for i in 0..<m {
            var ss: Float = 0
            vDSP_svesq(x + i * d, 1, &ss, vDSP_Length(d))
            var inv = 1 / (ss / Float(d) + eps).squareRoot()
            vDSP_vsmul(x + i * d, 1, &inv, y + i * d, 1, vDSP_Length(d))
            vDSP_vmul(y + i * d, 1, w, 1, y + i * d, 1, vDSP_Length(d))
        }
    }

    /// Time attention (`Attention` with `is_time`): RoPE on q and k, masked
    /// softmax over the row's tokens, the sigmoid gate, `wO`; added to
    /// `residual`. The split context/horizon passes of `TwoStreamMask` are
    /// one masked pass here: the context never attends to the horizon, so
    /// both compute the same thing.
    private func timeAttention(_ a: Attention, _ xn: UnsafePointer<Float>, rows: Int, seq: Int, mask: [Float],
                               cos: UnsafePointer<Float>, sin: UnsafePointer<Float>,
                               residual: UnsafeMutablePointer<Float>, ws: Workspace) {
        let c = config, d = c.d_model, nh = c.num_heads, hd = c.head_dim, half = hd / 2
        let m = rows * seq
        let qkv = ws.buf(.qkv, m * 3 * d)
        Self.linear(a.qkv, xn, m, qkv)
        let out = ws.buf(.attn, m * d)
        let q = ws.buf(.q, seq * hd), k = ws.buf(.k, seq * hd), v = ws.buf(.v, seq * hd)
        let sc = ws.buf(.scores, seq * seq), o = ws.buf(.o, seq * hd)
        let alpha = 1 / Float(hd).squareRoot()
        mask.withUnsafeBufferPointer { mb in
            for r in 0..<rows {
                for h in 0..<nh {
                    // The fused projection's layout is (qkv, head_dim, n_heads).
                    for s in 0..<seq {
                        let src = qkv + (r * seq + s) * 3 * d
                        let cs = cos + (r * seq + s) * hd, sn = sin + (r * seq + s) * hd
                        for e in 0..<hd {
                            let qe = src[e * nh + h], ke = src[d + e * nh + h]
                            // rotate_half: (-x2, x1).
                            let qr = e < half ? -src[(e + half) * nh + h] : src[(e - half) * nh + h]
                            let kr = e < half ? -src[d + (e + half) * nh + h] : src[d + (e - half) * nh + h]
                            q[s * hd + e] = qe * cs[e] + qr * sn[e]
                            k[s * hd + e] = ke * cs[e] + kr * sn[e]
                            v[s * hd + e] = src[2 * d + e * nh + h]
                        }
                    }
                    Self.gemm(transB: true, m: seq, n: seq, k: hd, alpha: alpha, a: q, lda: hd, b: k, ldb: hd,
                              beta: 0, c: sc, ldc: seq)
                    vDSP_vadd(sc, 1, mb.baseAddress! + r * seq * seq, 1, sc, 1, vDSP_Length(seq * seq))
                    Self.softmaxRows(sc, rows: seq, cols: seq, ws: ws)
                    Self.gemm(transB: false, m: seq, n: hd, k: seq, alpha: 1, a: sc, lda: seq, b: v, ldb: hd,
                              beta: 0, c: o, ldc: hd)
                    // Heads concatenate head-major: (heads, head_dim).
                    for s in 0..<seq { (out + (r * seq + s) * d + h * hd).update(from: o + s * hd, count: hd) }
                }
            }
        }
        finishAttention(a, xn, out, m, residual: residual, ws: ws)
    }

    /// Variate attention (`Attention` without `is_time`): per patch slot,
    /// over the rows of the same series; no positional encoding. A row with
    /// no other row it may read (one series, one variate: the meter models)
    /// reads only itself, so its output is its own value vector.
    private func variateAttention(_ a: Attention, _ xn: UnsafePointer<Float>, rows: Int, seq: Int, mask: [Float]?,
                                  residual: UnsafeMutablePointer<Float>, ws: Workspace) {
        let c = config, d = c.d_model, nh = c.num_heads, hd = c.head_dim
        let m = rows * seq
        let qkv = ws.buf(.qkv, m * 3 * d)
        Self.linear(a.qkv, xn, m, qkv)
        let out = ws.buf(.attn, m * d)
        // Which (slot, row) may read another row at all.
        func alone(_ s: Int, _ r: Int) -> Bool {
            guard rows > 1 else { return true }
            guard let mask else { return false }
            for r2 in 0..<rows where r2 != r && mask[(s * rows + r) * rows + r2] == 0 { return false }
            return true
        }
        let alpha = 1 / Float(hd).squareRoot()
        let q = ws.buf(.q, rows * hd), k = ws.buf(.k, rows * hd), v = ws.buf(.v, rows * hd)
        let sc = ws.buf(.scores, rows * rows), o = ws.buf(.o, rows * hd)
        for s in 0..<seq {
            // A slot where every row reads only itself: each output is its value.
            if (0..<rows).allSatisfy({ alone(s, $0) }) {
                for r in 0..<rows {
                    let src = qkv + (r * seq + s) * 3 * d + 2 * d, dst = out + (r * seq + s) * d
                    for h in 0..<nh { for e in 0..<hd { dst[h * hd + e] = src[e * nh + h] } }
                }
                continue
            }
            for h in 0..<nh {
                for r in 0..<rows {
                    let src = qkv + (r * seq + s) * 3 * d
                    for e in 0..<hd {
                        q[r * hd + e] = src[e * nh + h]; k[r * hd + e] = src[d + e * nh + h]; v[r * hd + e] = src[2 * d + e * nh + h]
                    }
                }
                Self.gemm(transB: true, m: rows, n: rows, k: hd, alpha: alpha, a: q, lda: hd, b: k, ldb: hd,
                          beta: 0, c: sc, ldc: rows)
                if let mask {
                    mask.withUnsafeBufferPointer { mb in
                        vDSP_vadd(sc, 1, mb.baseAddress! + s * rows * rows, 1, sc, 1, vDSP_Length(rows * rows))
                    }
                }
                // A row allowed only itself gets weight exactly 1 on itself,
                // so its output is its value here too.
                Self.softmaxRows(sc, rows: rows, cols: rows, ws: ws)
                Self.gemm(transB: false, m: rows, n: hd, k: rows, alpha: 1, a: sc, lda: rows, b: v, ldb: hd,
                          beta: 0, c: o, ldc: hd)
                for r in 0..<rows { (out + (r * seq + s) * d + h * hd).update(from: o + r * hd, count: hd) }
            }
        }
        finishAttention(a, xn, out, m, residual: residual, ws: ws)
    }

    /// The gate (`out · sigmoid(x @ W_g)`), `wO`, and the residual add.
    private func finishAttention(_ a: Attention, _ xn: UnsafePointer<Float>, _ out: UnsafeMutablePointer<Float>,
                                 _ m: Int, residual: UnsafeMutablePointer<Float>, ws: Workspace) {
        let d = config.d_model
        if let g = a.gate {
            let gate = ws.buf(.gate, m * d)
            Self.linear(g, xn, m, gate)
            Self.sigmoid(gate, m * d, ws: ws)
            vDSP_vmul(out, 1, gate, 1, out, 1, vDSP_Length(m * d))
        }
        let y = ws.buf(.y, m * d)
        Self.linear(a.o, out, m, y)
        vDSP_vadd(residual, 1, y, 1, residual, 1, vDSP_Length(m * d))
    }

    /// `FusedSwiGLU`: `w3(gate · silu(up))`, `gate, up = w12(x).chunk(2)`;
    /// added to `residual`.
    private func mlp(_ layer: Block, _ xn: UnsafePointer<Float>, _ m: Int, residual: UnsafeMutablePointer<Float>,
                     ws: Workspace) {
        let f = layer.w3.inp, d = config.d_model
        let u = ws.buf(.mlpU, m * 2 * f)
        Self.linear(layer.w12, xn, m, u)
        let z = ws.buf(.mlpZ, m * f)
        for i in 0..<m { (z + i * f).update(from: u + i * 2 * f + f, count: f) }
        Self.silu(z, m * f, ws: ws)
        for i in 0..<m { vDSP_vmul(z + i * f, 1, u + i * 2 * f, 1, z + i * f, 1, vDSP_Length(f)) }
        let y = ws.buf(.y, m * d)
        Self.linear(layer.w3, z, m, y)
        vDSP_vadd(residual, 1, y, 1, residual, 1, vDSP_Length(m * d))
    }

    /// `QuantileHead` on the decoder tokens `[decFrom, decFrom + decCount)`
    /// of each row, made monotone, then denormalized with each row's anchor
    /// `(loc, scale)` (`denormalize_quantiles`). Returns `(R, decCount·ps, Q)`.
    private func headQuantiles(_ x: UnsafePointer<Float>, rows: Int, seq: Int, decFrom: Int, decCount: Int,
                               ws: Workspace, anchor: (Int) -> (Float, Float)) -> [Float] {
        let c = config, d = c.d_model, ps = c.patch_size, nq = c.num_quantiles
        let m = rows * decCount
        let dec = ws.buf(.headIn, m * d)
        for r in 0..<rows {
            (dec + r * decCount * d).update(from: x + (r * seq + decFrom) * d, count: decCount * d)
        }
        let raw = ws.buf(.headOut, m * ps * nq)
        residualBlock(head, dec, m, raw, ws: ws)
        var out = [Float](repeating: 0, count: m * ps * nq)
        let widths = Self.quantileWidths(c.quantile_knots, factor: c.quantile_width_factor)
        let mi = c.median_index
        out.withUnsafeMutableBufferPointer { ob in
            let o = ob.baseAddress!
            for r in 0..<rows {
                let (aLoc, aScale) = anchor(r)
                for j in 0..<(decCount * ps) {
                    let src = raw + (r * decCount * ps + j) * nq
                    let dst = o + (r * decCount * ps + j) * nq
                    Self.monotoneQuantiles(src, dst, nq: nq, median: mi, widths: widths)
                    for k in 0..<nq {
                        dst[k] = TimestralScaler.invertAffineAsinh(dst[k], loc: aLoc, scale: aScale, useAsinh: c.use_asinh)
                    }
                    TimestralScaler.clampNonfinite(dst, nq)
                }
            }
        }
        return out
    }

    /// `width_factor · dp` per level (float32), `dp` the probability gap to
    /// the next level inward.
    static func quantileWidths(_ levels: [Double], factor: Double) -> [Float] {
        let m = levels.firstIndex(of: 0.5)!
        var w = [Double](repeating: 0, count: levels.count)
        for i in (m + 1)..<levels.count { w[i] = levels[i] - levels[i - 1] }
        for i in 0..<m { w[i] = levels[i + 1] - levels[i] }
        // torch: `width_factor * widths_t` with widths_t float32.
        return w.map { Float(factor) * Float($0) }
    }

    /// `monotone_quantiles`: the median channel is free, the others fan out
    /// from it as `median ∓ cumsum(width · softplus(raw))`.
    @inline(__always)
    static func monotoneQuantiles(_ raw: UnsafePointer<Float>, _ out: UnsafeMutablePointer<Float>, nq: Int,
                                  median m: Int, widths: [Float]) {
        let med = raw[m]
        out[m] = med
        var acc: Float = 0
        for i in (m + 1)..<nq { acc += widths[i] * softplus(raw[i]); out[i] = med + acc }
        acc = 0
        var i = m - 1
        while i >= 0 { acc += widths[i] * softplus(raw[i]); out[i] = med - acc; i -= 1 }
        let big = Float.greatestFiniteMagnitude
        for k in 0..<nq { out[k] = min(max(out[k], -big), big) }
    }

    /// torch's softplus (beta 1, threshold 20).
    @inline(__always) static func softplus(_ x: Float) -> Float { x > 20 ? x : log1pf(expf(x)) }

    // MARK: - Masks (`masks.py`)

    /// `(R, N)`: whether any step of each patch is observed.
    static func obsPerPatch(_ observed: [Bool], rows: Int, n: Int, ps: Int) -> [Bool] {
        var out = [Bool](repeating: false, count: rows * n)
        let t = n * ps
        for r in 0..<rows { for p in 0..<n { for i in 0..<ps where observed[r * t + p * ps + i] { out[r * n + p] = true; break } } }
        return out
    }

    /// `compute_enc_key_validity`: a patch is a valid key if observed, or (with
    /// `attend_missing`) once the row's series has started.
    static func encKeyValidity(_ obs: [Bool], rows: Int, n: Int, attendMissing: Bool) -> [Bool] {
        guard attendMissing else { return obs }
        var out = obs
        for r in 0..<rows {
            var started = false
            for p in 0..<n { started = started || obs[r * n + p]; out[r * n + p] = obs[r * n + p] || started }
        }
        return out
    }

    static let blocked = -Float.infinity

    /// `build_forecast_time_mask`, additive (0 = attend, -inf = not), `(R, S, S)`:
    /// the encoder causal over valid keys (diagonal open), every decoder token
    /// reading the whole valid context and its own causal decoder chain.
    static func forecastTimeMask(contextLen ll: Int, horizon h: Int, keyValid: [Bool], rows: Int) -> [Float] {
        let s = ll + h
        var m = [Float](repeating: blocked, count: rows * s * s)
        for r in 0..<rows {
            let base = r * s * s
            for i in 0..<ll {
                for j in 0...i where keyValid[r * ll + j] || j == i { m[base + i * s + j] = 0 }
            }
            for i in 0..<h {
                for j in 0..<ll where keyValid[r * ll + j] { m[base + (ll + i) * s + j] = 0 }
                for j in 0...i { m[base + (ll + i) * s + ll + j] = 0 }
            }
        }
        return m
    }

    /// `build_two_stream_time_mask` (the covariate path), additive, `(R, 2N, 2N)`.
    static func twoStreamTimeMask(minContext s0: Int, n: Int, blockSize: Int, keyValid: [Bool], rows: Int,
                                  bidirectionalRows: [Bool]?) -> [Float] {
        let s = 2 * n
        // `compute_block_layout`: per decoder position, its block's anchor.
        var anchor = [Int](repeating: 0, count: n), active = [Bool](repeating: false, count: n)
        for p in 0..<n {
            active[p] = p >= s0
            anchor[p] = active[p] ? s0 + blockSize * (max(p - s0, 0) / blockSize) : 0
        }
        var m = [Float](repeating: blocked, count: rows * s * s)
        for r in 0..<rows {
            let base = r * s * s
            let bi = bidirectionalRows?[r] ?? false
            for i in 0..<n {
                for j in 0..<n where (keyValid[r * n + j] && (bi || j <= i)) || j == i { m[base + i * s + j] = 0 }
            }
            for i in 0..<n {
                for j in 0..<n where active[i] && j < anchor[i] && keyValid[r * n + j] { m[base + (n + i) * s + j] = 0 }
                for j in 0..<n where (anchor[i] == anchor[j] && j <= i && active[i] && active[j]) || j == i {
                    m[base + (n + i) * s + n + j] = 0
                }
            }
        }
        return m
    }

    /// `build_two_stream_variate_mask`, additive, `(N_enc + N_dec, R, R)`,
    /// or nil for a single row. A row reads another row of the same series;
    /// on encoder slots the key row must also be a valid key; the firewalls
    /// (a covariate never reads a target; a known-future row never reads a
    /// causal one) apply on every slot; the diagonal is always open.
    static func twoStreamVariateMask(groupIds: [Int], encKeyValid: [Bool], rows: Int, nEnc: Int, nDec: Int,
                                     targetRows: [Bool]?, bidirectionalRows: [Bool]?) -> [Float]? {
        guard rows > 1 else { return nil }
        let slots = nEnc + nDec
        var m = [Float](repeating: blocked, count: slots * rows * rows)
        for s in 0..<slots {
            for q in 0..<rows {
                for k in 0..<rows {
                    var ok = groupIds[q] == groupIds[k] && (s >= nEnc || encKeyValid[k * nEnc + s])
                    if let t = targetRows, !t[q] && t[k] { ok = false }
                    if let b = bidirectionalRows, b[q] && !b[k] { ok = false }
                    if ok || q == k { m[(s * rows + q) * rows + k] = 0 }
                }
            }
        }
        return m
    }

    /// `group_first_observed_patch(...)[inverse]`: per row, the first patch any
    /// row of its group observes (0 if none).
    static func groupFirstObservedPatch(_ obs: [Bool], rows: Int, n: Int, groupIds: [Int]) -> [Int] {
        var first: [Int: Int] = [:]
        for r in 0..<rows {
            if let p = (0..<n).first(where: { obs[r * n + $0] }) {
                first[groupIds[r]] = min(first[groupIds[r]] ?? .max, p)
            }
        }
        return groupIds.map { first[$0] ?? 0 }
    }

    // MARK: - Kernels

    /// `nn.Linear`: `y[m, out] = x[m, in] · Wᵀ (+ b)`.
    static func linear(_ l: Linear, _ x: UnsafePointer<Float>, _ m: Int, _ y: UnsafeMutablePointer<Float>) {
        gemm(transB: true, m: m, n: l.out, k: l.inp, alpha: 1, a: x, lda: l.inp, b: l.w, ldb: l.inp, beta: 0, c: y, ldc: l.out)
        if let b = l.b {
            for i in 0..<m { vDSP_vadd(y + i * l.out, 1, b, 1, y + i * l.out, 1, vDSP_Length(l.out)) }
        }
    }

    /// Row-major `C = alpha · A · op(B) + beta · C` (the classic CBLAS
    /// interface: the one call site of a deprecated-in-13.3 header symbol;
    /// the ILP64 interface needs a clang define SwiftPM cannot pass safely).
    static func gemm(transB: Bool, m: Int, n: Int, k: Int, alpha: Float, a: UnsafePointer<Float>, lda: Int,
                     b: UnsafePointer<Float>, ldb: Int, beta: Float, c: UnsafeMutablePointer<Float>, ldc: Int) {
        cblas_sgemm(CblasRowMajor, CblasNoTrans, transB ? CblasTrans : CblasNoTrans, Int32(m), Int32(n), Int32(k),
                    alpha, a, Int32(lda), b, Int32(ldb), beta, c, Int32(ldc))
    }

    /// In-place row softmax (rows always have a finite entry: the diagonal).
    static func softmaxRows(_ x: UnsafeMutablePointer<Float>, rows: Int, cols: Int, ws: Workspace) {
        var n = Int32(cols)
        for i in 0..<rows {
            let row = x + i * cols
            var mx: Float = 0
            vDSP_maxv(row, 1, &mx, vDSP_Length(cols))
            var neg = -mx
            vDSP_vsadd(row, 1, &neg, row, 1, vDSP_Length(cols))
            vvexpf(row, row, &n)
            var sum: Float = 0
            vDSP_sve(row, 1, &sum, vDSP_Length(cols))
            vDSP_vsdiv(row, 1, &sum, row, 1, vDSP_Length(cols))
        }
    }

    /// In-place `x · sigmoid(x)` (torch's silu).
    static func silu(_ x: UnsafeMutablePointer<Float>, _ n: Int, ws: Workspace) {
        let t = ws.buf(.act, n)
        sigmoidInto(x, t, n)
        vDSP_vmul(x, 1, t, 1, x, 1, vDSP_Length(n))
    }

    /// In-place logistic sigmoid.
    static func sigmoid(_ x: UnsafeMutablePointer<Float>, _ n: Int, ws: Workspace) {
        sigmoidInto(x, x, n)
    }

    /// `y = 1 / (1 + exp(-x))`.
    static func sigmoidInto(_ x: UnsafePointer<Float>, _ y: UnsafeMutablePointer<Float>, _ n: Int) {
        var minus: Float = -1, one: Float = 1
        var cnt = Int32(n)
        vDSP_vsmul(x, 1, &minus, y, 1, vDSP_Length(n))
        vvexpf(y, y, &cnt)
        vDSP_vsadd(y, 1, &one, y, 1, vDSP_Length(n))
        vvrecf(y, y, &cnt)
    }

    // MARK: - Scratch buffers

    enum Slot: Int, CaseIterable {
        case x, xn, qkv, attn, gate, y, mlpU, mlpZ, q, k, v, o, scores, cos, sin, act,
             embedIn, embedOut, resHidden, resResidual, headIn, headOut
    }

    /// One call's scratch buffers (`FMWorkspace`).
    typealias Workspace = FMWorkspace<Slot>

    /// See `FMScratch`: one kept, and only a small one.
    typealias WorkspacePool = FMWorkspacePool<Workspace>
}
