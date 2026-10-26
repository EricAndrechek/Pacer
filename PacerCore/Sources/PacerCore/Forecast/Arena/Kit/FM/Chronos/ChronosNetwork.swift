import Accelerate
import Foundation

/// `layers.py` + `model.py`: the Chronos-2 network, inference only, on the
/// CPU in float32 with Accelerate (licence and provenance: `ChronosConfig.swift`).
///
/// A T5-style encoder over patch tokens: each row of the batch is
/// instance-normalized (mean/std over its whole context, then `arcsinh`),
/// cut into patches of 16, and each patch embedded from `[time encoding,
/// values, observed mask]`; a `[REG]` token and one token per output patch
/// (embedded from their time encoding alone) follow. Every encoder block runs
/// time self-attention (RoPE, unscaled scores, over one row's tokens), group
/// self-attention (across the rows of one group at the same token slot) and
/// a ReLU feed-forward, each pre-normed and residual. The output tokens read
/// out 21 quantiles for each of their 16 steps, denormalized with the row's
/// own location and scale.
///
/// Thread-safe: weights are read-only, and each call takes its own scratch
/// buffers from a small pool (so a backfill reuses them instead of
/// allocating per forecast).
public final class ChronosNetwork: @unchecked Sendable {
    struct Linear {
        let w: UnsafePointer<Float>   // [out, in], nn.Linear's layout
        let b: UnsafePointer<Float>?
        let inp: Int
        let out: Int
    }

    /// `ResidualBlock`: `output(act(hidden(x))) + residual(x)`, every Linear
    /// with a bias, no layer norm (Chronos-2 builds both with the default).
    struct ResidualBlock {
        let hidden: Linear, output: Linear, residual: Linear
    }

    /// `MHA`: separate q, k, v, o projections, no biases.
    struct Attention {
        let norm: UnsafePointer<Float>
        let q: Linear, k: Linear, v: Linear, o: Linear
    }

    /// `Chronos2EncoderBlock`: `layer[0]` time, `layer[1]` group, `layer[2]` feed-forward.
    struct Block {
        let time: Attention
        let group: Attention
        let ffNorm: UnsafePointer<Float>
        let wi: Linear
        let wo: Linear
    }

    public let config: ChronosConfig
    public let parameterCount: Int
    let file: SafeTensors
    let inputPatchEmbedding: ResidualBlock
    let outputPatchEmbedding: ResidualBlock
    /// `shared.weight[reg_token_id]`, when the checkpoint uses a `[REG]` token.
    let regEmbedding: UnsafePointer<Float>?
    let blocks: [Block]
    let finalNorm: UnsafePointer<Float>
    /// `Chronos2RotaryEmbedding.inv_freq`, `d_kv / 2` entries, float32.
    let invFreq: [Float]
    /// The output patches' input embeddings, `[max_output_patches, d_model]`.
    /// Without future covariates a future patch is `[time encoding, 0…, 0…]`,
    /// which depends only on its index, so they are embedded once at load
    /// rather than on every forecast.
    let futureEmbeds: [Float]
    private let pool = WorkspacePool()

    public static let regTokenID = 1

