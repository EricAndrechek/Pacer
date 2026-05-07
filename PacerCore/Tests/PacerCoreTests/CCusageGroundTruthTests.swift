import Foundation
import Testing
@testable import PacerCore

/// Ground-truth comparison: Pacer's parser must produce the same
/// per-day token totals as `bun x ccusage daily --json` did when the
/// snapshot at `docs/research/ccusage-outputs/daily.json` was captured.
///
/// **Key deviation that this test handles**: ccusage flattens
/// `cache_creation_input_tokens` into a single `cacheCreationTokens`
/// field; Pacer keeps the 5m/1h split (`cacheCreation5mTokens` +
/// `cacheCreation1hTokens`). The comparison sums Pacer's two columns
/// to recover ccusage's flat number — *that* match must be exact, the
/// split itself is the deliberate Pacer-better-than-ccusage extension
/// and isn't comparable. (See AGENTS.md "Non-negotiable correctness
/// rules" §5.)
///
/// **Skip semantics**: the test reads the user's real
/// `~/.claude/projects/` and the captured ccusage snapshot. Both must
/// be present locally; on a fresh checkout or a CI box without these
/// fixtures, the test silently returns. Validates correctness on the
/// developer's box without breaking elsewhere.
///
/// The captured snapshot is frozen in time. The user can keep using
/// Claude Code (adding new dates beyond the snapshot range) without
/// breaking this test — we only compare dates that appear in BOTH
/// sources. JSONL data for dates already past is immutable on disk
/// (sessions don't retroactively rewrite their own files), so per-day
/// totals for snapshot-covered dates are stable.

private struct CcusageDay: Decodable {
    let date: String
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheCreationTokens: Int64
    let cacheReadTokens: Int64
    let totalCost: Double
    let modelBreakdowns: [CcusageModelBreakdown]
}

private struct CcusageModelBreakdown: Decodable {
    let modelName: String
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheCreationTokens: Int64
    let cacheReadTokens: Int64
    let cost: Double
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
        .deletingLastPathComponent() // ccmac/
    let candidate = projectRoot.appendingPathComponent("docs/research/ccusage-outputs/daily.json")
    return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
}

