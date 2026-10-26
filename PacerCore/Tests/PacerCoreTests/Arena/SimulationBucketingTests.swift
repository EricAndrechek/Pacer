import Foundation
import Testing
@testable import PacerCore

/// In the app g2-08-fable-burst's turn log arrives as `ArenaSpendRow`s, one
/// per family per 5-minute bucket (the bucket's last `tEvent`, its summed
/// cost and turn count), not one row per turn as the arena had it. This
/// feeds the model the same synthetic activity both ways.
///
/// At a cut on a 5-minute epoch boundary (and live, where the current
/// bucket is built from the turns known now) every bucket before the cut is
/// complete, and what the model reads survives: everything built on
/// 5-minute epoch bins (the activity bins, both hazard tables and their
/// hour-of-day multipliers, the analogs, the active bins in a window), the
/// time of the last turn, the state now; only the length of a spell in
/// progress (counted in bins ending at now, not at the epoch) can come out
/// shorter, and the long-run rate move by an edge bin. (The live spend since
/// the last reading is the spend kit's: a bucket's spend counts at its last
/// turn, so it can move by up to one bucket's spend. Not checked here: the
/// synthetic readings land on the cut.)
///
/// At a cut inside a bucket, the bucket's row is not known yet (it is known
/// at its last turn), so up to 5 minutes of the latest activity is missing,
/// and the state now, the thing this model is built on, can flip from
/// active to idle. Backfill cuts should sit on 5-minute boundaries.
@Suite struct SimulationBucketingTests {
    struct Turn { let t: Millis; let family: String; let cost: Double }

    static func turns(days: Int, seed: UInt64, start: Millis) -> [Turn] {
        var rng = ArenaRNG(seed: seed)
        var out: [Turn] = []
        var t = start
        let end = start + Millis(days) * ArenaTime.day
        var active = false
        while t < end {
            let hour = Int(SimRandom.pmod(t - 4 * ArenaTime.hour, ArenaTime.day) / ArenaTime.hour)
            active = active ? rng.uniform() > 0.15 : rng.uniform() < (hour >= 9 && hour < 23 ? 0.08 : 0.01)
            if active {
                // A turn every 20 s to 3 min while a spell lasts.
                var s = t + Millis(rng.uniform() * 60_000)
                while s < t + 5 * ArenaTime.minute {
                    out.append(Turn(t: s, family: rng.uniform() < 0.3 ? "opus" : "fable", cost: SimRandom.exponential(0.2, rng: &rng)))
                    s += 20_000 + Millis(rng.uniform() * 160_000)
                }
            }
            t += 5 * ArenaTime.minute
        }
        return out
    }

    /// The app's form: one row per family per epoch 5-minute bucket.
    static func bucketed(_ turns: [Turn]) -> [ArenaSpendRow] {
        var by: [String: (t: Millis, cost: Double, n: Int)] = [:]
        for x in turns {
            let k = "\(x.family)|\(x.t / (5 * ArenaTime.minute))"
            let o = by[k] ?? (0, 0, 0)
            by[k] = (max(o.t, x.t), o.cost + x.cost, o.n + 1)
        }
        return by.map { k, v in
            ArenaSpendRow(tEvent: v.t, tKnown: v.t, family: String(k.split(separator: "|")[0]), costUSD: v.cost, turns: v.n)
        }
    }

    @Test func whatTheModelReadsSurvivesTheBuckets() throws {
        let (base, end) = SyntheticHistory.make(days: 30, seed: 11)
        let acct = SyntheticHistory.account
        let raw = Self.turns(days: 30, seed: 12, start: end - 30 * ArenaTime.day)
        let rawRows = raw.map { ArenaSpendRow(tEvent: $0.t, tKnown: $0.t, family: $0.family, costUSD: $0.cost) }
        func store(_ rows: [ArenaSpendRow]) -> ArenaHistoryStore {
            ArenaHistoryStore(meters: base.meters, spend: [acct: rows], tzOffsetMin: base.tzOffsetMin)
        }
        let a = store(rawRows), b = store(Self.bucketed(raw))
        var cuts = 0, ageShorter = 0, lrMoved = 0
        var unaligned = 0, stateFlipped = 0
        let bucket = 5 * ArenaTime.minute
        var t = end - 6 * ArenaTime.day
        while t < end {
            defer { t += 97 * ArenaTime.minute }
            for now in [t - SimRandom.pmod(t, bucket), t - SimRandom.pmod(t, bucket) + 150_000] {
                let aligned = SimRandom.pmod(now, bucket) == 0
                let ha = ArenaHistory(store: a, now: now, accounts: [acct]), hb = ArenaHistory(store: b, now: now, accounts: [acct])
                guard let tr = ArenaRunner.targetRequest(history: ha, meter: ArenaMeterID(account: acct, windowKind: "five_hour"))
                else { continue }
                let ma = SimParity.instance(G208FableBurst.name, { G208FableBurst(context: $0) }, history: ha)
                let mb = SimParity.instance(G208FableBurst.name, { G208FableBurst(context: $0) }, history: hb)
                try ma.fit(ha); try mb.fit(hb)
                let req = ArenaRequest(now: now, accounts: [acct], targets: [tr])
                _ = try ma.forecast(req); _ = try mb.forecast(req)
                let da = ma.lastDiag, db = mb.lastDiag
                if !aligned {
                    unaligned += 1
                    if da["act"] != db["act"] { stateFlipped += 1 }
                    continue
                }
                cuts += 1
                let za = try ma.hazards(acct, now: now), zb = try mb.hazards(acct, now: now)
                #expect(za.hOn == zb.hOn && za.hOff == zb.hOff && za.hodOn == zb.hodOn && za.hodOff == zb.hodOff)
                #expect(za.bins?.active == zb.bins?.active && za.bins?.origin == zb.bins?.origin)
                #expect(try ma.activity(acct).te.last == mb.activity(acct).te.last, "the last turn's time")
                #expect(da["act"] == db["act"] && da["n_rec"] == db["n_rec"] && da["proxy"] == db["proxy"])
                #expect(db["age"]! <= da["age"]!, "a spell in progress can only look shorter")
                if db["age"]! < da["age"]! { ageShorter += 1 }
                if abs(da["lr"]! - db["lr"]!) > 1e-9 { lrMoved += 1 }
            }
        }
        print("bucketing: \(cuts) aligned cuts: spell age shorter at \(ageShorter), long-run rate moved at \(lrMoved); "
              + "\(unaligned) cuts mid-bucket: active/idle flipped at \(stateFlipped)")
        #expect(cuts >= 10)
    }
}
