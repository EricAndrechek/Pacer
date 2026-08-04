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
                rows.append(ArchiveRow(
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
                    // The RAW cwd — canonicalization is a view over the alias
                    // graph, and the graph changes. Never bake it in here.
                    originalProjectPath: sample.originalProjectPath ?? sample.projectPath,
                    ccVersion: sample.ccVersion))
            }
            guard !rows.isEmpty else { return }
            try archive.append(rows)
            // Advanced only after the append succeeded, so a failed write is
            // retried rather than skipped.
            watermark = newest
            appendedTotal += rows.count
            // Logged sparsely — every cycle would be noise, but silence made
            // it impossible to tell "working" from "never ran".
            if appendedTotal >= nextLogAt {
                Log.write("ArchiveSync", "archived \(appendedTotal) turn(s) this session")
                nextLogAt = appendedTotal + 500
            }
        } catch {
            Log.write("ArchiveSync", "disabled after error: \(error)")
            disabled = true
            archive = nil
        }
    }

    /// Turns currently archived — for `make verify-data` and diagnostics.
    func archivedTurnCount() -> Int64? {
        guard !disabled, let count = try? openIfNeeded().totals().rows else { return nil }
        return count
    }

    private func openIfNeeded() throws -> RawArchive {
        if let archive { return archive }
        let opened = try RawArchive(url: archiveURL)
        archive = opened
        return opened
    }
}
