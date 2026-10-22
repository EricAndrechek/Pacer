import Foundation
import Testing
@testable import PacerCore

/// A parity check against `ccusage`, kept as a reference, not a gate (#299).
///
/// Ground truth is the raw JSONL, checked by Pacer's own passes: the
/// hand-computed fixtures (`JSONLScannerFixtureTests` for tokens and the
/// dollars they cost, `PriceLedgerTests`, `CuratedPriceHistoryTests`),
/// `make test-ingest-parity`, and `make verify-data` on a real store. These
/// tests ask a narrower question: do the token counts both tools count the
/// same way still agree? That is input, cache read, and cache creation as
/// one flat number.
///
/// **What is not compared, and why.**
/// - **The 5m/1h cache split.** ccusage flattens `cache_creation`; Pacer keeps
///   both tiers (correctness rule §5). Pacer's two columns are summed to get
///   ccusage's flat number, and *that* must match exactly.
/// - **Output tokens.** ccusage dedups first-wins and keeps the mid-stream copy
///   of a streamed message; Pacer keeps the finished one (rule §7). On a real
///   1,697-file corpus first-wins under-counts output by 29,533,409 tokens, 63%
///   of it. Pacer's output is legitimately higher, so it isn't compared.
/// - **Cost.** ccusage prices every day at today's catalog rate. Pacer prices
///   each request at the rate in effect when it was made, with request tiers,
///   fast mode and data residency. Once any rate has changed, ccusage's
///   `totalCost` is the wrong answer to compare against.
///
/// **Opt-in.** These captured-snapshot tests are gated behind
/// `PACER_RUN_CCUSAGE_SNAPSHOT_TEST=1` and skip otherwise. They compare a
/// *live* scan of the developer's `~/.claude` against a *frozen* ccusage
/// snapshot — which only holds while the snapshot matches what's on disk.
/// In practice Claude Code prunes/rewrites old session files over time,
/// so the live data drifts below the months-old snapshot and these fail
/// even though Pacer is correct (Pacer's own DB keeps the original
/// numbers; the snapshot and the on-disk files are what move). The
/// earlier assumption in this file — "JSONL data for past dates is
/// immutable on disk" — turned out false, which is why the gate exists.
///
/// Run them deliberately, right after recapturing a fresh snapshot, when
/// you want to verify parity with the reference tool:
///
///     bun x ccusage daily --json > docs/research/ccusage-outputs/daily.json
///     PACER_RUN_CCUSAGE_SNAPSHOT_TEST=1 swift test
///
/// The always-on, deterministic correctness gate lives in
/// `JSONLScannerFixtureTests` (synthetic fixture, hand-computed totals,
/// no live data) — that's what protects the parser/dedup/cache-split
/// rules in CI and on every box.
private func capturedSnapshotTestsEnabled() -> Bool {
    ProcessInfo.processInfo.environment["PACER_RUN_CCUSAGE_SNAPSHOT_TEST"] == "1"
}

private struct CcusageDay: Decodable {
    let date: String
    let inputTokens: Int64
    let cacheCreationTokens: Int64
    let cacheReadTokens: Int64
    let modelBreakdowns: [CcusageModelBreakdown]
}

private struct CcusageModelBreakdown: Decodable {
    let modelName: String
    let inputTokens: Int64
    let cacheCreationTokens: Int64
    let cacheReadTokens: Int64
}

private struct CcusageSnapshot: Decodable {
    let daily: [CcusageDay]
}

