import Darwin
import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// Runs ONE of the persister's writing walks on a frozen COPY of a real store
/// and measures it (#338, AGENTS.md rule 8): peak footprint and wall time
/// while the walk and its save run, then a digest of every resulting sample,
/// the walk's return value and the buckets it marked. Run it once per walk
/// per build, each on a fresh copy, and compare the two builds' outputs:
///
///     sqlite3 "<store>" ".backup '/tmp/walks/pristine.sqlite'"
///     cp -c /tmp/walks/pristine.sqlite /tmp/walks/old.sqlite
///     PACER_WALK_PROBE_STORE=/tmp/walks/old.sqlite PACER_WALK_PROBE_WALK=repair \
///     PACER_WALK_PROBE_OUT=/tmp/walks/out/old-repair.txt \
///     PACER_ISOLATED_DEFAULTS=1 swift test --filter RealStoreWalkProbe
///
/// Walks: `upgrade` (every 40th keyed row gets a finished copy with one more
/// output token, so `flush()` takes the bulk branch), `repair`, `canonicalize`
/// (with the copy's own aliases) and `stamp` (`markEverySampleDirty`). A real
/// store has nothing for the last three to do, so prepare the copy with
/// `sqlite3` first, once, and clone it for each build:
///
///     -- stamp: every row predates the stored hour
///     UPDATE ZTOKENSAMPLE SET ZLOCALHOUR = -1;
///     -- canonicalize: every row as a build before `originalProjectPath`
///     UPDATE ZTOKENSAMPLE SET ZPROJECTPATH = ZORIGINALPROJECTPATH, ZORIGINALPROJECTPATH = NULL;
///     -- repair: a second copy of every 50th row — identical, partial,
///     -- finished, or the same output stamped earlier
///     CREATE TEMP TABLE d AS SELECT * FROM ZTOKENSAMPLE WHERE Z_PK % 50 = 0;
///     UPDATE d SET ZOUTPUTTOKENS = MAX(ZOUTPUTTOKENS - 1, 0) WHERE Z_PK % 150 = 50;
///     UPDATE d SET ZOUTPUTTOKENS = ZOUTPUTTOKENS + 5 WHERE Z_PK % 150 = 100;
///     UPDATE d SET ZSAMPLEDAT = ZSAMPLEDAT - 60 WHERE Z_PK % 300 = 0;
///     UPDATE d SET Z_PK = Z_PK + (SELECT MAX(Z_PK) FROM ZTOKENSAMPLE);
///     INSERT INTO ZTOKENSAMPLE SELECT * FROM d;
///     UPDATE Z_PRIMARYKEY SET Z_MAX = (SELECT MAX(Z_PK) FROM ZTOKENSAMPLE)
///         WHERE Z_NAME = 'TokenSample';
///
/// Uses only API the pre-#338 tree has, so the same file measures both builds.
@Suite("Real-store walk probe",
       .enabled(if: ProcessInfo.processInfo.environment["PACER_WALK_PROBE_STORE"] != nil))
struct RealStoreWalkProbe {

    func log(_ s: String) {
        print("\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) [walk] \(s)")
    }

