import Foundation

/// Decides when a rollup bucket is rebuilt from its samples rather than
/// trusted (#151).
///
/// The incremental fast path adds each new sample to its bucket's running
/// totals, and nothing re-checks the result. If tokens and cost ever fall out
/// of step (a cost priced before pricing loaded, an upgrade reaching one
/// rollup and not another), the bucket carries the error; once its hour or
/// day is over, it carries it for good. A from-scratch rebuild is the fix,
/// so this schedules one:
///
/// 1. **Once after the bucket closes**, first of all. That rebuild settles it
///    for good. Closes that happened while Pacer was not running are caught
///    up on the next launch (`ScanCoordinator` keeps the watermark).
/// 2. **Within `writeDelay` of a fast-path write.** A total can only drift
///    when something writes to it, so the buckets being written to are the
///    ones to check, and soon.
/// 3. **At least every `sweepAge`, written to or not**, as a backstop for
///    drift that does not come through the fast path. A bucket not checked
///    since launch is due `writeDelay` after launch, so drift from before a
///    relaunch is not left waiting a whole sweep.
///
/// At most `limit` a cycle, in that order, so a burst of due buckets is spread
/// over cycles instead of holding the store at once. The ten-minute pass this
/// replaced rebuilt every open bucket together, re-reading the whole day's
/// samples each time: 3.8 s for eight busy project-days on a live store.
///
/// State lives for the process, apart from the close watermark. A relaunch
/// forgets which buckets were written and not yet checked; the launch rule in
/// (3) covers them.
struct LiveBucketVerifier<Bucket: Hashable> {
    let limit: Int
    let writeDelay: TimeInterval
    let sweepAge: TimeInterval
    /// Orders buckets that tie, so a cycle is deterministic.
    let order: @Sendable (Bucket) -> String

    /// When each bucket was last rebuilt from its samples.
    private(set) var verifiedAt: [Bucket: Date] = [:]
    /// The first fast-path write since each bucket's last rebuild.
    private(set) var writtenAt: [Bucket: Date] = [:]
    /// Buckets whose hour or day has closed and not been rebuilt since.
    private(set) var closed: Set<Bucket> = []
    /// When this verifier first ran: the launch, for rule (3).
    private var startedAt: Date?

    init(limit: Int, writeDelay: TimeInterval, sweepAge: TimeInterval,
         order: @escaping @Sendable (Bucket) -> String) {
        self.limit = limit
        self.writeDelay = writeDelay
        self.sweepAge = sweepAge
        self.order = order
    }

    /// Record this cycle's writes.
    ///
    /// - Parameters:
    ///   - written: every bucket this cycle marked for recompute.
    ///   - rebuilt: those the recompute rebuilds from their samples anyway
    ///     (polluted): they count as checked, closed or not.
    mutating func note(written: Set<Bucket>, rebuilt: Set<Bucket>, now: Date) {
        if startedAt == nil { startedAt = now }
        for bucket in rebuilt { markVerified(bucket, at: now) }
        for bucket in written.subtracting(rebuilt) where writtenAt[bucket] == nil {
            writtenAt[bucket] = now
        }
    }

    mutating func enqueueClosed(_ buckets: Set<Bucket>) {
        closed.formUnion(buckets)
    }

    /// The buckets to rebuild this cycle.
    ///
    /// - Parameter open: the buckets still open, for the sweep; nil when the
    ///   caller did not read them this cycle, which skips the sweep.
    mutating func pick(open: Set<Bucket>?, now: Date) -> Set<Bucket> {
        if startedAt == nil { startedAt = now }
        var picked: [Bucket] = []
        func take(_ candidates: [Bucket]) {
            for bucket in candidates where picked.count < limit && !picked.contains(bucket) {
                picked.append(bucket)
            }
        }

        take(closed.sorted { order($0) < order($1) })
        take(writtenAt
            .filter { now.timeIntervalSince($0.value) >= writeDelay }
            .sorted { $0.value != $1.value ? $0.value < $1.value : order($0.key) < order($1.key) }
            .map(\.key))
        if let open {
            let launchDue = (startedAt ?? now).addingTimeInterval(writeDelay)
            func due(_ bucket: Bucket) -> Date {
                verifiedAt[bucket].map { $0.addingTimeInterval(sweepAge) } ?? launchDue
            }
            take(open.filter { due($0) <= now }
                .sorted { due($0) != due($1) ? due($0) < due($1) : order($0) < order($1) })
        }

        for bucket in picked { markVerified(bucket, at: now) }
        if let open {
            // Remember only what can still come due.
            verifiedAt = verifiedAt.filter {
                open.contains($0.key) || writtenAt[$0.key] != nil || closed.contains($0.key)
            }
        }
        return Set(picked)
    }

    private mutating func markVerified(_ bucket: Bucket, at now: Date) {
        verifiedAt[bucket] = now
        writtenAt[bucket] = nil
        closed.remove(bucket)
    }
}
