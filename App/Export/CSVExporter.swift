import Foundation
import AppKit
import SwiftData
import PacerCore

/// CSV export helpers. Two flavors:
///
///   - `dailyByModel(...)`  one row per (date, model) — mirrors the
///                          shape of `DailyAggregate`. Most useful for
///                          spreadsheet pivot analysis.
///   - `dailyTotals(...)`   one row per date (sum across models). Best
///                          for "what did I spend per day" line plots.
///
/// All exports go through `runSavePanelAndWrite` which presents a
/// standard NSSavePanel; the user can cancel and nothing happens.
/// On write error we surface a non-blocking NSAlert so the user
/// knows the file didn't land.
@MainActor
enum CSVExporter {

    static func dailyByModel(context: ModelContext) {
        do {
            let descriptor = FetchDescriptor<DailyAggregate>(
                sortBy: [SortDescriptor(\.date), SortDescriptor(\.model)]
            )
            let rows = try context.fetch(descriptor)
            var csv = "date,model,input_tokens,output_tokens,cache_read_tokens,cache_creation_5m_tokens,cache_creation_1h_tokens,total_cost_usd\n"
            for r in rows {
                csv += "\(r.date),\(escape(r.model)),\(r.inputTokens),\(r.outputTokens),\(r.cacheReadTokens),\(r.cacheCreation5mTokens),\(r.cacheCreation1hTokens),\(format(r.totalCostUSD))\n"
            }
            runSavePanelAndWrite(
                suggestedName: "pacer-daily-by-model.csv",
                contents: csv
            )
        } catch {
            presentError("Couldn't read daily aggregates: \(error.localizedDescription)")
        }
    }

    static func dailyTotals(context: ModelContext) {
        do {
            let descriptor = FetchDescriptor<DailyAggregate>(
                sortBy: [SortDescriptor(\.date)]
            )
            let rows = try context.fetch(descriptor)
            // Sum across models within each date.
            struct Acc {
                var input: Int64 = 0
                var output: Int64 = 0
                var cacheRead: Int64 = 0
                var cache5m: Int64 = 0
                var cache1h: Int64 = 0
                var cost: Double = 0
            }
            var byDate: [String: Acc] = [:]
            for r in rows {
                var a = byDate[r.date] ?? Acc()
                a.input += r.inputTokens
                a.output += r.outputTokens
                a.cacheRead += r.cacheReadTokens
                a.cache5m += r.cacheCreation5mTokens
                a.cache1h += r.cacheCreation1hTokens
                a.cost += r.totalCostUSD
                byDate[r.date] = a
            }
            var csv = "date,input_tokens,output_tokens,cache_read_tokens,cache_creation_5m_tokens,cache_creation_1h_tokens,total_cost_usd\n"
            for (date, a) in byDate.sorted(by: { $0.key < $1.key }) {
                csv += "\(date),\(a.input),\(a.output),\(a.cacheRead),\(a.cache5m),\(a.cache1h),\(format(a.cost))\n"
            }
            runSavePanelAndWrite(
                suggestedName: "pacer-daily-totals.csv",
                contents: csv
            )
        } catch {
            presentError("Couldn't read daily aggregates: \(error.localizedDescription)")
        }
    }

    static func projectTotals(context: ModelContext) {
        do {
            // Read from the precomputed `ProjectDailyAggregate` rollup
            // instead of walking raw `TokenSample` rows. On a power
            // user's DB the sample table can hit 500K rows; the rollup
            // is at most N_projects × N_days (~3,650 typical). Cost is
            // already applied at the user's current mode by
            // `ProjectAggregateRecomputer`, so the CSV matches what
            // the app shows by construction — no per-row pricing call
            // on this code path.
            let descriptor = FetchDescriptor<ProjectDailyAggregate>(
                sortBy: [SortDescriptor(\.projectPath), SortDescriptor(\.date)]
            )
            let rows = try context.fetch(descriptor)
            struct Acc {
                var input: Int64 = 0
                var output: Int64 = 0
                var cacheRead: Int64 = 0
                var cost: Double = 0
                var sessions: Set<String> = []
                var lastSeen: Date = .distantPast
            }
            var byProject: [String: Acc] = [:]
            let decoder = JSONDecoder()
            for r in rows {
                var a = byProject[r.projectPath] ?? Acc()
                a.input += r.inputTokens
                a.output += r.outputTokens
                a.cacheRead += r.cacheReadTokens
                a.cost += r.totalCostUSD
                // Union session ids across this project's day buckets
                // so a session that spans midnight isn't double-counted.
                // The rollup's per-bucket sessionCount overcounts in
                // that case (it's per-day); the JSON id list lets us
                // dedup across days.
                if let ids = try? decoder.decode([String].self, from: r.sessionIdsJSON) {
                    a.sessions.formUnion(ids)
                }
                if r.lastActive > a.lastSeen { a.lastSeen = r.lastActive }
                byProject[r.projectPath] = a
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            var csv = "project_path,input_tokens,output_tokens,cache_read_tokens,sessions,last_seen,total_cost_usd\n"
            for (path, a) in byProject.sorted(by: { $0.key < $1.key }) {
                let lastSeen = a.lastSeen > .distantPast ? formatter.string(from: a.lastSeen) : ""
                csv += "\(escape(path)),\(a.input),\(a.output),\(a.cacheRead),\(a.sessions.count),\(lastSeen),\(format(a.cost))\n"
            }
            runSavePanelAndWrite(
                suggestedName: "pacer-project-totals.csv",
                contents: csv
            )
        } catch {
            presentError("Couldn't read project aggregates: \(error.localizedDescription)")
        }
    }

    // MARK: - Plumbing

    /// CSV-escape a value. Delegates to the tested PacerCore helper
    /// so the escaping rules stay in one place.
    private static func escape(_ value: String) -> String {
        CSVField.escape(value)
    }

    private static func format(_ usd: Double) -> String {
        CSVField.formatUSD(usd)
    }

    @MainActor
    private static func runSavePanelAndWrite(suggestedName: String, contents: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.title = "Export Pacer data"
        panel.message = "Choose where to save the CSV."
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            // Reveal in Finder so the user can confirm the export
            // landed and grab it without re-navigating to wherever they
            // saved it. Matches the post-save behavior of most native
            // macOS export flows (Numbers, Preview, Pages).
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            presentError("Couldn't write file: \(error.localizedDescription)")
        }
    }

    @MainActor
    private static func presentError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Export failed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
