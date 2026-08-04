import Foundation
import SwiftData
import PacerCore

/// Measures what a *first* launch costs: an empty store, the real scanner, a
/// real `~/.claude`.
///
/// Exists because two classes of bug in the ingest path are invisible without
/// it, both learned the hard way (AGENTS.md correctness rule §8):
///
///   - **Scale bugs.** A fresh in-memory store has nothing to upgrade and no
///     cursors to rewrite, so per-item fetches look fine right up until they
///     meet a real store and pin a core at 98% with gigabytes resident.
///   - **Field-mapping bugs.** A matching row *count* proves the filter and
///     dedup agree; only per-field token sums prove the mapping does. A
///     swapped cache tier keeps every count identical while silently changing
///     everyone's cost.
///
/// Run it headless — it never touches the real store (in-memory container),
/// never starts the scan loop, and writes nothing:
///
///     PACER_COLD_START_PROBE=1 /Applications/Pacer.app/Contents/MacOS/Pacer
///
/// Point it at a *frozen* copy of a transcript tree so results are comparable
/// across runs while your live transcripts keep growing:
///
///     cp -R ~/.claude/projects /tmp/frozen/projects
///     CLAUDE_CONFIG_DIR=/tmp/frozen PACER_COLD_START_PROBE=1 …/Pacer
@MainActor
enum ColdStartProbe {

    static var isActive: Bool {
        ProcessInfo.processInfo.environment["PACER_COLD_START_PROBE"] == "1"
    }

    private static func log(_ message: String) { print("[cold-start] \(message)") }

    static func run() async {
        log("empty in-memory store, real scanner, resolved Claude roots")
        guard let container = try? PacerStore.makeInMemoryContainer() else {
            log("FAIL: in-memory container"); return
        }
        await SampleCostCache.reload()

        let start = Date()
        do {
            let report = try await ScanCoordinator(container: container).runOnce()
            let p = report.phaseTimings
            log(String(format: "TOTAL %.1f s", Date().timeIntervalSince(start)))
            log("  parsed \(report.scanProgress.entriesParsed) entries from "
                + "\(report.scanProgress.filesScanned) files, "
                + "inserted \(report.persisterStats.inserted), "
                + "upgraded \(report.persisterStats.upgradedFromPartial)")
            log(String(format: "  parse %.0f · cursors %.0f · daily %.0f · hourly %.0f "
                       + "· project %.0f · session %.0f ms",
                       p.scanMs, p.saveCursorsMs, p.dailyRecomputeMs, p.hourlyRecomputeMs,
                       p.projectRecomputeMs, p.sessionRecomputeMs))
            log("  " + (await totals(container: container)))
        } catch {
            log("FAIL: scan threw \(error)")
        }
    }

    /// Per-field sums — the part that catches a mapping error a row count
    /// would sail past. Runs on `ScanActor` because `TokenSample` can't cross
    /// actors; only the numbers come back.
    @ScanActor
    private static func totals(container: ModelContainer) -> String {
        let context = ModelContext(container)
        guard let rows = try? context.fetch(FetchDescriptor<TokenSample>()) else {
            return "TOTALS unavailable"
        }
        var input: Int64 = 0, output: Int64 = 0, read: Int64 = 0
        var cc5m: Int64 = 0, cc1h: Int64 = 0
        for r in rows {
            input += r.inputTokens; output += r.outputTokens; read += r.cacheReadTokens
            cc5m += r.cacheCreation5mTokens; cc1h += r.cacheCreation1hTokens
        }
        return "TOTALS rows=\(rows.count) input=\(input) output=\(output) "
            + "cacheRead=\(read) cc5m=\(cc5m) cc1h=\(cc1h) "
            + "all=\(input + output + read + cc5m + cc1h)"
    }
}
