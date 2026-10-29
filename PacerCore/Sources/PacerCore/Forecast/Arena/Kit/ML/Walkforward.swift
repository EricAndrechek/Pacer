import Foundation

// `research/arena/kit/ml/walkforward.py`, in Swift: past cutoffs inside a
// history, each described as it was known then and labelled only with what
// was already known at `now`.
//
// A row is (meter, cutoff `t`): the features at `t` (`FeatureBuilder.row`,
// as of `t`) and, for each lead fraction `f` of the time then left to the
// cycle's reset `R`, the meter's rise from `t` to `t + f (R − t)`. A label is
// used only when it was known at `now` (the meter as a step function of its
// readings, counted only once a reading at or after that time is known; at
// the reset only once the cycle has reset by `now − 10 min`); otherwise it is
// NaN and the row trains the leads that have one. Cutoffs sit on a fixed UTC
// lattice, so which exist depends on the lattice and on what was known at
// each, never on later rows; when there are more than `max_rows`, a per-row
// draw (BLAKE2b of the row's account and time, as in the Python) keeps recent
// rows twice as likely as the oldest.

public enum KitMLWalkforward {
    public typealias M = KitMLData
    public static let leads: [Double] = [0.03, 0.08, 0.15, 0.25, 0.4, 0.6, 0.8, 1.0]
    public static func step(_ kind: String) -> Millis { kind == "five_hour" ? 30 * M.minMs : 3 * M.hourMs }
    public static func maxDays(_ kind: String) -> Millis { kind == "five_hour" ? 45 : 150 }
    public static let minLead: Millis = 10 * M.minMs
    public static let resetMargin: Millis = 10 * M.minMs
    public static func windowHalf(_ kind: String) -> Millis { kind == "five_hour" ? 150 * M.minMs : 84 * M.hourMs }

    public struct TrainSet: Sendable {
        /// `[n][featureNames.count]`.
        public var X: [[Double]]
        /// `[n][leads.count]` rise in points; NaN = not known at now.
        public var Y: [[Double]]
        public var tau: [[Double]]
        public var t: [Millis]
        public var reset: [Millis]
        public var account: [String]
        public var leads: [Double]
        public var now: Millis
        /// `[n][leads.count][leadNames.count]`.
        public var leadX: [[[Double]]]
        /// Rows of one meter cycle share an id (folds must not split one).
        public var cycle: [Int]

        public var count: Int { t.count }

        /// `stacked`: (X, y, row) over every (row, lead) with a known label,
        /// the row's features followed by the lead's; X row-major.
        public func stacked() -> (x: [Double], y: [Double], row: [Int], width: Int) {
            let width = KitMLFeatures.featureNames.count + KitMLFeatures.leadNames.count
            var x: [Double] = [], y: [Double] = [], r: [Int] = []
            for i in 0..<count {
                for j in leads.indices where Y[i][j].isFinite {
                    x.append(contentsOf: X[i]); x.append(contentsOf: leadX[i][j])
                    y.append(Y[i][j]); r.append(i)
                }
            }
            return (x, y, r, width)
        }
    }

    /// `lattice`: every `step` on the UTC grid in [lo, hi].
    public static func lattice(_ lo: Millis, _ hi: Millis, _ step: Millis) -> [Millis] {
        let first = lo + M.floorMod(-lo, step)
        guard first <= hi else { return [] }
        return Array(stride(from: first, through: hi, by: Int64.Stride(step)))
    }

    /// `_keep`: a deterministic per-row draw in [0, 1), the first 8 bytes of
    /// BLAKE2b-64 of "salt|account|t", big-endian, over 2^64.
    public static func keep(_ account: String, _ t: Millis, salt: String) -> Double {
        let d = Blake2b.hash(Array("\(salt)|\(account)|\(t)".utf8), outLength: 8)
        var v: UInt64 = 0
        for b in d { v = v << 8 | UInt64(b) }
        return Double(v) / 18_446_744_073_709_551_616.0
    }

