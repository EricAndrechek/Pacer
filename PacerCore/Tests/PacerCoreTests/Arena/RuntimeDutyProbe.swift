import Darwin
import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// What the runtime costs the rest of the app, measured: the CPU a scorer
/// pass takes against its budget (process CPU time over wall time, the number
/// Activity Monitor shows), and how long the store's other readers and
/// writers wait while a history is read through SwiftData or raw SQLite. Off
/// by default; `PACER_ARENA_DUTY=1 swift test --filter RuntimeDutyProbe`
/// prints the numbers. Synthetic data only, in a temporary file store (the
/// raw reads need a file).
@Suite("Arena runtime: duty and contention probe", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["PACER_ARENA_DUTY"] == "1"))
struct RuntimeDutyProbe {

    static let account = RuntimePerfProbe.account

    /// `RuntimePerfProbe.heavyStore`'s account, written to a file.
    static func fileStore(days: Int, now: Date) throws -> (ModelContainer, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("arena-duty-\(UUID()).sqlite")
        let container = try PacerStore.makeModelContainer(at: url)
        let source = try RuntimePerfProbe.heavyStore(days: days, now: now)
        let from = ModelContext(source), to = ModelContext(container)
        to.insert(Account(id: account, organizationId: account, displayName: "Perf", isActive: true,
                          firstSeenAt: now.addingTimeInterval(-Double(days) * 86400), lastSeenAt: now))
        for r in try from.fetch(FetchDescriptor<RateLimitSample>()) {
            to.insert(RateLimitSample(sampledAt: r.sampledAt, window: r.window, usedPercentage: r.usedPercentage,
                                      resetsAt: r.resetsAt, source: r.source, accountId: r.accountId))
        }
        // Five turns for each of the generator's, seconds apart: a heavy
        // account's ~1,000 turns a day.
        for s in try from.fetch(FetchDescriptor<TokenSample>()) {
            for k in 0..<5 {
                let at = s.sampledAt.addingTimeInterval(Double(k) * 7)
                let c = TokenSample(sampledAt: at, date: s.date, model: s.model, inputTokens: s.inputTokens,
                                    outputTokens: s.outputTokens, cacheReadTokens: s.cacheReadTokens,
                                    cacheCreation5mTokens: s.cacheCreation5mTokens,
                                    cacheCreation1hTokens: s.cacheCreation1hTokens)
                c.accountId = s.accountId
                to.insert(c)
            }
        }
        try to.save()
        return (container, url)
    }

    static func processCPU() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) * 1e-6
    }

    static func percentile(_ xs: [Double], _ p: Double) -> Double {
        guard !xs.isEmpty else { return .nan }
        let s = xs.sorted()
        return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
    }

    /// The store's other users while a history is read: a small fetch and a
    /// small save every 20 ms on contexts of their own (the scan's and the
    /// views' shape), timed.
    static func contention(_ container: ModelContainer, during work: @escaping @Sendable () -> Void)
        -> (wall: Double, p50: Double, p99: Double, max: Double) {
        let done = ArenaCancelFlag()
        let started = Date()
        let worker = Thread {
            work()
            done.set(true)
        }
        worker.qualityOfService = .background
        worker.start()
        var latencies: [Double] = []
        var i = 0
        while !done.isSet {
            let t = Date()
            let ctx = ModelContext(container)
            var d = FetchDescriptor<RateLimitSample>(sortBy: [SortDescriptor(\.sampledAt, order: .reverse)])
            d.fetchLimit = 1
            _ = try? ctx.fetch(d)
            ctx.insert(EngineEvalOutcome(surface: "probe", method: "probe", bucket: "b", periodKey: "p\(i)",
                                         predicted: 1, truth: 1, recordedAt: Date()))
            try? ctx.save()
            latencies.append(Date().timeIntervalSince(t) * 1000)
            i += 1
            usleep(20_000)
        }
        return (Date().timeIntervalSince(started), percentile(latencies, 0.5), percentile(latencies, 0.99),
                latencies.max() ?? .nan)
    }

    @Test func historyReadsAndTheirNeighbours() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let (container, url) = try Self.fileStore(days: 120, now: now)
        defer { for x in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + x) } }
        let pricing = PricingTable.Snapshot(pricingByModel: RuntimeHistoryBuilderTests.catalog)
        let after = now.addingTimeInterval(-120 * 86400)
        let account = Self.account
        let idle = Self.contention(container) { usleep(3_000_000) }
        let viaSwiftData = Self.contention(container) {
            _ = ArenaHistoryBuilder.readSpendThroughSwiftData(container: container, account: account, after: after,
                                                              through: now, pricing: pricing, mode: .calculate)
        }
        let raw = Self.contention(container) {
            _ = ArenaHistoryBuilder.readSpend(container: container, account: account, after: after, through: now,
                                              pricing: pricing, mode: .calculate)
        }
        for (name, r) in [("idle", idle), ("swiftdata", viaSwiftData), ("raw", raw)] {
            print("[duty] neighbours during \(name) read: read took \(String(format: "%.1f", r.wall)) s; "
                  + "fetch+save p50 \(String(format: "%.1f", r.p50)) ms, p99 \(String(format: "%.1f", r.p99)) ms, "
                  + "max \(String(format: "%.1f", r.max)) ms")
        }
        let turns = try ModelContext(container).fetchCount(FetchDescriptor<TokenSample>())
        print("[duty] store: \(turns) turns over 120 days")
    }

    /// A pass at a quarter of a core, cancelled after `seconds`: the process
    /// CPU it used over that wall time.
    static func pass(_ container: ModelContainer, now: Date, duty: Double, seconds: Double) async -> Double {
        var config = ArenaRecordScorer.Config()
        config.dutyCycle = duty
        // The models that need no downloaded weights: the arithmetic ports
        // and the bundled-size networks are what a first pass starts on.
        let registry = ArenaRegistry.all.filter { ArenaRunner(registry: ArenaRegistry.all).requiredWeights($0.name).isEmpty }
        let rt = ArenaRuntime(container: container, roster: ArenaRoster(registry: registry),
                              weights: { _ in nil }, ensureWeights: { _ in }, config: config,
                              onRecordLanded: { _, _ in }, onLiveLanded: { _ in })
        FMBackends.setBLASThreading(singleThreaded: true)
        let cpu0 = processCPU(), t0 = Date()
        let task = Task.detached { await rt.scorer.pass(accounts: [Self.account], now: now) }
        try? await Task.sleep(for: .seconds(seconds))
        await rt.stop()
        let report = await task.value
        let wall = Date().timeIntervalSince(t0), cpu = processCPU() - cpu0
        let totals = rt.budget.totals
        print("[duty] pass at \(Int(duty * 100))%: \(String(format: "%.0f", wall)) s wall, "
              + "process cpu \(String(format: "%.1f", cpu)) s = \(String(format: "%.0f", 100 * cpu / wall))% of a core; "
              + "budget charged \(String(format: "%.1f", totals.spent)) s, slept \(String(format: "%.1f", totals.slept)) s; "
              + "\(report.forecasts) forecasts, \(report.outcomes) outcomes")
        return cpu / wall
    }

    @Test func aPassStaysInsideItsBudget() async throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let (container, url) = try Self.fileStore(days: 120, now: now)
        defer { for x in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + x) } }
        let unbounded = await Self.pass(container, now: now, duty: 4, seconds: 20)
        let quarter = await Self.pass(container, now: now, duty: 0.25, seconds: 60)
        #expect(quarter < 0.35)
        #expect(unbounded > quarter)
    }
}
