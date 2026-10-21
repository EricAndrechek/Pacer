import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// Runs BOTH ingest paths over the same transcripts against two copies of the
/// same real store, and dumps what each one left behind, row by row (AGENTS.md
/// rule 8, `docs/duckdb-archive.md` "the differential gate").
///
/// The two paths are the line parser (`JSONLScanner` → `SamplePersister`, the
/// fallback when the bulk import fails) and the DuckDB bulk importer
/// (`ArchiveImporter` → `SamplePersister`, what a full scan normally uses).
/// They must leave identical rows. Totals alone can't show that they do — a
/// key upgraded on one side and a different key on the other can cancel — so
/// this writes every row of both stores, plus every entry each path handed
/// the persister, and the comparison is done on those.
///
/// It drives the persister exactly as a full-scan cycle does
/// (`backfillsPricingDetail`, the store's aliases, every root the resolver
/// gives), but stops after the persister's flush: the rollup rebuild that
/// follows reads the samples and can't change them, and is most of the
/// cycle's memory.
///
/// PacerCore can't link DuckDB, so this only runs from `bin/dev-ingest-parity.sh`,
/// which compiles it beside `ArchiveImporter` and the vendored engine, and
/// reports any key the two dumps disagree on:
///
///     bin/dev-ingest-parity.sh <copy of a pre-upgrade pacer.sqlite> <claude dir> <out dir>
///
/// `IngestParityTests` is the same comparison on a synthetic tree, for CI.
@Suite("Ingest parity probe",
       .enabled(if: ProcessInfo.processInfo.environment["PACER_PARITY_PROBE_OUT"] != nil))
struct IngestParityProbe {

    func log(_ s: String) {
        print("\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) [parity] \(s)")
    }

