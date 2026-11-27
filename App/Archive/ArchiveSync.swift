import Foundation
import SwiftData
import PacerCore

/// Keeps the raw archive current as the scan writes new turns.
///
/// Pull, not push: after a cycle reports new samples, this asks the store for
/// turns newer than the archive's own watermark and appends those. Nothing in
/// PacerCore has to know the archive exists, and a cycle that fails to archive
/// — a crash, a locked file, a bad write — is simply caught by the next one,
/// because the watermark is derived from what's actually in the archive rather
/// than from what we believe we sent.
///
/// The archive is additive and nothing user-visible reads it, so every failure
/// here is logged and swallowed. The alternative — letting an archive problem
/// break the scan — would trade a feature nobody depends on yet for the one
/// they do.
///
/// DuckDB takes an exclusive per-process file lock and its connection is a C
/// handle, so this owns the only one and lives entirely on `ScanActor`.
@ScanActor
final class ArchiveSync {

    private let container: ModelContainer
    private let archiveURL: URL
    /// Opened lazily and held: opening per cycle would pay the file lock and
    /// catalog load every few seconds.
    private var archive: RawArchive?
    /// Newest turn known to be archived. Seeded from the archive itself on
    /// first use, then advanced locally.
    private var watermark: Date?
    /// Once true, stop trying. A persistently broken archive should cost one
    /// log line, not one per cycle forever.
    private var disabled = false
    private var appendedTotal = 0
    private var nextLogAt = 1
    private var lastReconcileAt: Date?
    private var lastVerifyAt: Date?
    /// Set when the hourly check finds a divergence: the next reconcile pass
    /// drops its window and walks everything. Bounded because it only happens
    /// when something is provably wrong, and it makes convergence independent
    /// of whether the window happened to be wide enough.
    private var needsFullReconcile = false
    /// Set when reconciliation re-appended a turn the store has rewritten,
    /// so the archive briefly holds both copies and must collapse to the
    /// store's.
    private var pendingCollapse = false

    /// What one reconcile pass found, by `ArchivedTurn.Verdict`. Counts only.
    struct ReconcileCounts: Equatable {
        /// In the store, not archived at all.
        var missing = 0
        var upgraded = 0
        var patched = 0
        /// Turns, not rows: archived with more output than any store row.
        var ahead = 0
        /// Later store rows of a turn already compared (store duplicates).
        var superseded = 0
        var reappended: Int { upgraded + patched }
    }
    /// The last pass's counts, for the archive tests compiled beside this file.
    private(set) var lastReconcile: ReconcileCounts?

    /// How often the trailing window is reconciled rather than trusted.
    private static let reconcileInterval: TimeInterval = 30 * 60
    /// How often the archive is compared against the store. Hourly: often
    /// enough that a divergence is caught the same day, rare enough that six
    /// aggregate scans of each side cost nothing.
    private static let verifyInterval: TimeInterval = 60 * 60
    /// How far back reconciliation looks. Replay reach-back was measured on a
    /// real corpus at p99 6.07 days and max 7.15; 30 days is ~4x the observed
    /// worst case, and `--resume` can always target something older, which is
    /// what `make verify-data` is for.
    private static let reconcileWindow: TimeInterval = 30 * 86_400

    init(container: ModelContainer, archiveURL: URL) {
        self.container = container
        self.archiveURL = archiveURL
    }

