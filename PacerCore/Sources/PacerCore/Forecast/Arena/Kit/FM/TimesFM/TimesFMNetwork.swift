import Accelerate
import Foundation

/// `timesfm_2p5_torch.TimesFM_2p5_200M_torch_module` (with `torch/dense.py`,
/// `torch/transformer.py`, `torch/normalization.py`, `torch/util.py`): the
/// TimesFM 2.5 network and its `decode`, on the CPU in float32 with
/// Accelerate, from the pinned safetensors.
///
/// A decoder-only transformer over 32-step input patches: each patch
/// (normalized by the running mean and deviation of the series so far) and
/// its padding mask are embedded by a residual MLP, run through 20 causal
/// layers (fused QKV, RoPE, RMS-normed queries and keys, a learned
/// per-dimension query scale, unscaled softmax), and the last patch's
/// embedding is read by two heads: 128 steps × (mean + 9 quantiles), and the
/// continuous quantile head's 1024 steps × 10. Past 128 steps the median is
/// fed back four patches at a time against a KV cache (`decode`).
///
/// Thread-safe: weights are read-only (memory-mapped, file-backed), and each
/// call takes its scratch buffers, KV cache included, from a small pool.
public final class TimesFMNetwork: @unchecked Sendable {
    struct Linear {
        let w: UnsafePointer<Float>   // [out, in], nn.Linear's layout
        let b: UnsafePointer<Float>?
        let inp: Int
        let out: Int
    }

    /// `dense.ResidualBlock`: `output(swish(hidden(x))) + residual(x)`.
    struct ResidualBlock {
        let hidden: Linear, output: Linear, residual: Linear
    }

    /// `transformer.Transformer` (with its `MultiHeadAttention`).
    struct Layer {
        let preAttnLn: UnsafePointer<Float>, postAttnLn: UnsafePointer<Float>
        let preFfLn: UnsafePointer<Float>, postFfLn: UnsafePointer<Float>
        let qkv: Linear, out: Linear, ff0: Linear, ff1: Linear
        let queryLn: UnsafePointer<Float>, keyLn: UnsafePointer<Float>
        /// `PerDimScale`: `1.442695041 / sqrt(hd) · softplus(per_dim_scale)`.
        let queryScale: [Float]
    }

    public let config: TimesFMConfig
    public let parameterCount: Int
    let file: SafeTensors
    let tokenizer: ResidualBlock
    let layers: [Layer]
    let pointHead: ResidualBlock
    let quantileHead: ResidualBlock
    /// `RotaryPositionalEmbedding`'s timescales, `hd / 2` of them, in float32
    /// as torch computes them.
    let timescale: [Float]
    private let pool = WorkspacePool()