    /// Loads `config.json` and `model.safetensors` from `directory` (strict:
    /// every tensor the network needs must be there with its exact shape).
    public init(directory: URL) throws {
        let config = try ChronosConfig.load(directory.appendingPathComponent("config.json"))
        let file = try SafeTensors(url: directory.appendingPathComponent("model.safetensors"))
        self.config = config
        self.file = file
        let d = config.d_model, ff = config.d_ff, inner = config.inner_dim, ps = config.patch_size
        func lin(_ name: String, _ inp: Int, _ out: Int, bias: Bool) throws -> Linear {
            Linear(w: try file.floats("\(name).weight", shape: [out, inp]),
                   b: bias ? try file.floats("\(name).bias", shape: [out]) : nil, inp: inp, out: out)
        }
        func res(_ name: String, _ inp: Int, _ hid: Int, _ out: Int) throws -> ResidualBlock {
            ResidualBlock(hidden: try lin("\(name).hidden_layer", inp, hid, bias: true),
                          output: try lin("\(name).output_layer", hid, out, bias: true),
                          residual: try lin("\(name).residual_layer", inp, out, bias: true))
        }
        func attn(_ p: String) throws -> Attention {
            Attention(norm: try file.floats("\(p).layer_norm.weight", shape: [d]),
                      q: try lin("\(p).self_attention.q", d, inner, bias: false),
                      k: try lin("\(p).self_attention.k", d, inner, bias: false),
                      v: try lin("\(p).self_attention.v", d, inner, bias: false),
                      o: try lin("\(p).self_attention.o", inner, d, bias: false))
        }
        // x3 for [time_embedding, patch, patch_mask].
        inputPatchEmbedding = try res("input_patch_embedding", 3 * ps, ff, d)
        outputPatchEmbedding = try res("output_patch_embedding", d, ff, config.num_quantiles * config.chronos_config.output_patch_size)
        let vocab = config.chronos_config.use_reg_token ? 2 : 1
        let shared = try file.floats("shared.weight", shape: [vocab, d])
        regEmbedding = config.chronos_config.use_reg_token ? shared + Self.regTokenID * d : nil
        var bs: [Block] = []
        for i in 0..<config.num_layers {
            let p = "encoder.block.\(i).layer"
            bs.append(Block(time: try attn("\(p).0"), group: try attn("\(p).1"),
                            ffNorm: try file.floats("\(p).2.layer_norm.weight", shape: [d]),
                            wi: try lin("\(p).2.mlp.wi", d, ff, bias: false),
                            wo: try lin("\(p).2.mlp.wo", ff, d, bias: false)))
        }
        blocks = bs
        finalNorm = try file.floats("encoder.final_layer_norm.weight", shape: [d])
        // `compute_default_rope_parameters`: 1 / base^(arange(0, dim, 2) / dim),
        // the exponent and the power in float32 as torch computes them.
        let dk = config.d_kv
        invFreq = (0..<(dk / 2)).map { k in 1.0 / powf(Float(config.rope_theta), Float(2 * k) / Float(dk)) }
        parameterCount = file.entries.values.reduce(0) { $0 + $1.count }

        // `_prepare_patched_future` without covariates, every patch the
        // model can emit: time encoding `[0, 1, …) / time_encoding_scale`.
        let maxOut = config.chronos_config.max_output_patches
        var feats = [Float](repeating: 0, count: maxOut * 3 * ps)
        let tes = Float(config.time_encoding_scale)
        for n in 0..<maxOut { for i in 0..<ps { feats[n * 3 * ps + i] = Float(n * ps + i) / tes } }
        var fut = [Float](repeating: 0, count: maxOut * d)
        let block = inputPatchEmbedding
        pool.with { ws in
            feats.withUnsafeBufferPointer { fb in
                fut.withUnsafeMutableBufferPointer { ob in
                    Self.residualBlock(block, fb.baseAddress!, maxOut, ob.baseAddress!, ws: ws)
                }
            }
        }
        futureEmbeds = fut
    }

    // MARK: - Forward (`Chronos2Model.forward`, inference)

