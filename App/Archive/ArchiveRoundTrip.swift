import Foundation
import SwiftData
import PacerCore

/// Proves the archive can give back exactly what it was given — every field,
/// against the real store, without changing anything.
///
/// This is the check that has to pass before SwiftData is ever allowed to drop
/// a raw row. The distinction it establishes is the whole argument:
///
/// - A trim you **cannot** undo is a deletion. It needs the archive to be
///   perfect, forever, and the six-day soak showed it wasn't (466 turns
///   recorded short — `docs/duckdb-archive.md`).
/// - A trim you **can** undo is a cache eviction. It needs the archive to be
///   *restorable*, which is a claim you can test on demand rather than a
///   property you have to hope for.
///
/// Until now the archive was write-only: it could report how many turns it
/// held and what they summed to, but not hand one back. Totals agreeing is a
/// checksum, not a restore — two files can agree on every sum while disagreeing
/// on which turn belongs to which project.
///
///     PACER_ARCHIVE_ROUNDTRIP=1 /Applications/Pacer.app/Contents/MacOS/Pacer
///
/// Read-only. It compares, prints, and exits; it never writes to either store.
/// Pacer must be closed, because DuckDB takes an exclusive per-process lock.
@MainActor
enum ArchiveRoundTrip {

    static var isActive: Bool {
        ProcessInfo.processInfo.environment["PACER_ARCHIVE_ROUNDTRIP"] == "1"
    }

    /// How many recent days to verify. Enough to be meaningful, bounded so the
    /// check stays a few seconds rather than a full-history read.
    private static let days = 14

    private static func log(_ message: String) { print("[roundtrip] \(message)") }

    static func run(container: ModelContainer, archiveURL: URL) async {
        let archive: RawArchive
        do {
            archive = try RawArchive(url: archiveURL)
        } catch {
            log("FAIL: cannot open archive (is Pacer still running?) — \(error)")
            return
        }

        let context = ModelContext(container)
        let calendar = Calendar.current
        var totalCompared = 0, totalMissing = 0, totalExtra = 0
        var fieldMismatches: [String: Int] = [:]

        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: Date())
            else { continue }
            let date = TokenSample.formatDate(day)

            let archived: [ArchiveRow]
            do { archived = try archive.turns(onDate: date) }
            catch { log("FAIL: read \(date) — \(error)"); return }

            var descriptor = FetchDescriptor<TokenSample>(
                predicate: #Predicate<TokenSample> { $0.date == date })
            descriptor.propertiesToFetch = [
                \.sampledAt, \.date, \.localHour, \.model, \.inputTokens, \.outputTokens,
                \.cacheReadTokens, \.cacheCreation5mTokens, \.cacheCreation1hTokens,
                \.sourceCostUSD, \.dedupKey, \.sessionId, \.originalProjectPath,
                \.projectPath, \.ccVersion]
            let stored = (try? context.fetch(descriptor)) ?? []

            // Keyed on dedupKey — the identity the whole app already agrees on.
            var byKey: [String: TokenSample] = [:]
            for sample in stored { if let k = sample.dedupKey, !k.isEmpty { byKey[k] = sample } }

            var seen = Set<String>()
            for row in archived {
                guard let key = row.dedupKey, !key.isEmpty else { continue }
                seen.insert(key)
                guard let sample = byKey[key] else { totalExtra += 1; continue }
                totalCompared += 1

                func check(_ field: String, _ equal: Bool) {
                    if !equal { fieldMismatches[field, default: 0] += 1 }
                }
                // Sub-millisecond tolerance: the store keeps a Double and the
                // archive microseconds, so exact equality would fail on
                // representation rather than on content.
                check("sampledAt", abs(row.sampledAt.timeIntervalSince(sample.sampledAt)) < 0.001)
                check("date", row.date == sample.date)
                check("model", row.model == sample.model)
                check("input", row.breakdown.inputTokens == sample.inputTokens)
                check("output", row.breakdown.outputTokens == sample.outputTokens)
                check("cacheRead", row.breakdown.cacheReadTokens == sample.cacheReadTokens)
                check("cc5m", row.breakdown.cacheCreation5mTokens == sample.cacheCreation5mTokens)
                check("cc1h", row.breakdown.cacheCreation1hTokens == sample.cacheCreation1hTokens)
                check("sourceCost", row.sourceCostUSD == sample.sourceCostUSD)
                check("sessionId", row.sessionId == sample.sessionId)
                check("ccVersion", row.ccVersion == sample.ccVersion)
                // The archive stores the RAW cwd by design; the store may have
                // canonicalized `projectPath` since. Compare against what was
                // actually recorded.
                check("projectPath",
                      row.originalProjectPath == (sample.originalProjectPath ?? sample.projectPath))
                if sample.localHour >= 0 { check("localHour", row.localHour == sample.localHour) }
            }
            for (key, _) in byKey where !seen.contains(key) { totalMissing += 1 }
        }

        log("compared \(totalCompared) turn(s) across the last \(days) day(s)")
        if totalMissing > 0 { log("  ✗ \(totalMissing) in the store but NOT in the archive") }
        if totalExtra > 0 { log("  ✗ \(totalExtra) in the archive but NOT in the store") }
        if fieldMismatches.isEmpty && totalMissing == 0 && totalExtra == 0 {
            log("  ✓ every field round-tripped — the archive can restore what it was given")
        } else {
            for (field, count) in fieldMismatches.sorted(by: { $0.value > $1.value }) {
                log("  ✗ \(field): \(count) mismatch(es)")
            }
        }
    }
}
