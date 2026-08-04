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
            var descriptor = FetchDescriptor<TokenSample>(
                sortBy: [SortDescriptor(\.sampledAt, order: .forward)])
            if let watermark {
                descriptor.predicate = #Predicate<TokenSample> { $0.sampledAt > watermark }
            }
            var rows: [ArchiveRow] = []
            var newest = watermark
            try context.enumerate(descriptor, batchSize: 5_000) { sample in
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
            rows.append(contentsOf: try missedTurns(
                archive: archive, context: context,
                // Already staged by the forward path above and NOT yet in the
                // archive, so reconciliation would otherwise "rescue" them a
                // second time. An append-only table can't take that back —
                // caught only because the check counted one row too many.
                pending: Set(rows.compactMap(\.dedupKey))))

            if !rows.isEmpty { try archive.append(rows) }
            // Advanced only after the append succeeded, so a failed write is
            // retried rather than skipped.
            if !rows.isEmpty { watermark = newest }
            appendedTotal += rows.count
            // Logged sparsely — every cycle would be noise, but silence made
            // it impossible to tell "working" from "never ran".
            if !rows.isEmpty, appendedTotal >= nextLogAt {
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

    /// Store turns inside the trailing window that the archive doesn't have.
    ///
    /// Keyed on `dedupKey` because that's the identity the rest of the app
    /// already agrees on. Turns without one (no message id and no request id)
    /// can't be matched and are left to the forward path — they're rare, and
    /// guessing at identity here would risk archiving the same turn twice,
    /// which an append-only table can't take back.
    private func missedTurns(archive: RawArchive, context: ModelContext,
                             pending: Set<String>) throws -> [ArchiveRow] {
        let now = Date()
        if let last = lastReconcileAt,
           now.timeIntervalSince(last) < Self.reconcileInterval { return [] }
        lastReconcileAt = now

        let since = now.addingTimeInterval(-Self.reconcileWindow)
        let archived = try archive.dedupKeys(since: since)

        var descriptor = FetchDescriptor<TokenSample>(
            predicate: #Predicate<TokenSample> { $0.sampledAt >= since },
            sortBy: [SortDescriptor(\.sampledAt, order: .forward)])
        descriptor.propertiesToFetch = [
            \.sampledAt, \.date, \.localHour, \.model, \.dedupKey, \.sessionId,
            \.originalProjectPath, \.projectPath, \.ccVersion, \.sourceCostUSD]

        var missed: [ArchiveRow] = []
        try context.enumerate(descriptor, batchSize: 5_000) { sample in
            guard let key = sample.dedupKey,
                  !archived.contains(key), !pending.contains(key) else { return }
            missed.append(row(from: sample))
        }
        if !missed.isEmpty {
            Log.write("ArchiveSync",
                      "reconcile: \(missed.count) turn(s) the watermark had skipped")
        }
        return missed
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

        let stamp = Int(now.timeIntervalSince1970)
        let verdict: String
        if archived == stored {
            verdict = "ok|\(stamp)|\(archived.rows)"
        } else {
            let detail = "rows \(archived.rows)/\(stored.rows) out \(archived.output)/\(stored.output)"
            verdict = "mismatch|\(stamp)|\(detail)"
            Log.write("ArchiveSync", "INTEGRITY: archive disagrees with the store — \(detail)")
        }
        try writeMeta(ClaudeCodeMetaKey.archiveIntegrity, value: verdict, context: context)
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
            ccVersion: sample.ccVersion)
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
        }
        archive = opened
        return opened
    }
}