    /// Append anything the store has that the archive doesn't.
    func syncNewTurns() {
        guard !disabled else { return }
        do {
            let archive = try openIfNeeded()
            if watermark == nil { watermark = try archive.watermark() }

            let context = ModelContext(container)
            var descriptor = FetchDescriptor<TokenSample>()
            if let watermark {
                descriptor.predicate = #Predicate<TokenSample> { $0.sampledAt > watermark }
            }
            var rows: [ArchiveRow] = []
            var newest = watermark
            // Paged, not `enumerate`d: that held every row it visited (3.3 GB
            // for a whole 746k-row table, #337), and the reconcile below walks
            // thirty days of turns every half hour.
            try ModelWalk.forEach(descriptor, orderedBy: \.sampledAt, in: container) { sample in
                if newest == nil || sample.sampledAt > newest! { newest = sample.sampledAt }
                rows.append(row(from: sample))
            }
            // Out-of-order arrivals are the hole in a forward-only watermark:
            // a resumed session backfills turns whose `sampledAt` predates the
            // newest thing already archived, and `> watermark` skips them
            // FOREVER. Measured on the real store as 32 turns missing out of
            // 191,421 — found by `make verify-data`, not by anything here.
            //
            // So the fast path stays forward-only, and a trailing window is
            // reconciled on a throttle: ask the archive which dedup keys it
            // already holds for that window and append the store rows it
            // doesn't. Bounded work, and self-correcting.
            //
            // The reconcile appends what it finds itself, in batches.
            let reconciled = try reconcileIfDue(
                archive: archive,
                // Already staged by the forward path above and NOT yet in the
                // archive, so reconciliation would otherwise "rescue" them a
                // second time. An append-only table can't take that back —
                // caught only because the check counted one row too many.
                pending: Set(rows.compactMap(\.dedupKey)))

            if !rows.isEmpty { try archive.append(rows) }
            if pendingCollapse {
                pendingCollapse = false
                if let removed = try? archive.collapseDuplicates(), removed > 0 {
                    Log.write("ArchiveSync", "collapsed \(removed) superseded copy/copies")
                    TelemetryCounters.add("data.archive_superseded_collapsed", Int(removed))
                }
            }
            // Advanced only after the append succeeded, so a failed write is
            // retried rather than skipped.
            if !rows.isEmpty { watermark = newest }
            appendedTotal += rows.count + reconciled
            // Logged sparsely — every cycle would be noise, but silence made
            // it impossible to tell "working" from "never ran".
            if rows.count + reconciled > 0, appendedTotal >= nextLogAt {
                Log.write("ArchiveSync", "archived \(appendedTotal) turn(s) this session")
                nextLogAt = appendedTotal + 500
            }

            // Verify from inside the app, because from outside it can't be:
            // DuckDB's exclusive lock means `make verify-data` can only check
            // the archive with Pacer closed, which in practice means almost
            // never. A second copy that is never compared is just a second
            // chance to be wrong — and this archive had already lost 32 turns
            // before anything compared them.
            try verifyIfDue(archive: archive, context: context)
        } catch {
            Log.write("ArchiveSync", "disabled after error: \(error)")
            disabled = true
            archive = nil
        }
    }

    /// Store turns inside the trailing window that the archive doesn't have,
    /// or holds otherwise than the store now does, appended again.
    ///
    /// Keyed on `dedupKey` because that's the identity the rest of the app
    /// already agrees on. Turns without one (no message id and no request id)
    /// can't be matched and are left to the forward path — they're rare, and
    /// guessing at identity here would risk archiving the same turn twice,
    /// which an append-only table can't take back.
    ///
    /// Returns how many rows it appended.
    private func reconcileIfDue(archive: RawArchive, pending: Set<String>) throws -> Int {
        let now = Date()
        if let last = lastReconcileAt,
           now.timeIntervalSince(last) < Self.reconcileInterval { return 0 }
        lastReconcileAt = now

        let full = needsFullReconcile
        needsFullReconcile = false
        let appended = try reconcile(
            archive: archive, since: full ? nil : now.addingTimeInterval(-Self.reconcileWindow),
            pending: pending)
        return appended
    }

    /// Rows re-appended or rescued are staged and appended this many at a
    /// time, as `ArchiveBackfill` does. The first pass after an upgrade can
    /// find hundreds of thousands of turns rewritten since they were
    /// archived; holding them all for one append is a row value each, where
    /// the walk itself holds one page. Batched rather than capped per pass:
    /// the walk dominates a pass (69-323 s for a full one on a real 1.2M-row
    /// copy) and costs the same whatever it finds, so a cap would repeat it
    /// once per cap, 30 minutes apart. The collapse still runs once, after
    /// the pass: 500k superseded copies took 2.9 s with this archive's
    /// settings (one thread, 256 MB; measured with the DuckDB CLI).
    static let appendBatchRows = 5_000