    /// Loads `config.json` and `model.safetensors` from `directory` (strict:
    /// every tensor `load_state_dict(strict=True)` wants, with its shape).
    public init(directory: URL) throws {
        let config = try TimesFMConfig.load(directory.appendingPathComponent("config.json"))
        let file = try SafeTensors(url: directory.appendingPathComponent("model.safetensors"))
        self.config = config
        self.file = file
        let d = config.modelDims, p = config.inputPatchLen, hd = config.headDim, nq = config.numOutputs
        func lin(_ name: String, _ inp: Int, _ out: Int, bias: Bool) throws -> Linear {
            Linear(w: try file.floats("\(name).weight", shape: [out, inp]),
                   b: bias ? try file.floats("\(name).bias", shape: [out]) : nil, inp: inp, out: out)
        }
        func res(_ name: String, _ inp: Int, _ hid: Int, _ out: Int, bias: Bool) throws -> ResidualBlock {
            ResidualBlock(hidden: try lin("\(name).hidden_layer", inp, hid, bias: bias),
                          output: try lin("\(name).output_layer", hid, out, bias: bias),
                          residual: try lin("\(name).residual_layer", inp, out, bias: bias))
        }
        // TimesFM_2p5_200M_Definition: tokenizer 64 → 1280 → 1280 with bias;
        // the heads without; point 1280 → o·q, quantiles 1280 → os·q.
        tokenizer = try res("tokenizer", 2 * p, d, d, bias: true)
        pointHead = try res("output_projection_point", d, d, config.outputPatchLen * nq, bias: false)
        quantileHead = try res("output_projection_quantiles", d, d, config.outputQuantileLen * nq, bias: false)
        let base = Float(1.442695041 / Double(hd).squareRoot())
        layers = try (0..<config.numLayers).map { i in
            let n = "stacked_xf.\(i)"
            let pds = try file.floats("\(n).attn.per_dim_scale.per_dim_scale", shape: [hd])
            return Layer(
                preAttnLn: try file.floats("\(n).pre_attn_ln.scale", shape: [d]),
                postAttnLn: try file.floats("\(n).post_attn_ln.scale", shape: [d]),
                preFfLn: try file.floats("\(n).pre_ff_ln.scale", shape: [d]),
                postFfLn: try file.floats("\(n).post_ff_ln.scale", shape: [d]),
                qkv: try lin("\(n).attn.qkv_proj", d, 3 * d, bias: false),
                out: try lin("\(n).attn.out", d, d, bias: false),
                ff0: try lin("\(n).ff0", d, config.hiddenDims, bias: false),
                ff1: try lin("\(n).ff1", config.hiddenDims, d, bias: false),
                queryLn: try file.floats("\(n).attn.query_ln.scale", shape: [hd]),
                keyLn: try file.floats("\(n).attn.key_ln.scale", shape: [hd]),
                queryScale: (0..<hd).map { base * Self.softplus(pds[$0]) })
        }
        // fraction = 2 · arange(hd / 2) / hd; timescale = 1 · (1e4 / 1) ** fraction.
        timescale = (0..<(hd / 2)).map { k in powf(10_000, Float(2 * k) / Float(hd)) }
        parameterCount = file.entries.values.reduce(0) { $0 + $1.count }
    }

    // MARK: - decode