    /// The model's quantile predictions for `rows` series of `t` steps each
    /// (`context` row-major, NaN = missing): `(rows, Q, numOutputPatches ·
    /// patch)`, denormalized (`instance_norm.inverse`). Rows with the same
    /// `groupIds` value attend to each other (`group_ids`; the pipeline
    /// gives a multivariate series' variates one group).
    func forward(context: [Float], rows: Int, t: Int, groupIds: [Int], numOutputPatches nOut: Int) -> [Float] {
        let c = config, d = c.d_model, ps = c.patch_size, nq = c.num_quantiles
        precondition(context.count == rows * t && groupIds.count == rows && t >= 1)
        precondition(nOut >= 1 && nOut <= c.chronos_config.max_output_patches)

        // `_prepare_patched_context`: keep the last `context_length` steps,
        // scale each row, then left-pad to whole patches (padding is missing).
        let tt = min(t, c.chronos_config.context_length)
        let cut = t - tt
        let pad = tt % ps == 0 ? 0 : ps - tt % ps
        let tp = tt + pad, np = tp / ps
        let reg = regEmbedding != nil ? 1 : 0
        let s = np + reg + nOut
        var loc = [Float](repeating: 0, count: rows), scale = [Float](repeating: 1, count: rows)
        var feats = [Float](repeating: 0, count: rows * np * 3 * ps)
        // 1 where a token may be attended to (`attention_mask`), per row.
        var keyMask = [Float](repeating: 1, count: rows * s)
        let tes = Float(c.time_encoding_scale)
        for r in 0..<rows {
            let row = context[(r * t + cut)..<((r + 1) * t)]
            let (l, sc) = Self.instanceNormStats(row)
            loc[r] = l; scale[r] = sc
            let fb = r * np * 3 * ps
            for p in 0..<np {
                var any = false
                for i in 0..<ps {
                    let f = fb + p * 3 * ps
                    // context_time_enc: [-C, …, -1] / time_encoding_scale over the padded length.
                    feats[f + i] = Float(-tp + p * ps + i) / tes
                    let k = p * ps + i - pad
                    guard k >= 0 else { continue }
                    let x = row[row.startIndex + k]
                    guard !x.isNaN else { continue }
                    var z = (x - l) / sc
                    if c.chronos_config.use_arcsinh { z = asinhf(z) }
                    feats[f + ps + i] = z
                    feats[f + 2 * ps + i] = 1
                    any = true
                }
                keyMask[r * s + p] = any ? 1 : 0
            }
        }

        return pool.with { ws in
            let x = ws.buf(.x, rows * s * d)
            let emb = ws.buf(.embed, rows * np * d)
            feats.withUnsafeBufferPointer { fb in
                Self.residualBlock(inputPatchEmbedding, fb.baseAddress!, rows * np, emb, ws: ws)
            }
            futureEmbeds.withUnsafeBufferPointer { fe in
                for r in 0..<rows {
                    let xr = x + r * s * d
                    xr.update(from: emb + r * np * d, count: np * d)
                    if let regEmbedding { (xr + np * d).update(from: regEmbedding, count: d) }
                    (xr + (np + reg) * d).update(from: fe.baseAddress!, count: nOut * d)
                }
            }
            encoder(x, rows: rows, seq: s, keyMask: keyMask, groupIds: groupIds, ws: ws)

            // `output_patch_embedding` on the last `nOut` tokens of each row.
            let m = rows * nOut
            let dec = ws.buf(.headIn, m * d)
            for r in 0..<rows { (dec + r * nOut * d).update(from: x + (r * s + s - nOut) * d, count: nOut * d) }
            let width = nq * ps
            let raw = ws.buf(.headOut, m * width)
            Self.residualBlock(outputPatchEmbedding, dec, m, raw, ws: ws)
            // "b n (q p) -> b q (n p)", then `instance_norm.inverse`.
            let h = nOut * ps
            var out = [Float](repeating: 0, count: rows * nq * h)
            for r in 0..<rows {
                for n in 0..<nOut {
                    let src = raw + (r * nOut + n) * width
                    for q in 0..<nq {
                        for p in 0..<ps {
                            var v = src[q * ps + p]
                            if c.chronos_config.use_arcsinh { v = sinhf(v) }
                            out[(r * nq + q) * h + n * ps + p] = v * scale[r] + loc[r]
                        }
                    }
                }
            }
            return out
        }
    }

    /// `InstanceNorm.forward`'s statistics for one row (float32 output, the
    /// sums in float64): the mean and the population std of the observed
    /// values; no observed value gives `(0, 1)`, a constant row a scale of
    /// `eps` (1e-5).
    static func instanceNormStats(_ row: ArraySlice<Float>) -> (loc: Float, scale: Float) {
        var n = 0, sum = 0.0
        for x in row where !x.isNaN { n += 1; sum += Double(x) }
        guard n > 0 else { return (0, 1) }   // nan_to_num(nanmean) → 0, nan_to_num(std) → 1
        let loc = Float(sum / Double(n))
        var ss = 0.0
        for x in row where !x.isNaN { let dlt = x - loc; ss += Double(dlt * dlt) }
        let sc = Float(ss / Double(n)).squareRoot()
        return (loc, sc == 0 ? 1e-5 : sc)
    }

