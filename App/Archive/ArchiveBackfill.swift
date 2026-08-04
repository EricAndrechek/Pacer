import Foundation
import SwiftData
import PacerCore

/// Fills the raw archive from the SwiftData store, then proves the two agree.
///
/// Run headless before trusting the archive with anything:
///
///     PACER_ARCHIVE_BACKFILL=1 /Applications/Pacer.app/Contents/MacOS/Pacer
///
/// It reads the real store (read-only — the scan loop never starts), appends
/// every turn not already archived, and compares all six token totals. A row
/// count that matches proves the filter agrees; only per-field sums prove the
/// mapping does, which is the lesson from the streaming-dedup bug — a swapped
/// cache tier leaves every count identical while changing everyone's cost.
@MainActor
enum ArchiveBackfill {

    static var isActive: Bool {
        ProcessInfo.processInfo.environment["PACER_ARCHIVE_BACKFILL"] == "1"
    }

    private static func log(_ message: String) { print("[archive] \(message)") }

    static func run(container: ModelContainer) async {
        let archiveURL: URL
        do {
            archiveURL = try PacerStore.sharedContainerURL()
                .appendingPathComponent("raw-archive.duckdb")
        } catch {
            log("FAIL: no container — \(error)"); return
        }
        log("archive: \(archiveURL.path)")

        do {
            let started = Date()
            // Everything touching the archive happens on ScanActor: a DuckDB
            // connection is a C handle and not thread-safe, so rather than
            // claim `@unchecked Sendable` and hope, it never crosses actors.
            let (before, appended, after, store) = try await backfill(
                container: container, archiveURL: archiveURL)
            log("already archived: \(before.rows) turn(s)")
            log(String(format: "appended %d turn(s) in %.1f s",
                       appended, Date().timeIntervalSince(started)))
            log("  store   rows=\(store.rows) input=\(store.input) output=\(store.output) "
                + "cacheRead=\(store.cacheRead) cc5m=\(store.cc5m) cc1h=\(store.cc1h)")
            log("  archive rows=\(after.rows) input=\(after.input) output=\(after.output) "
                + "cacheRead=\(after.cacheRead) cc5m=\(after.cc5m) cc1h=\(after.cc1h)")
            log(after == store ? "  ✓ MATCH on every field" : "  ✗ MISMATCH")

            if let size = try? FileManager.default
                .attributesOfItem(atPath: archiveURL.path)[.size] as? Int64 {
                log(String(format: "archive file: %.1f MB", Double(size) / 1_048_576))
            }
        } catch {
            log("FAIL: \(error)")
        }
    }

    /// Streams turns newer than the archive's watermark straight into it.
    /// Batched so a large backfill doesn't hold the whole table as objects —
    /// the mistake that cost 646 MB of idle footprint before.
    @ScanActor
    private static func backfill(
        container: ModelContainer, archiveURL: URL
    ) throws -> (RawArchive.Totals, Int, RawArchive.Totals, RawArchive.Totals) {
        let archive = try RawArchive(url: archiveURL)
        let before = try archive.totals()
        let watermark = try archive.watermark()
        // Sum the store in the SAME pass that appends, so the comparison can't
        // be defeated by rows arriving mid-run. A separate pass afterwards
        // reported a phantom 3-row shortfall on a live app — the same "live
        // drift" that once got a genuine bug written off.
        var store = before
        let appended = try appendMissing(container: container, archive: archive,
                                         after: watermark, summing: &store)
        return (before, appended, try archive.totals(), store)
    }

    @ScanActor
    private static func appendMissing(
        container: ModelContainer, archive: RawArchive, after watermark: Date?,
        summing store: inout RawArchive.Totals
    ) throws -> Int {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<TokenSample>(
            sortBy: [SortDescriptor(\.sampledAt, order: .forward)])
        if let watermark {
            descriptor.predicate = #Predicate<TokenSample> { $0.sampledAt > watermark }
        }
        var batch: [ArchiveRow] = []
        var total = 0
        try context.enumerate(descriptor, batchSize: 5_000) { sample in
            store.rows += 1
            store.input += sample.inputTokens
            store.output += sample.outputTokens
            store.cacheRead += sample.cacheReadTokens
            store.cc5m += sample.cacheCreation5mTokens
            store.cc1h += sample.cacheCreation1hTokens
            batch.append(ArchiveRow(
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
                originalProjectPath: sample.originalProjectPath ?? sample.projectPath,
                ccVersion: sample.ccVersion))
            if batch.count >= 5_000 {
                try? archive.append(batch)
                total += batch.count
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty {
            try archive.append(batch)
            total += batch.count
        }
        return total
    }

}