    /// `decode(horizon, inputs, masks)` for `rows` series of `context` steps
    /// (a multiple of the input patch; `masks` true = padding, which only
    /// ever covers part of the first patch: the arena compiles the context
    /// to the series' length rounded up to a patch, so no patch is wholly
    /// masked and `num_masked` is 0 throughout).
    ///
    /// Returns, renormalized: `pf` `[rows][o][q]`, the last context patch's
    /// point head; `qs` `[rows][os][q]`, its quantile head; `ar`
    /// `[rows][steps · o][q]`, the autoregressive steps' point heads.
    func decode(horizon: Int, inputs: [Float], masks: [Bool], rows: Int, context: Int) throws
        -> (pf: [Float], qs: [Float], ar: [Float], steps: Int) {
        let c = config, p = c.inputPatchLen, o = c.outputPatchLen, nq = c.numOutputs, m = c.patchesPerOutput
        guard context % p == 0, inputs.count == rows * context, masks.count == rows * context else {
            throw ArenaError.invalid("TimesFM decode: context \(context) is not a whole number of patches")
        }
        let steps = (horizon - 1) / o
        let nPatches = context / p
        for r in 0..<rows where masks[r * context + p - 1] {
            throw ArenaError.invalid("TimesFM decode: a wholly padded patch (not compiled this way)")
        }
        return pool.with { ws in
            let cache = KVCache(ws: ws, layers: c.numLayers, rows: rows, heads: c.numHeads,
                                size: nPatches + steps * m, headDim: c.headDim)
            // Running stats per patch, then the normalized, mask-zeroed patches.
            var n = [Float](repeating: 0, count: rows), mu = n, sigma = n
            var patchMu = [Float](repeating: 0, count: rows * nPatches), patchSigma = patchMu
            let tok = ws.buf(.tokIn, rows * nPatches * 2 * p)
            for r in 0..<rows {
                for i in 0..<nPatches {
                    let off = r * context + i * p
                    (n[r], mu[r], sigma[r]) = Self.updateRunningStats(n[r], mu[r], sigma[r], inputs, masks, off, p)
                    patchMu[r * nPatches + i] = mu[r]; patchSigma[r * nPatches + i] = sigma[r]
                    let t = tok + (r * nPatches + i) * 2 * p
                    let s = Self.guarded(sigma[r])
                    for j in 0..<p {
                        t[j] = masks[off + j] ? 0 : (inputs[off + j] - mu[r]) / s
                        t[p + j] = masks[off + j] ? 1 : 0
                    }
                }
            }
            var lastN = n, lastMu = mu, lastSigma = sigma
            let last = forward(tok, rows: rows, tokens: nPatches, cache: cache, ws: ws)   // [rows][d]
            let pfRaw = ws.buf(.point, rows * o * nq)
            residualBlock(pointHead, last, rows, pfRaw, ws: ws)
            let qsRaw = ws.buf(.quant, rows * c.outputQuantileLen * nq)
            residualBlock(quantileHead, last, rows, qsRaw, ws: ws)
            var pf = [Float](repeating: 0, count: rows * o * nq)
            var qs = [Float](repeating: 0, count: rows * c.outputQuantileLen * nq)
            for r in 0..<rows {
                let lm = patchMu[r * nPatches + nPatches - 1], ls = patchSigma[r * nPatches + nPatches - 1]
                for k in 0..<(o * nq) { pf[r * o * nq + k] = pfRaw[r * o * nq + k] * ls + lm }
                let qn = c.outputQuantileLen * nq
                for k in 0..<qn { qs[r * qn + k] = qsRaw[r * qn + k] * ls + lm }
            }
            // Autoregressive decode: the median of the last output patch, as
            // m new input patches, against the cache.
            var ar = [Float](repeating: 0, count: rows * steps * o * nq)
            var feed = (0..<rows).map { r in (0..<o).map { pf[(r * o + $0) * nq + c.decodeIndex] } }
            let noMask = [Bool](repeating: false, count: o)
            for s in 0..<steps {
                var newMu = [Float](repeating: 0, count: rows * m), newSigma = newMu
                let tokAR = ws.buf(.tokIn, rows * m * 2 * p)
                for r in 0..<rows {
                    var (nn, mm, ss) = (lastN[r], lastMu[r], lastSigma[r])
                    for i in 0..<m {
                        (nn, mm, ss) = Self.updateRunningStats(nn, mm, ss, feed[r], noMask, i * p, p)
                        newMu[r * m + i] = mm; newSigma[r * m + i] = ss
                        let t = tokAR + (r * m + i) * 2 * p
                        let g = Self.guarded(ss)
                        for j in 0..<p { t[j] = (feed[r][i * p + j] - mm) / g; t[p + j] = 0 }
                    }
                    (lastN[r], lastMu[r], lastSigma[r]) = (nn, mm, ss)
                }
                let lastAR = forward(tokAR, rows: rows, tokens: m, cache: cache, ws: ws)
                residualBlock(pointHead, lastAR, rows, pfRaw, ws: ws)
                for r in 0..<rows {
                    let lm = newMu[r * m + m - 1], ls = newSigma[r * m + m - 1]
                    let dst = (r * steps + s) * o * nq
                    for k in 0..<(o * nq) { ar[dst + k] = pfRaw[r * o * nq + k] * ls + lm }
                    feed[r] = (0..<o).map { ar[dst + $0 * nq + c.decodeIndex] }
                }
            }
            return (pf, qs, ar, steps)
        }
    }