    /// `label_row`: (rise at each lead, label time) for a cutoff at t in the
    /// cycle resetting at `reset`, from readings known at `now` only.
    public static func labelRow(_ s: M.MeterSeries, _ t: Millis, _ reset: Millis, used: Double, now: Millis,
                                leads: [Double] = leads) -> (y: [Double], tau: [Double]) {
        let idx = s.cycleReadings(reset, asof: now, upto: reset)
        let tau = leads.map { Double(t) + $0 * Double(reset - t) }
        var y = [Double](repeating: .nan, count: leads.count)
        guard let lastI = idx.last else { return (y, tau) }
        let te = idx.map { s.te[$0] }, ut = idx.map { s.util[$0] }
        let start = reset - s.duration
        let lastTe = s.te[lastI]
        for (j, f) in leads.enumerated() {
            let tj = tau[j]
            if tj > Double(now) { continue }
            if f >= 1.0 {
                if reset <= now - resetMargin { y[j] = KitMLFeatures.pmax(ut[ut.count - 1] - used, 0.0) }
            } else if Double(lastTe) >= tj {
                y[j] = KitMLFeatures.pmax(M.stepValue(te, ut, tj, start: start) - used, 0.0)
            }
        }
        return (y, tau)
    }

    /// `build_trainset`: every lattice cutoff in [max(start, now − max_days),
    /// now − 10 min] where a cycle of this kind (and cap) was active as known
    /// then, on every account in the data, subsampled to `maxRows`.
    public static func buildTrainset(_ data: M.AsOfData, _ builder: KitMLFeatures.FeatureBuilder, kind: String,
                                     cap: String?, now: Millis, start: Millis? = nil, step stepIn: Millis? = nil,
                                     maxDays maxDaysIn: Millis? = nil, maxRows: Int = 4000, leads: [Double] = leads,
                                     salt: String = "wf", checkCancelled: () throws -> Void = {}) throws -> TrainSet {
        let stp = stepIn ?? step(kind)
        let days = maxDaysIn ?? maxDays(kind)
        var lo = now - days * M.dayMs
        if let start { lo = max(lo, start) }
        let times = lattice(lo, now - minLead, stp)
        var cand: [(M.MeterSeries, Millis, Millis)] = []
        for s in data.seriesOf(kind, cap) where s.count > 0 {
            for t in times {
                guard let c = s.cycleAt(t), c.resetAt - t >= minLead else { continue }
                cand.append((s, t, c.resetAt))
            }
        }
        if cand.count > maxRows {
            // Recent rows twice as likely as the oldest: priority = draw / weight.
            let span = Double(max(now - lo, 1))
            let pri = cand.map { keep($0.0.account, $0.1, salt: salt) / (0.5 + 0.5 * Double($0.1 - lo) / span) }
            let order = pri.indices.sorted { (pri[$0], $0) < (pri[$1], $1) }
            cand = order.prefix(maxRows).sorted().map { cand[$0] }
        }
        var ts = TrainSet(X: [], Y: [], tau: [], t: [], reset: [], account: [], leads: leads, now: now, leadX: [], cycle: [])
        for (n, (s, t, r)) in cand.enumerated() {
            if n % 64 == 0 { try checkCancelled() }
            guard let st = s.stateAt(t, reset: r), let row = builder.row(s, t, reset: r, st: st) else { continue }
            let (y, tau) = labelRow(s, t, r, used: st.used, now: now, leads: leads)
            if !y.contains(where: { $0.isFinite }) { continue }
            ts.X.append(row); ts.Y.append(y); ts.tau.append(tau); ts.t.append(t); ts.reset.append(r)
            ts.account.append(s.account)
            ts.leadX.append(builder.leadRows(row, s, t, reset: r, fracs: leads))
        }
        ts.cycle = cycleIds(ts.account, ts.reset, half: windowHalf(kind))
        return ts
    }