/// Walks up from this test file to find the project root, then to
/// `docs/research/ccusage-outputs/daily.json`. Avoids hardcoding an
/// absolute path that breaks if the project moves.
private func locateCcusageSnapshot() -> URL? {
    let here = URL(fileURLWithPath: #filePath)
    let projectRoot = here
        .deletingLastPathComponent() // PacerCoreTests/
        .deletingLastPathComponent() // Tests/
        .deletingLastPathComponent() // PacerCore/
        .deletingLastPathComponent() // Pacer/
    let candidate = projectRoot.appendingPathComponent("docs/research/ccusage-outputs/daily.json")
    return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
}

@Test func scannerTotalsMatchCapturedCcusageSnapshot() async throws {
    guard capturedSnapshotTestsEnabled() else { return }
    guard let snapshotURL = locateCcusageSnapshot() else {
        // Captured outputs not present in this checkout — skip silently.
        // Comment from the test author: this means the dev didn't pull
        // in docs/research/ccusage-outputs/. Run `bun x ccusage daily
        // --json > docs/research/ccusage-outputs/daily.json` to refresh.
        return
    }
    let snapshotData = try Data(contentsOf: snapshotURL)
    let snapshot = try JSONDecoder().decode(CcusageSnapshot.self, from: snapshotData)

    let resolver = ClaudePathResolver()
    let roots: [ClaudePathResolver.ResolvedRoot]
    do {
        roots = try resolver.resolve()
    } catch {
        // CLAUDE_CONFIG_DIR misconfigured or no valid root. On a fresh
        // dev box without Claude Code installed, this is the right
        // skip path.
        return
    }
    guard !roots.isEmpty else { return }

    // Per-day totals from Pacer's parser. We use the scanner's raw
    // output (with dedup) directly rather than going through
    // SamplePersister/AggregateRecomputer — this isolates parsing
    // correctness from the persistence layer (which has its own tests).
    var pacerByDate: [String: TokenBreakdown] = [:]
    let collector = DateCollector()
    let scanner = JSONLScanner()
    _ = try await scanner.scan(roots: roots) { entry in
        await collector.add(entry)
    }
    pacerByDate = await collector.byDate()

    let snapshotByDate = Dictionary(uniqueKeysWithValues: snapshot.daily.map { ($0.date, $0) })
    // The snapshot's most-recent date is the day ccusage was run AND
    // captured — and for that day, Claude Code may have continued
    // writing JSONL after the snapshot. Older dates are "completed"
    // and immutable on disk, so they're stable. Skip the latest to
    // avoid a flaky test on the day the user re-runs it.
    let mostRecentSnapshotDate = snapshotByDate.keys.max() ?? ""

    var checkedDays = 0
    for (date, ccu) in snapshotByDate {
        if date == mostRecentSnapshotDate {
            // Snapshot's tail-day total is by definition partial.
            // Skip without complaint — completed-day comparisons are
            // the strong signal we care about.
            continue
        }
        guard let pacer = pacerByDate[date] else {
            // ccusage saw a date that Pacer didn't. Could legitimately
            // happen if ccusage was run from a different CLAUDE_CONFIG_DIR
            // — surface as a soft skip rather than a hard fail.
            continue
        }
        checkedDays += 1
        // Cache-tier rebuild: ccusage's flat number == sum of our split.
        let pacerCacheCreationFlat = pacer.cacheCreation5mTokens + pacer.cacheCreation1hTokens
        #expect(
            pacer.inputTokens == ccu.inputTokens,
            "input mismatch on \(date): pacer=\(pacer.inputTokens) ccusage=\(ccu.inputTokens)"
        )
        #expect(
            pacer.cacheReadTokens == ccu.cacheReadTokens,
            "cacheRead mismatch on \(date): pacer=\(pacer.cacheReadTokens) ccusage=\(ccu.cacheReadTokens)"
        )
        #expect(
            pacerCacheCreationFlat == ccu.cacheCreationTokens,
            "cacheCreation flat-sum mismatch on \(date): pacer(5m+1h)=\(pacerCacheCreationFlat) ccusage=\(ccu.cacheCreationTokens)"
        )
    }
    // If we found the snapshot AND have real data, we expect at least
    // one overlapping day. Otherwise the test silently passes for the
    // wrong reason.
    if !snapshotByDate.isEmpty && !pacerByDate.isEmpty {
        #expect(checkedDays > 0, "no overlapping dates between Pacer and captured ccusage snapshot")
    }
}

