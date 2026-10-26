import Foundation

// The table of cuts, built once per history store instead of once per cut.
//
// The arena rebuilds the analog table at every call: every complete past
// cycle as known at `now`, cut every few minutes. In the app the model runs
// at every cut of every completed cycle over up to 120 days, plus its
// calibration layer's backtests, so rebuilding is most of its cost. A past
// cycle's cuts depend only on that cycle's readings (and the store's time
// zone, step and resolution), so this index cuts every cycle of the whole
// store once and, at `now`, selects the cycles `KitSpend.pastCycles` would
// return then.
//
// Why the selection is exactly the per-cut table. `past_cycles` at `now`
// groups the active readings known at `now` by reset, splitting where
// consecutive resets differ by half a window or more, and keeps the groups
// whose (median) reset has passed. The index groups every reading the same
// way. Taking readings away only widens gaps, so a group of the whole store
// whose members are all known at `now` is a group at `now` too, with the
// same members, median and cuts. A group none of whose members is known at
// `now` is invisible then. What the index cannot reproduce is a group only
// partly known at `now` that already has a passed reset among its members (a
// reading that became known after its own cycle ended): its group at `now`
// may differ. `select` then returns nil and the model builds that cut's
// table the arena's way. In the app a row is known when it is written
// (`tKnown == tEvent`), so that never happens; in the arena's replay it can.
// `AnalogTableTests` checks the two against each other cut by cut.

extension Analog {
    struct CycleIndex: Sendable {
        struct Cycle: Sendable {
            /// The truncated median of the members' resets (`past_cycles`).
            let reset: Millis
            /// The earliest member's reset.
            let minReset: Millis
            /// When the first and the last member became known.
            let minKnown: Millis
            let maxKnown: Millis
            /// The cycle's cuts, nil when it is not usable.
            let cuts: CycleCuts?
        }

        /// Every cycle of one meter in the store, oldest first.
        let cycles: [Cycle]

        /// Built from the readings of the whole store (every row from the
        /// history's start, whenever it became known), grouped exactly as
        /// `KitSpend.pastCycles` groups the rows known at one `now`.
        init(store: ArenaHistoryStore, account: String, kind: String, cap: String?, start: Millis?,
             tz: Millis, step: Millis, M: Int) {
            let all = ArenaHistory(store: store, now: .max, accounts: [account], start: start)
            let rows = all.readings(account: account, windowKind: kind, scopeModel: cap)
            // `_readings` then the active filter, in the store's (tEvent, util) order.
            var t = [Millis](), p = [Double](), reset = [Millis](), known = [Millis]()
            for r in rows {
                guard let u = r.utilPct, r.active, let rs = r.resetsAt else { continue }
                t.append(r.tEvent); p.append(u); reset.append(rs); known.append(r.tKnown)
            }
            guard !t.isEmpty else { cycles = []; return }
            let dur = KitSpend.windowMs(kind)
            let half = Double(dur) / 2
            let lags = meterLags(kind)
            let o = reset.indices.sorted { reset[$0] != reset[$1] ? reset[$0] < reset[$1] : $0 < $1 }
            var groups: [[Int]] = [[o[0]]]
            for j in 1..<o.count {
                if Double(reset[o[j]] - reset[o[j - 1]]) >= half { groups.append([o[j]]) }
                else { groups[groups.count - 1].append(o[j]) }
            }
            var out: [(Int, Cycle)] = []
            for (gi, g) in groups.enumerated() {
                let res = KitSpend.truncatedMedian(g.map { reset[$0] })
                let byT = g.indices.sorted { t[g[$0]] != t[g[$1]] ? t[g[$0]] < t[g[$1]] : $0 < $1 }.map { g[$0] }
                let cuts = Analog.cycleCuts(account: account, reset: res, start: res - dur, t: byT.map { t[$0] },
                                            util: byT.map { p[$0] }, tz: tz, step: step, M: M, lags: lags)
                out.append((gi, Cycle(reset: res, minReset: g.map { reset[$0] }.min()!,
                                      minKnown: g.map { known[$0] }.min()!, maxKnown: g.map { known[$0] }.max()!,
                                      cuts: cuts)))
            }
            // `past_cycles` sorts by reset, stably.
            cycles = out.sorted { $0.1.reset != $1.1.reset ? $0.1.reset < $1.1.reset : $0.0 < $1.0 }.map(\.1)
        }

        /// The usable cycles among the latest `maxCycles` that
        /// `KitSpend.pastCycles` returns at `now`, or nil when a cycle is
        /// only partly known then (see the file's header).
        func select(now: Millis, maxCycles: Int) -> [CycleCuts]? {
            var eligible: [Int] = []
            for (i, c) in cycles.enumerated() {
                if c.minReset <= now && c.minKnown <= now && now < c.maxKnown { return nil }
                if c.maxKnown <= now && c.reset <= now { eligible.append(i) }
            }
            return eligible.suffix(maxCycles).compactMap { cycles[$0].cuts }
        }
    }

    /// A memo that lives as long as a history store, for what is built once
    /// per store (the cycle index). The contract's memo lives on one history
    /// cut (`ArenaHistory.memo`); nothing in it outlives the cut. Entries
    /// hold their store weakly, are dropped once it is gone, and at most
    /// four are kept. If `ArenaHistoryStore` gains a memo of its own, this
    /// goes.
    enum StoreMemo {
        private final class Entry: @unchecked Sendable {
            weak var store: ArenaHistoryStore?
            let memo = ArenaMemo()
            init(_ store: ArenaHistoryStore) { self.store = store }
        }

        private final class Entries: @unchecked Sendable {
            let lock = NSLock()
            var list: [Entry] = []
        }

        private static let entries = Entries()
        static let capacity = 4

        static func memo(for store: ArenaHistoryStore) -> ArenaMemo {
            let e = entries
            e.lock.lock(); defer { e.lock.unlock() }
            e.list.removeAll { $0.store == nil }
            if let hit = e.list.first(where: { $0.store === store }) { return hit.memo }
            let entry = Entry(store)
            e.list.append(entry)
            if e.list.count > capacity { e.list.removeFirst(e.list.count - capacity) }
            return entry.memo
        }
    }
}