@Test func scannerTotalsMatchCapturedCcusageSnapshot() async throws {
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
    _ = try await scanner.scan(roots: roots, mtimeAfter: nil) { entry in
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
            pacer.outputTokens == ccu.outputTokens,
            "output mismatch on \(date): pacer=\(pacer.outputTokens) ccusage=\(ccu.outputTokens)"
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
    _ = try await scanner.scan(roots: roots, mtimeAfter: nil) { entry in
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
        if differsBeyondTolerance(pacer.outputTokens, ccu.outputTokens) {
            divergentDays.append((ccu.date, "output pacer=\(pacer.outputTokens) ccu=\(ccu.outputTokens)"))
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

/// Per-day, per-model `CostCalculator` totals plus tracking of any
/// 1h-cache tokens (so divergences can be classified — see the cost
/// test's docstring for the cache-1h caveat).
private actor PerModelCostCollector {
    private var costs: [String: [String: Double]] = [:]  // date -> model -> cost
    private var oneHour: [String: [String: Int64]] = [:] // date -> model -> 1h tokens
    private let calculator: CostCalculator

    init(mode: CostMode = .auto) {
        self.calculator = CostCalculator(mode: mode)
    }

    func add(_ entry: ParsedUsageEntry) async {
        let date = TokenSample.formatDate(entry.timestamp)
        let cost = await calculator.cost(for: entry)
        var dayCosts = costs[date] ?? [:]
        dayCosts[entry.model, default: 0] += cost
        costs[date] = dayCosts
        var dayOneHour = oneHour[date] ?? [:]
        dayOneHour[entry.model, default: 0] += entry.breakdown.cacheCreation1hTokens
        oneHour[date] = dayOneHour
    }

    func costs(date: String, model: String) -> Double {
        costs[date]?[model] ?? 0
    }

    func has1hCache(date: String, model: String) -> Bool {
        (oneHour[date]?[model] ?? 0) > 0
    }
}

/// Like `DateCollector` but also runs `CostCalculator` per entry so
/// the total per-day cost can be compared against ccusage's
/// `totalCost` field. We accumulate cost during the scan rather than
/// after so we don't have to retain per-entry breakdowns; the
/// calculator runs in `.auto` mode (matches ccusage default).
private actor CostCollector {
    private var costByDate: [String: Double] = [:]
    private var oneHourCacheByDate: [String: Int64] = [:]
    private let calculator: CostCalculator

    init(mode: CostMode = .auto) {
        self.calculator = CostCalculator(mode: mode)
    }

    func add(_ entry: ParsedUsageEntry) async {
        let date = TokenSample.formatDate(entry.timestamp)
        let cost = await calculator.cost(for: entry)
        costByDate[date, default: 0] += cost
        oneHourCacheByDate[date, default: 0] += entry.breakdown.cacheCreation1hTokens
    }

    func byDate() -> [String: Double] { costByDate }
    func oneHourCache() -> [String: Int64] { oneHourCacheByDate }
}

/// End-to-end cost comparison: Pacer's per-day cost must match
/// ccusage's `totalCost` for the same range, modulo the legitimate
/// cache-creation-1h divergence. ccusage applies a single
/// `cacheCreationInputTokenCost` rate to all cache-creation tokens
/// (because it flattens 5m+1h into one bucket); Pacer applies the
/// 1h-specific rate when present in pricing data, so on a day with
/// 1h-cached tokens *Pacer is more accurate than ccusage*. We
/// surface that case as a soft divergence (logged, not failed) and
/// require exact match on days without 1h cache tokens.
@Test func dailyCostsMatchCapturedCcusageSnapshot() async throws {
    guard let snapshotURL = locateCcusageSnapshot() else { return }
    let snapshot = try JSONDecoder().decode(
        CcusageSnapshot.self,
        from: try Data(contentsOf: snapshotURL)
    )

    let resolver = ClaudePathResolver()
    let roots: [ClaudePathResolver.ResolvedRoot]
    do { roots = try resolver.resolve() } catch { return }
    guard !roots.isEmpty else { return }

    let collector = CostCollector(mode: .auto)
    let scanner = JSONLScanner()
    _ = try await scanner.scan(roots: roots, mtimeAfter: nil) { entry in
        await collector.add(entry)
    }
    let pacerCostByDate = await collector.byDate()
    let oneHourCacheByDate = await collector.oneHourCache()

    let mostRecentDate = snapshot.daily.map(\.date).max() ?? ""
    var checkedStrict = 0
    var divergencesOn1hDays: [String] = []

    for ccu in snapshot.daily where ccu.date != mostRecentDate {
        guard let pacerCost = pacerCostByDate[ccu.date] else { continue }
        let absDiff = abs(pacerCost - ccu.totalCost)
        let larger = max(abs(pacerCost), abs(ccu.totalCost))
        let relDiff = larger > 0 ? absDiff / larger : 0
        let has1hCache = (oneHourCacheByDate[ccu.date] ?? 0) > 0

        if has1hCache {
            // Legitimate divergence on this day — log only.
            if relDiff > 0.001 {
                divergencesOn1hDays.append(
                    "\(ccu.date): pacer=$\(String(format: "%.4f", pacerCost)) ccu=$\(String(format: "%.4f", ccu.totalCost)) (1h-cache divergence)"
                )
            }
        } else {
            // Strict match. Float tolerance: $0.001 absolute or 0.01% relative.
            checkedStrict += 1
            let withinTolerance = absDiff < 0.001 || relDiff < 0.0001
            #expect(
                withinTolerance,
                "cost mismatch on \(ccu.date): pacer=$\(pacerCost) ccusage=$\(ccu.totalCost) diff=$\(absDiff) rel=\(relDiff)"
            )
        }
    }

    // Don't fail on no-overlap (test scaffolds skip silently); but if
    // we found overlap, at least some strict comparisons should have
    // happened — otherwise the test passed for the wrong reason.
    if !pacerCostByDate.isEmpty && !snapshot.daily.isEmpty {
        #expect(
            checkedStrict > 0 || !divergencesOn1hDays.isEmpty,
            "expected at least one cost-comparable overlapping date"
        )
    }
    if !divergencesOn1hDays.isEmpty {
        // Surface but don't fail — these are the "Pacer is more correct"
        // wins where the captured snapshot is from ccusage's
        // less-accurate flat cache rate.
        FileHandle.standardError.write(
            Data("\n[CCusageGroundTruth] cache-1h cost divergences (Pacer more accurate):\n  - \(divergencesOn1hDays.joined(separator: "\n  - "))\n\n".utf8)
        )
    }
}

/// Per-model breakdown ground truth. For each completed day in the
/// captured snapshot, verify that:
///   - Pacer sees the same set of models as ccusage.
///   - Per (date, model), input/output/cacheRead tokens match exactly.
///   - cacheCreation flat-sum (Pacer's 5m+1h) matches ccusage's flat
///     `cacheCreationTokens`.
///   - Per-model cost matches strictly when the model has no 1h cache
///     tokens that day; logged-only divergence otherwise (see the
///     daily-cost test for the rationale).
@Test func perModelTotalsMatchCapturedCcusageSnapshot() async throws {
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
    let costCollector = PerModelCostCollector(mode: .auto)
    let scanner = JSONLScanner()
    _ = try await scanner.scan(roots: roots, mtimeAfter: nil) { entry in
        await dmCollector.add(entry)
        await costCollector.add(entry)
    }
    let pacerByDateModel = await dmCollector.byDateModel()

    let mostRecentDate = snapshot.daily.map(\.date).max() ?? ""
    var costDivergencesOn1hDays: [String] = []
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
                pacer.outputTokens == ccuModel.outputTokens,
                "output mismatch on \(ccu.date) \(ccuModel.modelName): pacer=\(pacer.outputTokens) ccusage=\(ccuModel.outputTokens)"
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

            // Per-model cost comparison with the same 1h-cache caveat
            // as the day-level cost test.
            let pacerCost = await costCollector.costs(date: ccu.date, model: ccuModel.modelName)
            let has1h = await costCollector.has1hCache(date: ccu.date, model: ccuModel.modelName)
            let absDiff = abs(pacerCost - ccuModel.cost)
            let larger = max(abs(pacerCost), abs(ccuModel.cost))
            let relDiff = larger > 0 ? absDiff / larger : 0
            if has1h {
                if relDiff > 0.001 {
                    costDivergencesOn1hDays.append(
                        "\(ccu.date)/\(ccuModel.modelName): pacer=$\(String(format: "%.4f", pacerCost)) ccu=$\(String(format: "%.4f", ccuModel.cost))"
                    )
                }
            } else {
                let withinTolerance = absDiff < 0.001 || relDiff < 0.0001
                #expect(
                    withinTolerance,
                    "per-model cost mismatch on \(ccu.date) \(ccuModel.modelName): pacer=$\(pacerCost) ccusage=$\(ccuModel.cost) diff=$\(absDiff)"
                )
            }
        }
    }

    if !pacerByDateModel.isEmpty && !snapshot.daily.isEmpty {
        #expect(
            checkedModels > 0,
            "expected at least one (date, model) overlap with ccusage snapshot"
        )
    }
}
