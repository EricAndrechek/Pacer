import Foundation

/// Chooses which full-day rollup buckets one live-rebuild pass rebuilds (#151).
///
/// The live pass rebuilds still-open buckets from their samples, which bounds
/// drift in the running totals the fast path keeps (see
/// `ScanCoordinator.rebuildLiveBuckets`). It used to rebuild every open bucket
/// together, every ten minutes. For a day-long bucket that means re-reading
/// every sample of the day, so the pass cost grew with the day's volume: 3.8 s
/// for eight busy project-days on a live store, holding the store the whole
/// time, and 2–2.6 s in the first hour after midnight, when yesterday's
/// buckets joined today's.
///
/// So each pass rebuilds at most `limit` of them:
/// - **A day that has closed goes first.** Its buckets are about to freeze,
///   and a rebuild after the close is the one that settles them. They stay
///   queued until each has been rebuilt once, however many passes that takes,
///   rather than only for the hour after midnight.
/// - **Then whichever was rebuilt longest ago**, never-rebuilt first, so every
///   open bucket comes round in turn.
///
/// Not per-bucket expiry on the fast path (the way `SessionRollupCache` bounds
/// sessions): that rebuilds a bucket only when a sample lands in it, and the
/// bucket that matters most, the one that just closed, gets no more samples.
///
/// Hour buckets are not planned: one hour of samples is cheap (tens of ms),
/// so the pass still rebuilds the current and previous hour whole.
///
/// State lives for the process. A relaunch starts with every open bucket
/// never-rebuilt, and forgets a closed day still queued; the first is harmless,
/// and the second is the same as Pacer not running at midnight, which the
/// timer never covered either.
struct LiveRebuildPlanner<Bucket: Hashable> {
    let limit: Int
    /// Orders buckets that tie, so a pass is deterministic.
    let order: @Sendable (Bucket) -> String

    private(set) var lastRebuilt: [Bucket: Date] = [:]
    private(set) var closing: Set<Bucket> = []

    init(limit: Int, order: @escaping @Sendable (Bucket) -> String) {
        self.limit = limit
        self.order = order
    }

    /// The buckets this pass rebuilds.
    ///
    /// - Parameters:
    ///   - open: today's buckets.
    ///   - justClosed: the buckets of a day that ended within the last hour
    ///     (empty the rest of the day).
    ///   - dayStart: the start of today. A closed bucket last rebuilt before it
    ///     has not been rebuilt since it closed.
    mutating func pick(open: Set<Bucket>, justClosed: Set<Bucket>,
                       now: Date, dayStart: Date) -> Set<Bucket> {
        for bucket in justClosed where (lastRebuilt[bucket] ?? .distantPast) < dayStart {
            closing.insert(bucket)
        }

        var picked = Array(closing.sorted { order($0) < order($1) }.prefix(limit))
        if picked.count < limit {
            let rest = open.subtracting(picked).sorted {
                let a = lastRebuilt[$0] ?? .distantPast, b = lastRebuilt[$1] ?? .distantPast
                return a != b ? a < b : order($0) < order($1)
            }
            picked += rest.prefix(limit - picked.count)
        }

        for bucket in picked {
            lastRebuilt[bucket] = now
            closing.remove(bucket)
        }
        // Remember only what can still be picked, or is needed to tell a
        // closed bucket already rebuilt from one that is not.
        lastRebuilt = lastRebuilt.filter {
            open.contains($0.key) || justClosed.contains($0.key) || closing.contains($0.key)
        }
        return Set(picked)
    }
}