    /// `cycle_ids`: one id per (account, cycle) by the half-window rule.
    public static func cycleIds(_ accounts: [String], _ resets: [Millis], half: Millis) -> [Int] {
        var out = [Int](repeating: 0, count: resets.count)
        var next = 0
        for a in Set(accounts).sorted() {
            let idx = accounts.indices.filter { accounts[$0] == a }
            let o = idx.sorted { (resets[$0], $0) < (resets[$1], $1) }
            var anchor: Millis?
            for i in o {
                if anchor == nil || resets[i] - anchor! >= half { anchor = resets[i]; next += 1 }
                out[i] = next - 1
            }
        }
        return out
    }
}

/// BLAKE2b (RFC 7693), unkeyed, for `KitMLWalkforward.keep` (Python's
/// `hashlib.blake2b(..., digest_size=8)`): CryptoKit has no BLAKE2.
enum Blake2b {
    static let iv: [UInt64] = [
        0x6a09_e667_f3bc_c908, 0xbb67_ae85_84ca_a73b, 0x3c6e_f372_fe94_f82b, 0xa54f_f53a_5f1d_36f1,
        0x510e_527f_ade6_82d1, 0x9b05_688c_2b3e_6c1f, 0x1f83_d9ab_fb41_bd6b, 0x5be0_cd19_137e_2179,
    ]
    static let sigma: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
    ]

    static func hash(_ input: [UInt8], outLength: Int) -> [UInt8] {
        var h = iv
        h[0] ^= 0x0101_0000 ^ UInt64(outLength)
        var t: UInt64 = 0
        var blocks = max(1, (input.count + 127) / 128)
        if input.isEmpty { blocks = 1 }
        for b in 0..<blocks {
            var block = [UInt8](repeating: 0, count: 128)
            let lo = b * 128, hi = min(lo + 128, input.count)
            if lo < hi { block.replaceSubrange(0..<(hi - lo), with: input[lo..<hi]) }
            t += UInt64(hi - lo)
            compress(&h, block, t: t, last: b == blocks - 1)
        }
        var out: [UInt8] = []
        for w in h { for k in 0..<8 { out.append(UInt8(truncatingIfNeeded: w >> (8 * UInt64(k)))) } }
        return Array(out.prefix(outLength))
    }

    static func compress(_ h: inout [UInt64], _ block: [UInt8], t: UInt64, last: Bool) {
        var m = [UInt64](repeating: 0, count: 16)
        for i in 0..<16 {
            var w: UInt64 = 0
            for k in 0..<8 { w |= UInt64(block[i * 8 + k]) << (8 * UInt64(k)) }
            m[i] = w
        }
        var v = h + iv
        v[12] ^= t
        if last { v[14] = ~v[14] }
        @inline(__always) func rotr(_ x: UInt64, _ n: UInt64) -> UInt64 { (x >> n) | (x << (64 - n)) }
        func g(_ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt64, _ y: UInt64) {
            v[a] = v[a] &+ v[b] &+ x; v[d] = rotr(v[d] ^ v[a], 32)
            v[c] = v[c] &+ v[d]; v[b] = rotr(v[b] ^ v[c], 24)
            v[a] = v[a] &+ v[b] &+ y; v[d] = rotr(v[d] ^ v[a], 16)
            v[c] = v[c] &+ v[d]; v[b] = rotr(v[b] ^ v[c], 63)
        }
        for r in 0..<12 {
            let s = sigma[r % 10]
            g(0, 4, 8, 12, m[s[0]], m[s[1]]); g(1, 5, 9, 13, m[s[2]], m[s[3]])
            g(2, 6, 10, 14, m[s[4]], m[s[5]]); g(3, 7, 11, 15, m[s[6]], m[s[7]])
            g(0, 5, 10, 15, m[s[8]], m[s[9]]); g(1, 6, 11, 12, m[s[10]], m[s[11]])
            g(2, 7, 8, 13, m[s[12]], m[s[13]]); g(3, 4, 9, 14, m[s[14]], m[s[15]])
        }
        for i in 0..<8 { h[i] ^= v[i] ^ v[i + 8] }
    }
}