    /// `util.update_running_stats` over `x[off ..< off + count]`, in float32
    /// as torch computes it (the sums accumulate in Double, then round: within
    /// an ulp of torch's float32 reductions).
    static func updateRunningStats(_ n: Float, _ mu: Float, _ sigma: Float, _ x: [Float], _ mask: [Bool],
                                   _ off: Int, _ count: Int) -> (Float, Float, Float) {
        var cnt = 0.0, sum = 0.0
        for j in 0..<count where !mask[off + j] { cnt += 1; sum += Double(x[off + j]) }
        let incN = Float(cnt)
        let incNSafe: Float = incN == 0 ? 1 : incN
        let incMu: Float = incN == 0 ? 0 : Float(sum) / incNSafe
        var sq = 0.0
        for j in 0..<count where !mask[off + j] {
            let dv = x[off + j] - incMu
            sq += Double(dv * dv)
        }
        let incVar: Float = incN == 0 ? 0 : Float(sq) / incNSafe
        let incSigma = incVar.squareRoot()
        let newN = n + incN
        let newNSafe: Float = newN == 0 ? 1 : newN
        let newMu: Float = newN == 0 ? 0 : (n * mu + incMu * incN) / newNSafe
        let t1 = n * (sigma * sigma)
        let t2 = incN * (incSigma * incSigma)
        let t3 = n * ((mu - newMu) * (mu - newMu))
        let t4 = incN * ((incMu - newMu) * (incMu - newMu))
        let newVar: Float = newN == 0 ? 0 : (t1 + t2 + t3 + t4) / newNSafe
        return (newN, newMu, max(newVar, 0).squareRoot())
    }

    /// `revin`'s divisor: a deviation under `_TOLERANCE` (1e-6) divides by 1.
    /// (The reverse direction multiplies by the deviation as it is.)
    @inline(__always) static func guarded(_ s: Float) -> Float { s < 1e-6 ? 1 : s }

    // MARK: - forward