    /// `Chronos2Encoder.forward`, in place on `x` `(rows, seq, d)`.
    private func encoder(_ x: UnsafeMutablePointer<Float>, rows: Int, seq: Int, keyMask: [Float], groupIds: [Int],
                         ws: Workspace) {
        let c = config, d = c.d_model, dk = c.d_kv, half = dk / 2
        let m = rows * seq
        // `_expand_and_invert_time_attention_mask`: (1 - mask) · finfo.min, added to scores.
        let tMask = keyMask.map { (1 - $0) * Self.maskMin }
        // `Chronos2RotaryEmbedding.forward`: position_ids = arange(seq) for every row.
        let cosT = ws.buf(.cos, seq * half), sinT = ws.buf(.sin, seq * half)
        for p in 0..<seq {
            for k in 0..<half {
                let f = invFreq[k] * Float(p)
                cosT[p * half + k] = cosf(f); sinT[p * half + k] = sinf(f)
            }
        }
        let xn = ws.buf(.xn, m * d)
        for b in blocks {
            Self.rmsNorm(x, m, b.time.norm, xn, d: d, eps: Float(c.layer_norm_epsilon))
            timeAttention(b.time, xn, rows: rows, seq: seq, mask: tMask, cos: cosT, sin: sinT, residual: x, ws: ws)
            Self.rmsNorm(x, m, b.group.norm, xn, d: d, eps: Float(c.layer_norm_epsilon))
            groupAttention(b.group, xn, rows: rows, seq: seq, keyMask: keyMask, groupIds: groupIds, residual: x, ws: ws)
            Self.rmsNorm(x, m, b.ffNorm, xn, d: d, eps: Float(c.layer_norm_epsilon))
            feedForward(b, xn, m, residual: x, ws: ws)
        }
        Self.rmsNorm(x, m, finalNorm, x, d: d, eps: Float(c.layer_norm_epsilon))
    }

    /// `TimeSelfAttention`: RoPE on q and k, unscaled scores (Chronos-2's
    /// T5 lineage: `scale=1.0`), the key mask, softmax over the row's
    /// tokens, `o`; added to `residual`.
    private func timeAttention(_ a: Attention, _ xn: UnsafePointer<Float>, rows: Int, seq: Int, mask: [Float],
                               cos: UnsafePointer<Float>, sin: UnsafePointer<Float>,
                               residual: UnsafeMutablePointer<Float>, ws: Workspace) {
        let c = config, inner = c.inner_dim, nh = c.num_heads, dk = c.d_kv, half = dk / 2
        let m = rows * seq
        let q = ws.buf(.q, m * inner), k = ws.buf(.k, m * inner), v = ws.buf(.v, m * inner)
        Self.linear(a.q, xn, m, q); Self.linear(a.k, xn, m, k); Self.linear(a.v, xn, m, v)
        // apply_rotary_pos_emb: x·cos + rotate_half(x)·sin, per head ("b s (h d)").
        for i in 0..<m {
            let cs = cos + (i % seq) * half, sn = sin + (i % seq) * half
            for buf in [q, k] {
                for h in 0..<nh {
                    let p = buf + i * inner + h * dk
                    for e in 0..<half {
                        let x1 = p[e], x2 = p[e + half]
                        p[e] = x1 * cs[e] + (-x2) * sn[e]
                        p[e + half] = x2 * cs[e] + x1 * sn[e]
                    }
                }
            }
        }
        let out = ws.buf(.attn, m * inner)
        let sc = ws.buf(.scores, seq * seq)
        mask.withUnsafeBufferPointer { mb in
            for r in 0..<rows {
                let base = r * seq * inner
                let mrow = mb.baseAddress! + r * seq
                for h in 0..<nh {
                    Self.gemm(transB: true, m: seq, n: seq, k: dk, alpha: 1, a: q + base + h * dk, lda: inner,
                              b: k + base + h * dk, ldb: inner, beta: 0, c: sc, ldc: seq)
                    for i in 0..<seq { vDSP_vadd(sc + i * seq, 1, mrow, 1, sc + i * seq, 1, vDSP_Length(seq)) }
                    Self.softmaxRows(sc, rows: seq, cols: seq)
                    Self.gemm(transB: false, m: seq, n: dk, k: seq, alpha: 1, a: sc, lda: seq,
                              b: v + base + h * dk, ldb: inner, beta: 0, c: out + base + h * dk, ldc: inner)
                }
            }
        }
        let y = ws.buf(.y, m * c.d_model)
        Self.linear(a.o, out, m, y)
        vDSP_vadd(residual, 1, y, 1, residual, 1, vDSP_Length(m * c.d_model))
    }