/// Optional live-subprocess canary: shells out to `bun x ccusage daily
/// --json` and re-runs the same comparison. Gated on
/// `PACER_RUN_LIVE_CCUSAGE_TEST=1` because (a) it depends on bun being
/// installed and (b) it's slow (3-10s for ccusage to parse the user's
/// dataset). The captured-snapshot test above is the always-on safety
/// net; this one is for a quick "is the snapshot stale?" sanity check
/// before bumping the captured file.
@Test func scannerTotalsMatchLiveCcusageOutput() async throws {
    guard ProcessInfo.processInfo.environment["PACER_RUN_LIVE_CCUSAGE_TEST"] == "1" else {
        return
    }

    let resolver = ClaudePathResolver()
    let roots = (try? resolver.resolve()) ?? []
    guard !roots.isEmpty else { return }

    // Shell out to ccusage. We DON'T use Bundle.module to find bun —
    // we trust the user's PATH. Failure here means bun/ccusage isn't
    // installed, which the env-var gate already implies the user has.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["bun", "x", "ccusage", "daily", "--json"]
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0, "ccusage subprocess failed")

    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    let snapshot = try JSONDecoder().decode(CcusageSnapshot.self, from: data)

    let collector = DateCollector()
    let scanner = JSONLScanner()
    _ = try await scanner.scan(roots: roots) { entry in
        await collector.add(entry)
    }
    let pacerByDate = await collector.byDate()

    // Same skip-the-latest rule as the captured-snapshot test — even
    // a fresh subprocess run can race writes from an active session.
    let latestDate = snapshot.daily.map(\.date).max() ?? ""

    // Live mode runs against the FULL history, where occasional
    // 0.1–1% discrepancies on old dates can crop up from edge cases
    // neither tool handles identically (e.g. a single line with
    // unusual field shapes). Treat as soft warning unless the
    // difference exceeds the tolerance — the captured-snapshot test
    // is the strong correctness assertion.
    func differsBeyondTolerance(_ pacer: Int64, _ ccu: Int64) -> Bool {
        let absDiff = abs(pacer - ccu)
        if absDiff < 1_000 { return false }
        let larger = max(pacer, ccu)
        guard larger > 0 else { return false }
        return Double(absDiff) / Double(larger) > 0.01 // 1%
    }

    var divergentDays: [(String, String)] = []
    for ccu in snapshot.daily where ccu.date != latestDate {
        guard let pacer = pacerByDate[ccu.date] else { continue }
        let pacerCacheCreationFlat = pacer.cacheCreation5mTokens + pacer.cacheCreation1hTokens
        if differsBeyondTolerance(pacer.inputTokens, ccu.inputTokens) {
            divergentDays.append((ccu.date, "input pacer=\(pacer.inputTokens) ccu=\(ccu.inputTokens)"))
        }
        if differsBeyondTolerance(pacer.cacheReadTokens, ccu.cacheReadTokens) {
            divergentDays.append((ccu.date, "cacheRead pacer=\(pacer.cacheReadTokens) ccu=\(ccu.cacheReadTokens)"))
        }
        if differsBeyondTolerance(pacerCacheCreationFlat, ccu.cacheCreationTokens) {
            divergentDays.append((ccu.date, "cacheCreation(5m+1h sum) pacer=\(pacerCacheCreationFlat) ccu=\(ccu.cacheCreationTokens)"))
        }
    }
    // Beyond-tolerance divergence is a real signal worth surfacing.
    // Within-tolerance is logged below for awareness without failing.
    #expect(divergentDays.isEmpty, "live ccusage comparison divergence beyond tolerance: \(divergentDays)")
}

/// Actor wrapper for collecting per-date token totals from the
/// scanner's @Sendable async emit closure. Day rollup happens on this
/// actor so the scanner stays free of SwiftData/persistence concerns.
private actor DateCollector {
    private var totals: [String: TokenBreakdown] = [:]

    func add(_ entry: ParsedUsageEntry) {
        let date = TokenSample.formatDate(entry.timestamp)
        var current = totals[date] ?? TokenBreakdown()
        current.add(entry.breakdown)
        totals[date] = current
    }

    func byDate() -> [String: TokenBreakdown] { totals }
}