    @ScanActor
    @Test func runOneWalkOnACopy() throws {
        let env = ProcessInfo.processInfo.environment
        let storeURL = URL(fileURLWithPath: try #require(env["PACER_WALK_PROBE_STORE"]))
        let walk = try #require(env["PACER_WALK_PROBE_WALK"])
        if let live = try? PacerStore.storeURL() {
            let same = storeURL.resolvingSymlinksInPath().path == live.resolvingSymlinksInPath().path
            #expect(!same)
            guard !same else { return }
        }
        let container = try PacerStore.makeModelContainer(at: storeURL)
        let context = ModelContext(container)
        let persister = try SamplePersister(context: context)

        // Inputs, built before the measured window.
        var entries: [ParsedUsageEntry] = []
        var aliases: [String: String] = [:]
        switch walk {
        case "upgrade":
            try persister.ensurePreloaded()
            var n = 0
            try ModelWalk.forEach(FetchDescriptor<TokenSample>(), in: container) { s in
                defer { n += 1 }
                guard n % 40 == 0, let key = s.dedupKey else { return }
                entries.append(ParsedUsageEntry(
                    timestamp: s.sampledAt, model: s.model,
                    breakdown: TokenBreakdown(inputTokens: s.inputTokens, outputTokens: s.outputTokens + 1,
                                              cacheReadTokens: s.cacheReadTokens,
                                              cacheCreation5mTokens: s.cacheCreation5mTokens,
                                              cacheCreation1hTokens: s.cacheCreation1hTokens),
                    storedCostUSD: s.sourceCostUSD, dedupKey: key, sessionId: s.sessionId,
                    projectPath: s.projectPath, isComplete: true,
                    speed: s.speed, inferenceGeo: s.inferenceGeo))
            }
            log("upgrade: \(entries.count) finished copies of \(n) rows")
        case "canonicalize":
            for row in try context.fetch(FetchDescriptor<ProjectPathAlias>()) {
                aliases[row.sourcePath] = row.canonicalPath
            }
            log("canonicalize: \(aliases.count) alias(es)")
        case "repair", "stamp":
            break
        default:
            Issue.record("unknown walk \(walk)")
            return
        }
        let before = ProcessMemory.current()
        log("memory before: \(before.summary)")

        let sampler = ResourceSampler()
        sampler.start()
        let started = Date()
        var result = -1
        switch walk {
        case "upgrade":
            for e in entries { try persister.insert(e) }
            try persister.flush()
            result = persister.stats.upgradedFromPartial
        case "repair":
            result = try persister.repairDuplicateSamples()
        case "canonicalize":
            result = try persister.canonicalizeProjectPaths(aliases: aliases)
        default:
            try persister.markEverySampleDirty()
        }
        try context.save()
        let wall = Date().timeIntervalSince(started)
        let usage = sampler.stop()
        log(String(format: "%@: result %d · %.1f s wall · peak footprint %.0f MB (+%.0f MB over the %.0f MB before) at +%.1f s",
                   walk, result, wall, Double(usage.peakFootprint) / 1e6,
                   (Double(usage.peakFootprint) - Double(before.footprint)) / 1e6,
                   Double(before.footprint) / 1e6, usage.peakFootprintAt))

        // What the walk left: every sample, the marks, the counts.
        let digest = try Self.sampleDigest(container)
        func setDigest<S: Sequence>(_ name: String, _ s: S, _ f: (S.Element) -> String) -> String {
            let lines = s.map(f).sorted()
            return "\(name)\t\(lines.count)\t\(String(Self.fnv1a(lines.joined(separator: "\n")), radix: 16))"
        }
        let pollution = persister.stats.sessionPollution.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        let lines = [
            "walk\t\(walk)",
            "result\t\(result)",
            "rows\t\(digest.rows)",
            "samples\t\(digest.digest)",
            setDigest("dirtyPairs", persister.dirtyPairs) { "\($0.date)|\($0.model)" },
            setDigest("pollutedDailyPairs", persister.pollutedDailyPairs) { "\($0.date)|\($0.model)" },
            setDigest("dirtyHourBuckets", persister.dirtyHourBuckets) { "\($0.date)|\($0.hour)|\($0.model)" },
            setDigest("pollutedHourBuckets", persister.pollutedHourBuckets) { "\($0.date)|\($0.hour)|\($0.model)" },
            setDigest("dirtyProjectDates", persister.dirtyProjectDates) { "\($0.projectPath)|\($0.date)" },
            setDigest("pollutedProjectPairs", persister.pollutedProjectPairs) { "\($0.projectPath)|\($0.date)" },
            setDigest("dirtySessionIds", persister.dirtySessionIds) { $0 },
            setDigest("pollutedSessionIds", persister.pollutedSessionIds) { $0 },
            setDigest("sessionUpgrades", persister.pendingSessionUpgrades.flatMap { sid, us in
                us.map { "\(sid)|\($0.old.breakdown)|\($0.new.dedupKey ?? "-")|\($0.new.outputTokens)" }
            }) { $0 },
            "pollution\t\(pollution)",
        ]
        let timing = String(format: "measure\twall_s=%.2f\tpeak_mb=%.0f\tbefore_mb=%.0f",
                            wall, Double(usage.peakFootprint) / 1e6, Double(before.footprint) / 1e6)
        for l in lines { log(l) }
        log(timing)
        if let out = env["PACER_WALK_PROBE_OUT"] {
            try (lines.joined(separator: "\n") + "\n").write(
                toFile: out, atomically: true, encoding: .utf8)
            try (timing + "\n").write(toFile: out + ".timing", atomically: true, encoding: .utf8)
        }
    }

    /// Order-independent digest of every sample's stored fields, paged so it
    /// costs this process nothing that lingers.
    @ScanActor
    static func sampleDigest(_ container: ModelContainer) throws -> (rows: Int, digest: String) {
        var rows = 0
        var sum: UInt64 = 0, mix: UInt64 = 0
        try ModelWalk.forEach(FetchDescriptor<TokenSample>(), in: container) { s in
            rows += 1
            let stamp: String = String(s.sampledAt.timeIntervalSince1970.bitPattern, radix: 16)
            let cost: String = s.sourceCostUSD.map { String($0.bitPattern, radix: 16) } ?? "-"
            var parts: [String] = [s.dedupKey ?? "-", stamp, s.date, s.model, String(s.localHour)]
            parts += [String(s.inputTokens), String(s.outputTokens), String(s.cacheReadTokens)]
            parts += [String(s.cacheCreation5mTokens), String(s.cacheCreation1hTokens), cost]
            parts += [s.sessionId ?? "-", s.projectPath ?? "-", s.originalProjectPath ?? "-"]
            parts += [s.ccVersion ?? "-", s.accountId ?? "-", s.speed ?? "-", s.inferenceGeo ?? "-"]
            let h = fnv1a(parts.joined(separator: "\u{1F}"))
            sum &+= h
            mix ^= h &* 0x9E37_79B9_7F4A_7C15
        }
        return (rows, String(format: "%016llx%016llx", sum, mix))
    }

    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return h
    }
}