    private func reconcile(archive: RawArchive, since: Date?,
                           pending: Set<String>) throws -> Int {
        let full = since == nil
        // Values, not just presence. A streamed message is archived PARTIAL
        // and then upgraded in place in the store when its finished copy
        // arrives; the archive can't see that mutation, so a key can be
        // present and still be wrong.
        //
        // Six days of soak measured this precisely: 466 turns where the
        // archive held less output than the store, ZERO where it held more,
        // 2,351,397 output tokens missing. Presence-only reconciliation
        // called every one of them fine.
        //
        // And every value, not just output (#433). Since 0.8.0 a full
        // re-read also rewrites a stored row at EQUAL output when it brings
        // pricing detail the row predates (fast mode, `inference_geo`, a
        // response split into several calls): input and cache change. An
        // output-only comparison never saw that, so one Mac's hourly check
        // failed on input or cache from 0.8.2 on, and the full reconcile each
        // failure triggers never converged.
        //
        // `var`: the walk marks each turn it visits, in place.
        var archived = try archive.reconcileView(since: since)

        let descriptor = FetchDescriptor<TokenSample>(
            predicate: since.map { cutoff in
                #Predicate<TokenSample> { $0.sampledAt >= cutoff }
            })
        var counts = ReconcileCounts()
        var batch: [ArchiveRow] = []
        var appended = 0
        func stage(_ sample: TokenSample) throws {
            batch.append(row(from: sample))
            guard batch.count >= Self.appendBatchRows else { return }
            try archive.append(batch)
            appended += batch.count
            batch.removeAll(keepingCapacity: true)
        }
        // Thirty days is ~370k turns on a heavy store, fifteen pages: each
        // seeks the `sampledAt` index to where the last ended (#394).
        try ModelWalk.forEach(descriptor, orderedBy: \.sampledAt, in: container) { sample in
            guard let key = sample.dedupKey, !pending.contains(key) else { return }
            guard let index = archived.index(forKey: key) else {
                try stage(sample)   // never archived
                counts.missing += 1
                return
            }
            // Hashed only at equal output, which is almost every row: the
            // store side is plain field reads off the row the walk already
            // holds. `turn` is a copy for the hash, so the mark below writes
            // the map in place without overlapping it.
            let turn = archived.values[index]
            let verdict = archived.values[index].visit(storeOutput: sample.outputTokens) {
                turn.storeFingerprint(
                    input: sample.inputTokens, cacheRead: sample.cacheReadTokens,
                    cc5m: sample.cacheCreation5mTokens, cc1h: sample.cacheCreation1hTokens,
                    sourceCostUSD: sample.sourceCostUSD, sampledAt: sample.sampledAt,
                    speed: sample.speed, inferenceGeo: sample.inferenceGeo)
            }
            switch verdict {
            case .same:
                break
            // Archived, but not as the store now holds it: captured
            // mid-stream (`upgraded`), or rewritten since at equal output
            // (`patched`). Re-append the store's copy; the duplicate collapse
            // below keeps it. For a streamed message that is the fuller copy,
            // the rule `ParsedUsageEntry.supersedes` applies on the live
            // path; at equal output it is the later append
            // (`RawArchive.collapseOrder`).
            case .upgraded:
                try stage(sample)
                counts.upgraded += 1
            case .patched:
                try stage(sample)
                counts.patched += 1
            case .superseded:
                counts.superseded += 1
            case .ahead:
                break   // counted per turn below
            }
        }
        if !batch.isEmpty {
            try archive.append(batch)
            appended += batch.count
        }
        counts.ahead = archived.values.reduce(0) { $0 + ($1.isAhead ? 1 : 0) }
        if appended > 0 || counts.ahead > 0 || counts.superseded > 0 {
            Log.write("ArchiveSync",
                      "reconcile\(full ? " (full)" : ""): \(counts.missing) skipped, "
                      + "\(counts.upgraded) upgraded, \(counts.patched) patched since archiving"
                      + (counts.ahead > 0 ? ", \(counts.ahead) archived with more output than the store" : "")
                      + (counts.superseded > 0 ? ", \(counts.superseded) store duplicate(s) not compared" : ""))
        }
        lastReconcile = counts
        pendingCollapse = counts.reappended > 0
        return appended
    }