/// Per-(date, model) token totals. Used by the modelBreakdowns
/// ground-truth test to confirm Pacer's split matches ccusage's.
private actor DateModelCollector {
    private var totals: [String: [String: TokenBreakdown]] = [:]  // date -> model -> breakdown

    func add(_ entry: ParsedUsageEntry) {
        let date = TokenSample.formatDate(entry.timestamp)
        var dayMap = totals[date] ?? [:]
        var current = dayMap[entry.model] ?? TokenBreakdown()
        current.add(entry.breakdown)
        dayMap[entry.model] = current
        totals[date] = dayMap
    }

    func byDateModel() -> [String: [String: TokenBreakdown]] { totals }
}

/// Per-model breakdown ground truth. For each completed day in the
/// captured snapshot, verify that:
///   - Pacer sees the same set of models as ccusage.
///   - Per (date, model), input and cacheRead tokens match exactly.
///   - cacheCreation flat-sum (Pacer's 5m+1h) matches ccusage's flat
///     `cacheCreationTokens`.
@Test func perModelTotalsMatchCapturedCcusageSnapshot() async throws {
    guard capturedSnapshotTestsEnabled() else { return }
    guard let snapshotURL = locateCcusageSnapshot() else { return }
    let snapshot = try JSONDecoder().decode(
        CcusageSnapshot.self,
        from: try Data(contentsOf: snapshotURL)
    )

    let resolver = ClaudePathResolver()
    let roots: [ClaudePathResolver.ResolvedRoot]
    do { roots = try resolver.resolve() } catch { return }
    guard !roots.isEmpty else { return }

    let dmCollector = DateModelCollector()
    let scanner = JSONLScanner()
    _ = try await scanner.scan(roots: roots) { entry in
        await dmCollector.add(entry)
    }
    let pacerByDateModel = await dmCollector.byDateModel()

    let mostRecentDate = snapshot.daily.map(\.date).max() ?? ""
    var checkedModels = 0

    for ccu in snapshot.daily where ccu.date != mostRecentDate {
        guard let pacerDay = pacerByDateModel[ccu.date] else { continue }

        let ccuModelSet = Set(ccu.modelBreakdowns.map(\.modelName))
        let pacerModelSet = Set(pacerDay.keys)
        // Surface model-set divergence as an immediate failure — if
        // Pacer is missing a model ccusage saw, we have a parser bug
        // (or vice versa).
        #expect(
            ccuModelSet == pacerModelSet,
            "model set mismatch on \(ccu.date): pacer=\(pacerModelSet.sorted()) ccusage=\(ccuModelSet.sorted())"
        )

        for ccuModel in ccu.modelBreakdowns {
            guard let pacer = pacerDay[ccuModel.modelName] else { continue }
            checkedModels += 1
            #expect(
                pacer.inputTokens == ccuModel.inputTokens,
                "input mismatch on \(ccu.date) \(ccuModel.modelName): pacer=\(pacer.inputTokens) ccusage=\(ccuModel.inputTokens)"
            )
            #expect(
                pacer.cacheReadTokens == ccuModel.cacheReadTokens,
                "cacheRead mismatch on \(ccu.date) \(ccuModel.modelName): pacer=\(pacer.cacheReadTokens) ccusage=\(ccuModel.cacheReadTokens)"
            )
            let pacerCacheCreationFlat = pacer.cacheCreation5mTokens + pacer.cacheCreation1hTokens
            #expect(
                pacerCacheCreationFlat == ccuModel.cacheCreationTokens,
                "cacheCreation flat-sum mismatch on \(ccu.date) \(ccuModel.modelName): pacer=\(pacerCacheCreationFlat) ccusage=\(ccuModel.cacheCreationTokens)"
            )
        }
    }

    if !pacerByDateModel.isEmpty && !snapshot.daily.isEmpty {
        #expect(
            checkedModels > 0,
            "expected at least one (date, model) overlap with ccusage snapshot"
        )
    }
}
