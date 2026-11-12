import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// Holds the dedup index a quit mid-cycle writes to what a rebuild of the
/// same store builds, on a frozen COPY of a real store (#395, AGENTS.md rule
/// 8). The copy is never written: the cycle's work stays pending in its
/// context and is dropped, as the quit drops it.
///
///     sqlite3 "<store>" ".backup '/tmp/index/store.sqlite'"
///     PACER_INDEX_PROBE_STORE=/tmp/index/store.sqlite PACER_ISOLATED_DEFAULTS=1 \
///     swift test --filter RealStoreDedupIndexProbe
///
/// The pending work: a finished copy of every 2,000th keyed row (an upgrade,
/// applied), of every 1,999th (decided, not yet applied), 300 new turns, and
/// one stored row deleted.
@Suite("Real-store dedup index probe",
       .enabled(if: ProcessInfo.processInfo.environment["PACER_INDEX_PROBE_STORE"] != nil))
struct RealStoreDedupIndexProbe {

    func log(_ s: String) {
        print("\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) [index] \(s)")
    }

    @ScanActor
    @Test func aMidCycleIndexMatchesARebuild() throws {
        let env = ProcessInfo.processInfo.environment
        let storeURL = URL(fileURLWithPath: try #require(env["PACER_INDEX_PROBE_STORE"]))
        if let live = try? PacerStore.storeURL() {
            let same = storeURL.resolvingSymlinksInPath().path == live.resolvingSymlinksInPath().path
            #expect(!same)
            guard !same else { return }
        }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("index-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let container = try PacerStore.makeModelContainer(at: storeURL)

        // A rebuild: the reference.
        var started = Date()
        let rebuilt = try SamplePersister(context: ModelContext(container),
                                          indexURL: scratch.appendingPathComponent("rebuilt.bin"))
        try rebuilt.ensurePreloaded()
        rebuilt.writeDedupIndexIfNeeded(force: true)
        let reference = try #require(DedupIndex.load(from: scratch.appendingPathComponent("rebuilt.bin")))
        log(String(format: "rebuild: %d entries, %d keyed rows, %.1f s",
                   reference.entries.count, reference.rowCount, Date().timeIntervalSince(started)))

        // The cycle the quit catches.
        let context = ModelContext(container)
        let persister = try SamplePersister(context: context, saveBatchSize: .max,
                                            indexURL: scratch.appendingPathComponent("quit.bin"))
        var applied: [ParsedUsageEntry] = []
        var decided: [ParsedUsageEntry] = []
        var victim: PersistentIdentifier?
        var n = 0
        var keyed = FetchDescriptor<TokenSample>(predicate: #Predicate { $0.dedupKey != nil })
        keyed.propertiesToFetch = [\.dedupKey, \.sampledAt, \.model, \.outputTokens, \.sessionId,
                                   \.projectPath, \.inputTokens]
        try ModelWalk.forEach(keyed, in: container) { s in
            defer { n += 1 }
            if n == 1_234 { victim = s.persistentModelID }
            guard n % 2_000 == 0 || n % 1_999 == 0, let key = s.dedupKey else { return }
            let finished = ParsedUsageEntry(
                timestamp: s.sampledAt, model: s.model,
                breakdown: TokenBreakdown(inputTokens: s.inputTokens, outputTokens: s.outputTokens + 7,
                                          cacheReadTokens: 0, cacheCreation5mTokens: 0,
                                          cacheCreation1hTokens: 0),
                storedCostUSD: nil, dedupKey: key, sessionId: s.sessionId,
                projectPath: s.projectPath, isComplete: true)
            if n % 2_000 == 0 { applied.append(finished) } else { decided.append(finished) }
        }
        for e in applied { try persister.insert(e) }
        try persister.flush()
        for e in decided { try persister.insert(e) }
        for i in 0..<300 {
            try persister.insert(ParsedUsageEntry(
                timestamp: Date(timeIntervalSince1970: 1_900_000_000 + Double(i)), model: "claude-opus-5",
                breakdown: TokenBreakdown(inputTokens: 1, outputTokens: 1, cacheReadTokens: 0,
                                          cacheCreation5mTokens: 0, cacheCreation1hTokens: 0),
                storedCostUSD: nil, dedupKey: "probe-msg-\(i):probe-req-\(i)", sessionId: "probe",
                projectPath: "/probe", isComplete: true))
        }
        if let victim, let row = context.model(for: victim) as? TokenSample { context.delete(row) }
        log("pending: \(applied.count) applied upgrade(s), \(decided.count) decided, 300 new turns, 1 delete")

        started = Date()
        persister.writeDedupIndexIfNeeded(force: true)
        let ms = Date().timeIntervalSince(started) * 1000
        let quit = try #require(DedupIndex.load(from: scratch.appendingPathComponent("quit.bin")))
        log(String(format: "mid-cycle write: %d entries, %d keyed rows, %.0f ms", quit.entries.count, quit.rowCount, ms))
        #expect(quit.rowCount == reference.rowCount)
        #expect(quit.entries.count == reference.entries.count)
        let differing = reference.entries.filter { quit.entries[$0.key] != $0.value }.count
        log("entries differing from the rebuild: \(differing)")
        #expect(differing == 0)
        // Dropped, as the quit drops it: the copy is never written.
        context.rollback()
    }
}