    /// `forward` over `tokens` new patches per row (`tok` `[rows][tokens][2p]`:
    /// the normalized values, then the mask) against the cache, which it
    /// advances. Returns the last new token's output embedding per row
    /// (`[rows][d]`, a workspace buffer): the only one any head reads.
    private func forward(_ tok: UnsafePointer<Float>, rows: Int, tokens: Int, cache: KVCache,
                         ws: Workspace) -> UnsafePointer<Float> {
        let c = config, d = c.modelDims, hd = c.headDim, nh = c.numHeads, half = hd / 2
        let mt = rows * tokens
        let x = ws.buf(.x, mt * d)
        residualBlock(tokenizer, tok, mt, x, ws: ws)
        // RoPE at positions next_index + i (num_masked is 0): float32 angles.
        let start = cache.nextIndex
        let cosT = ws.buf(.cos, tokens * half), sinT = ws.buf(.sin, tokens * half)
        for i in 0..<tokens {
            let pos = Float(start + i)
            for k in 0..<half {
                let a = pos / timescale[k]
                cosT[i * half + k] = cosf(a); sinT[i * half + k] = sinf(a)
            }
        }
        let xn = ws.buf(.xn, mt * d)
        let qkv = ws.buf(.qkv, mt * 3 * d)
        let att = ws.buf(.att, mt * d)
        let y = ws.buf(.y, mt * d)
        let hid = ws.buf(.ffHidden, mt * c.hiddenDims)
        let keys = start + tokens
        let scores = ws.buf(.scores, tokens * keys)
        for (li, layer) in layers.enumerated() {
            // Attention.
            rmsNorm(x, mt, d, layer.preAttnLn, xn)
            Self.linear(layer.qkv, xn, mt, qkv)
            for r in 0..<rows {
                for i in 0..<tokens {
                    let row = qkv + (r * tokens + i) * 3 * d
                    for h in 0..<nh {
                        let q = row + h * hd, k = row + d + h * hd, v = row + 2 * d + h * hd
                        Self.rotary(q, half, cosT + i * half, sinT + i * half)
                        Self.rotary(k, half, cosT + i * half, sinT + i * half)
                        rmsNorm(q, 1, hd, layer.queryLn, q)
                        rmsNorm(k, 1, hd, layer.keyLn, k)
                        layer.queryScale.withUnsafeBufferPointer { vDSP_vmul(q, 1, $0.baseAddress!, 1, q, 1, vDSP_Length(hd)) }
                        let slot = start + i
                        (cache.k(li, r, h) + slot * hd).update(from: k, count: hd)
                        (cache.v(li, r, h) + slot * hd).update(from: v, count: hd)
                    }
                }
                for h in 0..<nh {
                    // softmax(q · kᵀ) · v over keys 0 ... next_index + i (scale 1).
                    let q0 = qkv + r * tokens * 3 * d + h * hd
                    Self.gemm(transB: true, m: tokens, n: keys, k: hd, a: q0, lda: 3 * d,
                              b: cache.k(li, r, h), ldb: hd, c: scores, ldc: keys)
                    for i in 0..<tokens where start + i + 1 < keys {
                        let rowp = scores + i * keys
                        for j in (start + i + 1)..<keys { rowp[j] = -.infinity }
                    }
                    Self.softmaxRows(scores, rows: tokens, cols: keys)
                    Self.gemm(transB: false, m: tokens, n: hd, k: keys, a: scores, lda: keys,
                              b: cache.v(li, r, h), ldb: hd, c: att + r * tokens * d + h * hd, ldc: d)
                }
            }
            Self.linear(layer.out, att, mt, y)
            rmsNorm(y, mt, d, layer.postAttnLn, y)
            vDSP_vadd(x, 1, y, 1, x, 1, vDSP_Length(mt * d))
            // Feed-forward.
            rmsNorm(x, mt, d, layer.preFfLn, xn)
            Self.linear(layer.ff0, xn, mt, hid)
            Self.swish(hid, mt * c.hiddenDims, ws: ws)
            Self.linear(layer.ff1, hid, mt, y)
            rmsNorm(y, mt, d, layer.postFfLn, y)
            vDSP_vadd(x, 1, y, 1, x, 1, vDSP_Length(mt * d))
        }
        cache.nextIndex += tokens
        let last = ws.buf(.last, rows * d)
        for r in 0..<rows { (last + r * d).update(from: x + (r * tokens + tokens - 1) * d, count: d) }
        return UnsafePointer(last)
    }

    /// `RotaryPositionalEmbedding.forward` on one head vector, in place:
    /// `[a·cos − b·sin, b·cos + a·sin]` over its two halves.
    @inline(__always) static func rotary(_ x: UnsafeMutablePointer<Float>, _ half: Int,
                                         _ cos: UnsafePointer<Float>, _ sin: UnsafePointer<Float>) {
        for k in 0..<half {
            let a = x[k], b = x[half + k]
            x[k] = a * cos[k] - b * sin[k]
            x[half + k] = b * cos[k] + a * sin[k]
        }
    }

    /// `RMSNorm`: `x · rsqrt(mean(x²) + eps) · scale` per row of `width`.
    private func rmsNorm(_ x: UnsafePointer<Float>, _ m: Int, _ width: Int, _ w: UnsafePointer<Float>,
                         _ y: UnsafeMutablePointer<Float>) {
        let eps = Float(config.rmsEps)
        for i in 0..<m {
            var ss: Float = 0
            vDSP_svesq(x + i * width, 1, &ss, vDSP_Length(width))
            var inv = 1 / (ss / Float(width) + eps).squareRoot()
            vDSP_vsmul(x + i * width, 1, &inv, y + i * width, 1, vDSP_Length(width))
            vDSP_vmul(y + i * width, 1, w, 1, y + i * width, 1, vDSP_Length(width))
        }
    }