    /// `GroupSelfAttention`: at each token slot, across the batch's rows; a
    /// row reads the rows of its own group whose token there may be attended
    /// to (`_construct_and_invert_group_time_mask`). No positional encoding.
    ///
    /// A batch of one row (every meter forecast) reads only itself: one key,
    /// softmax weight exactly 1, so its output is its value vector (and q, k
    /// are not computed). With several rows the scores carry the additive
    /// `finfo.min` mask in float32, as torch's do: where every key of a row
    /// is masked they all round to the same value and the row averages the
    /// whole batch. That is upstream behaviour, kept for parity.
    private func groupAttention(_ a: Attention, _ xn: UnsafePointer<Float>, rows: Int, seq: Int, keyMask: [Float],
                                groupIds: [Int], residual: UnsafeMutablePointer<Float>, ws: Workspace) {
        let c = config, inner = c.inner_dim, nh = c.num_heads, dk = c.d_kv, d = c.d_model
        let m = rows * seq
        let v = ws.buf(.v, m * inner)
        Self.linear(a.v, xn, m, v)
        let out: UnsafeMutablePointer<Float>
        if rows == 1 {
            out = v
        } else {
            let q = ws.buf(.q, m * inner), k = ws.buf(.k, m * inner)
            Self.linear(a.q, xn, m, q); Self.linear(a.k, xn, m, k)
            out = ws.buf(.attn, m * inner)
            let sc = ws.buf(.scores, rows * rows)
            let gm = ws.buf(.groupMask, rows * rows)
            let stride = seq * inner
            for t in 0..<seq {
                for qi in 0..<rows {
                    for bi in 0..<rows {
                        let open = groupIds[qi] == groupIds[bi] ? keyMask[bi * seq + t] : 0
                        gm[qi * rows + bi] = (1 - open) * Self.maskMin
                    }
                }
                for h in 0..<nh {
                    let off = t * inner + h * dk
                    Self.gemm(transB: true, m: rows, n: rows, k: dk, alpha: 1, a: q + off, lda: stride,
                              b: k + off, ldb: stride, beta: 0, c: sc, ldc: rows)
                    vDSP_vadd(sc, 1, gm, 1, sc, 1, vDSP_Length(rows * rows))
                    Self.softmaxRows(sc, rows: rows, cols: rows)
                    Self.gemm(transB: false, m: rows, n: dk, k: rows, alpha: 1, a: sc, lda: rows,
                              b: v + off, ldb: stride, beta: 0, c: out + off, ldc: stride)
                }
            }
        }
        let y = ws.buf(.y, m * d)
        Self.linear(a.o, out, m, y)
        vDSP_vadd(residual, 1, y, 1, residual, 1, vDSP_Length(m * d))
    }

    /// `FeedForward`: `wo(relu(wi(x)))`, added to `residual`.
    private func feedForward(_ b: Block, _ xn: UnsafePointer<Float>, _ m: Int, residual: UnsafeMutablePointer<Float>,
                             ws: Workspace) {
        let ff = b.wi.out, d = config.d_model
        let hdn = ws.buf(.ffHidden, m * ff)
        Self.linear(b.wi, xn, m, hdn)
        Self.relu(hdn, m * ff)
        let y = ws.buf(.y, m * d)
        Self.linear(b.wo, hdn, m, y)
        vDSP_vadd(residual, 1, y, 1, residual, 1, vDSP_Length(m * d))
    }

    // MARK: - Kernels

    /// `torch.finfo(float32).min`, the inverted masks' fill.
    static let maskMin = -Float.greatestFiniteMagnitude

    /// `Chronos2LayerNorm` (T5's: no mean, no bias): `w · x · rsqrt(mean(x²) + eps)`.
    static func rmsNorm(_ x: UnsafePointer<Float>, _ m: Int, _ w: UnsafePointer<Float>, _ y: UnsafeMutablePointer<Float>,
                        d: Int, eps: Float) {
        for i in 0..<m {
            var ss: Float = 0
            vDSP_svesq(x + i * d, 1, &ss, vDSP_Length(d))
            var inv = 1 / (ss / Float(d) + eps).squareRoot()
            vDSP_vsmul(x + i * d, 1, &inv, y + i * d, 1, vDSP_Length(d))
            vDSP_vmul(y + i * d, 1, w, 1, y + i * d, 1, vDSP_Length(d))
        }
    }