    /// Compare the archive against the store over a settled window and record
    /// the verdict where `make verify-data` can read it without the lock.
    ///
    /// The window is whole days ending before today, because the guarantee is
    /// eventual, not instantaneous — comparing right up to the newest turn
    /// reports ordinary sync lag as corruption, which is the false alarm that
    /// made the first version of this check useless.
    private func verifyIfDue(archive: RawArchive, context: ModelContext) throws {
        let now = Date()
        if let last = lastVerifyAt, now.timeIntervalSince(last) < Self.verifyInterval { return }
        lastVerifyAt = now

        // Whole days only, ending before today. Two reasons: today is still
        // being written on both sides, and comparing at a day boundary lets
        // the store side be answered from `DailyAggregate` — ~200 rows — where
        // summing the samples themselves means materializing all 190k, which
        // measured ~10.9 s. An integrity check that costs ten seconds an hour
        // on the scan actor is a regression, not a safeguard.
        //
        // Chaining through the rollup is sound because `make verify-data`
        // already proves hourly == samples; this adds archive == hourly.
        let today = TokenSample.formatDate(now)
        let archived = try archive.totals(beforeDate: today)

        // Hourly rather than daily purely because it carries `sampleCount`,
        // so the row count is checked too and not just the token sums. ~1,500
        // rows against ~190,000.
        var stored = RawArchive.Totals()
        let days = try context.fetch(FetchDescriptor<HourlyAggregate>(
            predicate: #Predicate<HourlyAggregate> { $0.date < today }))
        for day in days {
            stored.rows += Int64(day.sampleCount)
            stored.input += day.inputTokens
            stored.output += day.outputTokens
            stored.cacheRead += day.cacheReadTokens
            stored.cc5m += day.cacheCreation5mTokens
            stored.cc1h += day.cacheCreation1hTokens
        }

        // Carry counters forward rather than just the latest verdict. One
        // overwritten row answers "is it OK right now", which is the wrong
        // question — the question is "has it EVER disagreed", and a failure
        // that self-corrects before anyone looks would otherwise leave no
        // trace at all.
        let previous = try fetchMeta(ClaudeCodeMetaKey.archiveIntegrity, context: context)
        var checks = 0, mismatches = 0, worst = ""
        for field in (previous ?? "").split(separator: "|") {
            if field.hasPrefix("checks=") { checks = Int(field.dropFirst(7)) ?? 0 }
            if field.hasPrefix("mismatches=") { mismatches = Int(field.dropFirst(11)) ?? 0 }
            if field.hasPrefix("first=") { worst = String(field) }
        }
        checks += 1

        let stamp = Int(now.timeIntervalSince1970)
        var verdict: String
        if archived == stored {
            verdict = "ok|\(stamp)|\(archived.rows)"
        } else {
            mismatches += 1
            // The store's samples for the same days, counted, so a rollup
            // that disagrees with its own samples can be told from an archive
            // that is off (#433). A COUNT on the (date, model) index walks
            // every row before today: O(rows), 0.24 s of CPU for 1.17M rows
            // on a store copy, on the scan actor, once per failing hourly
            // check. Skipped while a scan cycle is part-way through, when the
            // rollups may still be catching up with samples it already saved.
            // nil if the count fails, which must not stop the check.
            let midScan = ScanCoordinator.isCycleInFlight
            let sampleRows = midScan ? nil : (try? context.fetchCount(FetchDescriptor<TokenSample>(
                predicate: #Predicate<TokenSample> { $0.date < today }))).map(Int64.init)
            var detail = "rows \(archived.rows)/\(stored.rows) out \(archived.output)/\(stored.output)"
            // The other token fields only where they differ, so the line in
            // the log (and in `make verify-data`) names the field (#433).
            for (name, a, s) in [("in", archived.input, stored.input),
                                 ("cacheRead", archived.cacheRead, stored.cacheRead),
                                 ("cc5m", archived.cc5m, stored.cc5m),
                                 ("cc1h", archived.cc1h, stored.cc1h)] where a != s {
                detail += " \(name) \(a)/\(s)"
            }
            if let sampleRows { detail += " samples \(sampleRows)" }
            if midScan { detail += " mid-scan" }
            // Direction and order of magnitude only, per field: what the
            // check-in sends.
            for key in ArchiveIntegrityGap.counterKeys(
                archived: Self.sums(archived), stored: Self.sums(stored),
                sampleRows: sampleRows, midScan: midScan) {
                TelemetryCounters.add(key)
            }
            verdict = "mismatch|\(stamp)|\(detail)"
            // Widen the next reconcile pass to everything. Convergence then
            // doesn't depend on the window having been wide enough, which is
            // the assumption that let this run for six days.
            needsFullReconcile = true
            // Only the FIRST divergence is kept: it's the one with diagnostic
            // value. Later ones are usually the same fault still present.
            if worst.isEmpty { worst = "first=\(stamp):\(detail)" }
            Log.write("ArchiveSync", "INTEGRITY: archive disagrees with the store — \(detail)")
        }
        verdict += "|checks=\(checks)|mismatches=\(mismatches)"
        if !worst.isEmpty { verdict += "|" + worst }
        // Integrity checks run on the sync's own slow cadence, so one tally
        // add each; the check-in sends ok vs mismatch.
        TelemetryCounters.add(archived == stored ? "data.archive_integrity.ok" : "data.archive_integrity.mismatch")
        // Logged every time, not only on failure: a soak needs to distinguish
        // "clean for two days" from "never ran".
        Log.write("ArchiveSync",
                  "integrity check \(checks): \(archived == stored ? "ok" : "MISMATCH") "
                  + "(\(archived.rows) turns, \(mismatches) mismatch(es) all-time)")
        try writeMeta(ClaudeCodeMetaKey.archiveIntegrity, value: verdict, context: context)
    }

    private static func sums(_ t: RawArchive.Totals) -> ArchiveIntegrityGap.Sums {
        .init(rows: t.rows, input: t.input, output: t.output,
              cacheRead: t.cacheRead, cc5m: t.cc5m, cc1h: t.cc1h)
    }

    private func fetchMeta(_ key: String, context: ModelContext) throws -> String? {
        try context.fetch(FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key })).first?.value
    }

    private func writeMeta(_ key: String, value: String, context: ModelContext) throws {
        let existing = try context.fetch(FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key })).first
        if let existing { existing.value = value }
        else { context.insert(ClaudeCodeMeta(key: key, value: value)) }
        try context.save()
    }

    /// Turns currently archived — for `make verify-data` and diagnostics.
    func archivedTurnCount() -> Int64? {
        guard !disabled, let count = try? openIfNeeded().totals().rows else { return nil }
        return count
    }

    /// One place both the forward path and reconciliation build a row, so the
    /// two can't drift on something like which project path gets recorded.
    private func row(from sample: TokenSample) -> ArchiveRow {
        ArchiveRow(
            sampledAt: sample.sampledAt,
            date: sample.date,
            localHour: sample.localHour >= 0
                ? sample.localHour
                : Calendar.current.component(.hour, from: sample.sampledAt),
            model: sample.model,
            breakdown: sample.breakdown,
            sourceCostUSD: sample.sourceCostUSD,
            dedupKey: sample.dedupKey,
            sessionId: sample.sessionId,
            // The RAW cwd — canonicalization is a view over the alias graph,
            // and the graph changes. Never bake it in here.
            originalProjectPath: sample.originalProjectPath ?? sample.projectPath,
            ccVersion: sample.ccVersion,
            accountId: sample.accountId,
            speed: sample.speed,
            inferenceGeo: sample.inferenceGeo)
    }

    private func openIfNeeded() throws -> RawArchive {
        if let archive { return archive }
        let opened = try RawArchive(url: archiveURL)
        // Once per launch, and a no-op unless something is actually wrong.
        // The store's own duplicate repair removes rows the archive already
        // holds; without this the two would disagree forever and
        // `make verify-data` would fail on every run from then on.
        if let removed = try? opened.collapseDuplicates(), removed > 0 {
            Log.write("ArchiveSync", "collapsed \(removed) duplicate turn(s) in the archive")
            TelemetryCounters.add("data.archive_duplicates_collapsed", Int(removed))
        }
        archive = opened
        return opened
    }
}
