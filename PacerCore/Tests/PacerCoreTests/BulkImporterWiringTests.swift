import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// `ScanCoordinator`'s use of an injected `BulkTranscriptImporter`.
///
/// The importer is a *full-scan* accelerator: first launch, or a
/// `currentScanVersion` bump re-deriving history. Incremental cycles must
/// never touch it — they resume from byte cursors and a bulk reader has no
/// way to beat that. And because the line parser can always do the job, an
/// importer that fails has to cost time, not correctness.
@Suite struct BulkImporterWiringTests {

    /// Records how it was called and returns whatever it was told to.
    private final class StubImporter: BulkTranscriptImporter, @unchecked Sendable {
        let entries: [ParsedUsageEntry]
        let error: Error?
        private(set) var callCount = 0

        init(entries: [ParsedUsageEntry] = [], error: Error? = nil) {
            self.entries = entries
            self.error = error
        }

        struct Boom: Error {}

        func importAll(roots: [URL], aliases: [String: String]) throws -> BulkImportResult {
            callCount += 1
            if let error { throw error }
            return BulkImportResult(entries: entries, fileMarks: [:], seconds: 0)
        }
    }

    /// An empty `projects/` tree in a temp dir. Every test here must resolve
    /// to this rather than the developer's real `~/.claude`: scanning that is
    /// slow (~90 s), non-deterministic, and behaves differently in CI than on
    /// a laptop — the first version of these tests did exactly that and
    /// "passed" by ingesting 55,077 of the maintainer's own rows.
    private func isolatedResolver() throws -> (ClaudePathResolver, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pacer-bulk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("projects"), withIntermediateDirectories: true)
        return (ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": root.path]), root)
    }

    private func entry(_ id: String, output: Int64) -> ParsedUsageEntry {
        ParsedUsageEntry(
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            model: "claude-opus-5",
            breakdown: TokenBreakdown(inputTokens: 10, outputTokens: output,
                                      cacheReadTokens: 0,
                                      cacheCreation5mTokens: 0, cacheCreation1hTokens: 0),
            dedupKey: id,
            sessionId: "s1",
            projectPath: "/Users/dev/code/acme")
    }

    /// An empty store is a full scan by definition (no stored scanVersion), so
    /// the importer runs and its entries land as rows.
    @MainActor
    @Test func fullScanUsesTheImporter() async throws {
        let container = try PacerStore.makeInMemoryContainer()
        let (resolver, root) = try isolatedResolver()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = StubImporter(entries: [entry("a", output: 5), entry("b", output: 7)])
        let coordinator = ScanCoordinator(
            container: container,
            configuration: .init(probeStatsCache: false, bulkImporter: stub),
            resolver: resolver)

        _ = try await coordinator.runOnce()

        #expect(stub.callCount == 1)
        let rows = try ModelContext(container).fetch(FetchDescriptor<TokenSample>())
        #expect(rows.count == 2)
        #expect(rows.reduce(0) { $0 + $1.outputTokens } == 12)
    }

    /// A failing importer must degrade to the line parser rather than abort
    /// the scan — the launch still succeeds, just slower.
    @MainActor
    @Test func importerFailureFallsBackToTheLineParser() async throws {
        let container = try PacerStore.makeInMemoryContainer()
        let (resolver, root) = try isolatedResolver()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = StubImporter(error: StubImporter.Boom())
        let coordinator = ScanCoordinator(
            container: container,
            configuration: .init(probeStatsCache: false, bulkImporter: stub),
            resolver: resolver)

        // Completes rather than throwing: the importer was tried and failed,
        // and the line parser took over. The isolated tree is empty, so the
        // fallback legitimately finds nothing — what matters is that we got a
        // report at all instead of an error.
        let report = try await coordinator.runOnce()
        #expect(stub.callCount == 1)
        #expect(report.persisterStats.inserted == 0)
    }

    /// No importer configured — the widget extension and every test that
    /// doesn't opt in — must behave exactly as before it existed.
    @MainActor
    @Test func absentImporterIsUnchangedBehaviour() async throws {
        let container = try PacerStore.makeInMemoryContainer()
        let (resolver, root) = try isolatedResolver()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = ScanCoordinator(
            container: container,
            configuration: .init(probeStatsCache: false),
            resolver: resolver)
        let report = try await coordinator.runOnce()
        #expect(report.persisterStats.inserted == 0)   // completed with no bulk path
    }
}