    /// `ResidualBlock.forward` with ReLU.
    static func residualBlock(_ b: ResidualBlock, _ x: UnsafePointer<Float>, _ m: Int,
                              _ y: UnsafeMutablePointer<Float>, ws: Workspace) {
        let hid = ws.buf(.resHidden, m * b.hidden.out)
        linear(b.hidden, x, m, hid)
        relu(hid, m * b.hidden.out)
        linear(b.output, hid, m, y)
        let r = ws.buf(.resResidual, m * b.residual.out)
        linear(b.residual, x, m, r)
        vDSP_vadd(y, 1, r, 1, y, 1, vDSP_Length(m * b.residual.out))
    }

    /// `nn.Linear`: `y[m, out] = x[m, in] · Wᵀ (+ b)`.
    static func linear(_ l: Linear, _ x: UnsafePointer<Float>, _ m: Int, _ y: UnsafeMutablePointer<Float>) {
        gemm(transB: true, m: m, n: l.out, k: l.inp, alpha: 1, a: x, lda: l.inp, b: l.w, ldb: l.inp, beta: 0, c: y, ldc: l.out)
        if let b = l.b {
            for i in 0..<m { vDSP_vadd(y + i * l.out, 1, b, 1, y + i * l.out, 1, vDSP_Length(l.out)) }
        }
    }

    /// Row-major `C = alpha · A · op(B) + beta · C` (the classic CBLAS
    /// interface, as `TimestralNetwork.gemm`: the ILP64 one needs a clang
    /// define SwiftPM cannot pass safely).
    static func gemm(transB: Bool, m: Int, n: Int, k: Int, alpha: Float, a: UnsafePointer<Float>, lda: Int,
                     b: UnsafePointer<Float>, ldb: Int, beta: Float, c: UnsafeMutablePointer<Float>, ldc: Int) {
        cblas_sgemm(CblasRowMajor, CblasNoTrans, transB ? CblasTrans : CblasNoTrans, Int32(m), Int32(n), Int32(k),
                    alpha, a, Int32(lda), b, Int32(ldb), beta, c, Int32(ldc))
    }

    /// In-place row softmax (every row has an unmasked entry or, all masked,
    /// equal ones: never all `-inf`).
    static func softmaxRows(_ x: UnsafeMutablePointer<Float>, rows: Int, cols: Int) {
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

    /// In-place `max(x, 0)`.
    static func relu(_ x: UnsafeMutablePointer<Float>, _ n: Int) {
        var zero: Float = 0
        vDSP_vthr(x, 1, &zero, x, 1, vDSP_Length(n))
    }

    // MARK: - Scratch buffers

    enum Slot: Int, CaseIterable {
        case x, xn, q, k, v, attn, y, scores, groupMask, cos, sin, ffHidden, embed, resHidden, resResidual, headIn, headOut
    }

    /// One call's scratch buffers, grown on demand and kept for the next.
    final class Workspace {
        private var ptrs = [UnsafeMutablePointer<Float>?](repeating: nil, count: Slot.allCases.count)
        private var caps = [Int](repeating: 0, count: Slot.allCases.count)
        func buf(_ s: Slot, _ n: Int) -> UnsafeMutablePointer<Float> {
            let i = s.rawValue
            if caps[i] < n {
                ptrs[i]?.deallocate()
                let c = max(n, caps[i] * 3 / 2)
                ptrs[i] = .allocate(capacity: c)
                caps[i] = c
            }
            return ptrs[i]!
        }
        var bytes: Int { caps.reduce(0, +) * MemoryLayout<Float>.size }
        deinit { for p in ptrs { p?.deallocate() } }
    }

    /// Workspaces for concurrent callers: one per call in flight, kept for reuse.
    final class WorkspacePool: @unchecked Sendable {
        private var free: [Workspace] = []
        private let lock = NSLock()
        func with<T>(_ body: (Workspace) throws -> T) rethrows -> T {
            lock.lock()
            let ws = free.popLast() ?? Workspace()
            lock.unlock()
            defer { lock.lock(); if free.count < 4 { free.append(ws) }; lock.unlock() }
            return try body(ws)
        }
    }
}