    #if canImport(CDuckDB)
    @ScanActor
    @Test func bothPathsLeaveTheSameRows() async throws {
        let env = ProcessInfo.processInfo.environment
        let outDir = URL(fileURLWithPath: try #require(env["PACER_PARITY_PROBE_OUT"]))
        let claudeDir = try #require(env["PACER_PARITY_PROBE_CLAUDE_DIR"])
        let stores: [(name: String, url: URL)] = [
            ("line", URL(fileURLWithPath: try #require(env["PACER_PARITY_PROBE_STORE_LINE"]))),
            ("bulk", URL(fileURLWithPath: try #require(env["PACER_PARITY_PROBE_STORE_BULK"]))),
        ]
        if let live = try? PacerStore.storeURL() {
            for store in stores {
                let same = store.url.resolvingSymlinksInPath().path == live.resolvingSymlinksInPath().path
                #expect(!same)
                guard !same else { return }
            }
        }
        let roots = try ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": claudeDir]).resolve()
        let only = env["PACER_PARITY_PROBE_ONLY"]

        for store in stores where only == nil || only == store.name {
            let started = Date()
            let container = try PacerStore.makeModelContainer(at: store.url)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            var aliases: [String: String] = [:]
            for row in try context.fetch(FetchDescriptor<ProjectPathAlias>()) {
                aliases[row.sourcePath] = row.canonicalPath
            }
            let persister = try SamplePersister(context: context)
            persister.backfillsPricingDetail = true
            try persister.ensurePreloaded()
            log("\(store.name): store open and dedup map built in \(Self.seconds(since: started))")

            let read = Date()
            if store.name == "line" {
                // The script reports rows for turns written after this as live
                // drift: the bulk read comes later and sees more.
                try String(read.timeIntervalSince1970).write(
                    to: outDir.appendingPathComponent("read-started.txt"), atomically: true, encoding: .utf8)
            }
            let entries: [ParsedUsageEntry]
            if store.name == "line" {
                let box = Collected()
                _ = try await JSONLScanner().scan(roots: roots, aliases: aliases, emit: { box.append($0) })
                entries = box.drain()
            } else {
                entries = try ArchiveImporter().importAll(roots: roots, aliases: aliases).entries
            }
            log("\(store.name): \(entries.count) entries read in \(Self.seconds(since: read))")
            try Self.writeEmissions(entries, to: outDir.appendingPathComponent("\(store.name)-emitted.tsv"))

            for entry in entries { _ = try persister.insert(entry) }
            try persister.flush()
            try context.save()
            let s = persister.stats
            log("\(store.name): inserted \(s.inserted) · upgraded \(s.upgradedFromPartial) · "
                + "patched \(s.patchedPricingDetail) · skipped \(s.skippedAsDuplicate)")
            try "\(s.inserted)\t\(s.upgradedFromPartial)\t\(s.patchedPricingDetail)\t\(s.skippedAsDuplicate)\n"
                .write(to: outDir.appendingPathComponent("\(store.name)-stats.tsv"), atomically: true, encoding: .utf8)
            let totals = try Self.writeRows(ModelContext(container),
                                            to: outDir.appendingPathComponent("\(store.name)-rows.tsv"))
            log("\(store.name): \(totals)")
        }
    }
    #endif

    /// Collects what the scanner emits. The scanner's callback is `@Sendable`
    /// and synchronous; the lock is what makes the append safe.
    final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [ParsedUsageEntry] = []
        func append(_ e: ParsedUsageEntry) { lock.lock(); entries.append(e); lock.unlock() }
        func drain() -> [ParsedUsageEntry] { lock.lock(); defer { lock.unlock() }; return entries }
    }

    static func seconds(since date: Date) -> String {
        String(format: "%.1f s", Date().timeIntervalSince(date))
    }

    /// Every keyed entry in the order the persister received it.
    static func writeEmissions(_ entries: [ParsedUsageEntry], to url: URL) throws {
        var out = "seq\tkey\tts\toutput\tcomplete\tpart\tinput\tcache_read\tcc5m\tcc1h\n"
        for (seq, e) in entries.enumerated() {
            guard let key = e.dedupKey else { continue }
            let b = e.breakdown
            let fields: [String] = [
                String(seq), key, String(e.timestamp.timeIntervalSince1970),
                String(b.outputTokens), e.isComplete ? "1" : "0", e.isIterationPart ? "1" : "0",
                String(b.inputTokens), String(b.cacheReadTokens),
                String(b.cacheCreation5mTokens), String(b.cacheCreation1hTokens),
            ]
            out += fields.joined(separator: "\t") + "\n"
        }
        try out.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Every sample's stored fields, one row per line, sorted, so two stores
    /// compare with `cmp`/`comm`. Returns the six-field totals.
    @ScanActor
    static func writeRows(_ context: ModelContext, to url: URL) throws -> String {
        var lines: [String] = []
        var tokens = [Int64](repeating: 0, count: 5)
        try context.enumerate(FetchDescriptor<TokenSample>(), batchSize: 5_000) { s in
            tokens[0] += s.inputTokens; tokens[1] += s.outputTokens; tokens[2] += s.cacheReadTokens
            tokens[3] += s.cacheCreation5mTokens; tokens[4] += s.cacheCreation1hTokens
            // Seconds as Swift prints a Double: exact, and readable by awk.
            let stamp: String = String(s.sampledAt.timeIntervalSince1970)
            let cost: String = s.sourceCostUSD.map { String($0.bitPattern, radix: 16) } ?? "-"
            var parts: [String] = [s.dedupKey ?? "-", stamp, s.date, s.model, String(s.localHour)]
            parts += [String(s.inputTokens), String(s.outputTokens), String(s.cacheReadTokens)]
            parts += [String(s.cacheCreation5mTokens), String(s.cacheCreation1hTokens), cost]
            parts += [s.sessionId ?? "-", s.projectPath ?? "-", s.originalProjectPath ?? "-"]
            parts += [s.ccVersion ?? "-", s.accountId ?? "-", s.speed ?? "-", s.inferenceGeo ?? "-"]
            lines.append(parts.joined(separator: "\t"))
        }
        lines.sort()
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return "rows=\(lines.count) input=\(tokens[0]) output=\(tokens[1]) cacheRead=\(tokens[2]) "
            + "cc5m=\(tokens[3]) cc1h=\(tokens[4])"
    }
}