    /// `ResidualBlock.forward`: `output(swish(hidden(x))) + residual(x)`.
    private func residualBlock(_ b: ResidualBlock, _ x: UnsafePointer<Float>, _ m: Int,
                               _ y: UnsafeMutablePointer<Float>, ws: Workspace) {
        let hid = ws.buf(.resHidden, m * b.hidden.out)
        Self.linear(b.hidden, x, m, hid)
        Self.swish(hid, m * b.hidden.out, ws: ws)
        Self.linear(b.output, hid, m, y)
        let r = ws.buf(.resResidual, m * b.residual.out)
        Self.linear(b.residual, x, m, r)
        vDSP_vadd(y, 1, r, 1, y, 1, vDSP_Length(m * b.residual.out))
    }

    // MARK: - Kernels

    /// `nn.Linear`: `y[m, out] = x[m, in] · Wᵀ (+ b)`.
    static func linear(_ l: Linear, _ x: UnsafePointer<Float>, _ m: Int, _ y: UnsafeMutablePointer<Float>) {
        gemm(transB: true, m: m, n: l.out, k: l.inp, a: x, lda: l.inp, b: l.w, ldb: l.inp, c: y, ldc: l.out)
        if let b = l.b {
            for i in 0..<m { vDSP_vadd(y + i * l.out, 1, b, 1, y + i * l.out, 1, vDSP_Length(l.out)) }
        }
    }

    /// Row-major `C = A · op(B)` (Timestral's CBLAS call).
    static func gemm(transB: Bool, m: Int, n: Int, k: Int, a: UnsafePointer<Float>, lda: Int,
                     b: UnsafePointer<Float>, ldb: Int, c: UnsafeMutablePointer<Float>, ldc: Int) {
        TimestralNetwork.gemm(transB: transB, m: m, n: n, k: k, alpha: 1, a: a, lda: lda, b: b, ldb: ldb,
                              beta: 0, c: c, ldc: ldc)
    }

    /// In-place row softmax (every row keeps its own position: finite).
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

    /// In-place `x · sigmoid(x)` (nn.SiLU, the config's "swish").
    static func swish(_ x: UnsafeMutablePointer<Float>, _ n: Int, ws: Workspace) {
        let t = ws.buf(.act, n)
        TimestralNetwork.sigmoidInto(x, t, n)
        vDSP_vmul(x, 1, t, 1, x, 1, vDSP_Length(n))
    }

    /// `F.softplus` (beta 1, threshold 20), in float32.
    static func softplus(_ x: Float) -> Float { x > 20 ? x : Float(log1p(exp(Double(x)))) }

    // MARK: - Scratch buffers

    enum Slot: Int, CaseIterable {
        case x, xn, qkv, att, y, ffHidden, scores, cos, sin, act, tokIn, resHidden, resResidual,
             last, point, quant, cacheK, cacheV
    }

    /// `util.DecodeCache` for every layer: keys and values `[layer][row][head][slot][hd]`
    /// (head-major, so one head's keys are a contiguous matrix for the GEMM).
    final class KVCache {
        let k: UnsafeMutablePointer<Float>, v: UnsafeMutablePointer<Float>
        let rows: Int, heads: Int, size: Int, headDim: Int
        var nextIndex = 0
        init(ws: Workspace, layers: Int, rows: Int, heads: Int, size: Int, headDim: Int) {
            let n = layers * rows * heads * size * headDim
            k = ws.buf(.cacheK, n); v = ws.buf(.cacheV, n)
            self.rows = rows; self.heads = heads; self.size = size; self.headDim = headDim
        }
        @inline(__always) func k(_ l: Int, _ r: Int, _ h: Int) -> UnsafeMutablePointer<Float> {
            k + ((l * rows + r) * heads + h) * size * headDim
        }
        @inline(__always) func v(_ l: Int, _ r: Int, _ h: Int) -> UnsafeMutablePointer<Float> {
            v + ((l * rows + r) * heads + h) * size * headDim
        }
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

    /// Workspaces for concurrent callers: one per call in flight, a few kept.
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
