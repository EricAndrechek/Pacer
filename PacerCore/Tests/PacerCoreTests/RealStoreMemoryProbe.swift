import Darwin
import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// What Pacer costs in memory, stage by stage, on a frozen COPY of a real store
/// (#389). Footprint alone hides half the answer here: the forecast networks are
/// memory maps, so their pages count as resident and never as footprint, and a
/// pass over one can push the rest of the machine out of RAM while the footprint
/// line stays flat. Every stage reports both, with the page-ins it caused.
///
///     sqlite3 "file:<live store>?mode=ro" ".backup '/tmp/mem/pacer.sqlite'"
///     MallocSpaceEfficient=1 PACER_ISOLATED_DEFAULTS=1 \
///     PACER_MEMORY_PROBE_STORE=/tmp/mem/pacer.sqlite \
///     swift test --filter RealStoreMemoryProbe
///
/// `MallocSpaceEfficient=1` matches the app (`LSEnvironment`, `MemoryHygiene`).
/// Optional:
///   - `PACER_MEMORY_PROBE_ACCOUNTS=<n>`: fit only the n accounts with the most
///     scoreboard rows, to read a smaller Mac off a big store.
///   - `PACER_MEMORY_PROBE_NETWORKS=1`: run one forecast per large network. Each
///     pages its whole file in, so leave it off on a Mac someone is working on
///     unless that is the point.
///   - `PACER_MEMORY_PROBE_LIVE=1`: attach the arena runtime and let one refit's
///     live round finish.
///   - `PACER_MEMORY_PROBE_CATALOG=<litellm-pricing.cache.json>`: price without
///     the network.
@Suite("Real-store memory probe", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["PACER_MEMORY_PROBE_STORE"] != nil))
struct RealStoreMemoryProbe {

    /// One reading of this process, every number a stage is judged on.
    struct Reading {
        var footprint: UInt64 = 0
        var resident: UInt64 = 0
        /// Resident pages backed by a file: the mapped networks, mostly.
        var external: UInt64 = 0
        var compressed: UInt64 = 0
        var pageins: UInt64 = 0
        var diskRead: UInt64 = 0
        var cpu: Double = 0
        var mallocLive: UInt64 = 0
        var mallocDirty: UInt64 = 0

        static func now() -> Reading {
            var r = Reading()
            var vm = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &vm) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            if result == KERN_SUCCESS {
                r.footprint = vm.phys_footprint
                r.resident = vm.resident_size
                r.external = vm.external
                r.compressed = vm.compressed
            }
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
                }
            } == 0
            if ok {
                r.pageins = info.ri_pageins
                r.diskRead = info.ri_diskio_bytesread
            }
            var ru = rusage()
            getrusage(RUSAGE_SELF, &ru)
            r.cpu = Double(ru.ru_utime.tv_sec + ru.ru_stime.tv_sec)
                + Double(ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) / 1e6
            let process = ProcessMemory.current()
            r.mallocLive = process.mallocLive
            r.mallocDirty = process.mallocDirty
            return r
        }
    }

    private static func mb(_ v: UInt64) -> Int { Int((Double(v) / 1_000_000).rounded()) }

    /// Runs `body`, then prints one row: what the stage took and what it left.
    /// Peak is sampled every 100 ms by the upgrade probe's `ResourceSampler`;
    /// the settled columns are read after a `MemoryHygiene.relieve`, so they say
    /// what stays rather than what has yet to be handed back.
    private func stage<T>(_ label: String, _ body: () async throws -> T) async rethrows -> T {
        let before = Reading.now()
        let sampler = ResourceSampler()
        sampler.start()
        let started = Date()
        let value = try await body()
        let wall = Date().timeIntervalSince(started)
        let usage = sampler.stop()
        MemoryHygiene.relieve()
        let after = Reading.now()
        let pageMB = (Double(after.pageins &- before.pageins) * Double(getpagesize())) / 1_000_000
        print(String(format: "MEM %-34@ wall %7.1fs cpu %7.1fs | fp %5d peak %5d Δfp %+5d | res %5d file %5d comp %5d | live %5d dirty %5d | pagein %6.0f read %6d",
                     label as NSString, wall, after.cpu - before.cpu,
                     Self.mb(after.footprint), Self.mb(usage.peakFootprint),
                     Self.mb(after.footprint) - Self.mb(before.footprint),
                     Self.mb(after.resident), Self.mb(after.external), Self.mb(after.compressed),
                     Self.mb(after.mallocLive), Self.mb(after.mallocDirty),
                     pageMB, Self.mb(after.diskRead &- before.diskRead)))
        return value
    }

    @Test func whatEachStageCosts() async throws {
        let env = ProcessInfo.processInfo.environment
        let storeURL = URL(fileURLWithPath: try #require(env["PACER_MEMORY_PROBE_STORE"]))
        if let live = try? PacerStore.storeURL() {
            let same = storeURL.resolvingSymlinksInPath().path == live.resolvingSymlinksInPath().path
            #expect(!same)
            guard !same else { return }
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        print("MEM columns in MB; malloc mode \(MemoryHygiene.allocatorMode); machine pressure \(MemoryPressure.kernelLevel().name)")

        _ = await stage("baseline") { }

        let container = try await stage("open store") { try PacerStore.makeModelContainer(at: storeURL) }

        let table = PricingTable()
        try await stage("pricing") {
            try await table.ensureLoaded(cacheURL: env["PACER_MEMORY_PROBE_CATALOG"].map(URL.init(fileURLWithPath:)))
            await SampleCostCache.reload(table, curatedCacheURL: URL(fileURLWithPath: "/nonexistent/price-history.json"))
        }

        // An empty config root: nothing is re-read, so this is what the
        // coordinator holds to stand ready (dedup index, cursors, persister),
        // which is the steady state. A home of its own, so nothing reads the
        // developer's login.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-mem-home-\(UUID().uuidString)")
        let claudeDir = home.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: claudeDir.appendingPathComponent("projects"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let coordinator = ScanCoordinator(
            container: container,
            configuration: .init(costMode: .auto, watcherMode: .manual, probeStatsCache: false),
            resolver: ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": claudeDir.path]),
            homeDirectory: home)
        _ = try await stage("scan: first cycle (preload)") { try await coordinator.runOnce() }
        _ = try await stage("scan: second cycle") { try await coordinator.runOnce() }

        // Every account's engine plus all-accounts, one at a time: what each
        // holds, and how far it scales with its share of the scoreboard.
        let accounts = await MainActor.run {
            ((try? ModelContext(container).fetch(FetchDescriptor<Account>())) ?? []).map(\.id)
        }
        let rowsByAccount = try Self.rowsByAccount(container, accounts: accounts)
        var chosen = rowsByAccount.sorted { $0.value > $1.value }.map(\.key)
        if let n = env["PACER_MEMORY_PROBE_ACCOUNTS"].flatMap(Int.init) { chosen = Array(chosen.prefix(n)) }
        print("MEM accounts: \(accounts.count), fitting \(chosen.count), scoreboard rows each: "
              + chosen.map { "\(rowsByAccount[$0] ?? 0)" }.joined(separator: ","))

        var engines: [UsageIntelligenceEngine] = []
        let scopes: [EngineScope] = [.allAccounts] + chosen.map { .account($0) }
        for (i, scope) in scopes.enumerated() {
            let engine = UsageIntelligenceEngine(modelContainer: container)
            await engine.adopt(scope: scope)
            let label = scope == .allAccounts ? "engine all: cold refit" : "engine \(i): cold refit"
            await stage(label) { await Self.refitOffMain(engine) }
            let rows = await engine.evalRowCountForProbe()
            print("MEM   \(label): \(rows) scoreboard rows held")
            engines.append(engine)
        }

        await stage("all engines: warm refit, together") { await Self.refitAll(engines) }
        await stage("all engines: warm refit, again") { await Self.refitAll(engines) }

        // What the pressure handler can get back (`shedRebuildableCaches`), and
        // what the next refit then pays to read it again.
        await stage("engines shed their caches") {
            for engine in engines { await engine.shedRebuildableCaches() }
        }
        await stage("all engines: refit after a shed") { await Self.refitAll(engines) }

        if env["PACER_MEMORY_PROBE_LIVE"] != nil {
            try await liveArena(container: container, engines: engines)
        }
        if env["PACER_MEMORY_PROBE_NETWORKS"] != nil {
            try await largeNetworks(container: container, account: try #require(chosen.first))
        }
        await stage("final: after relief") { }
    }

    /// The arena attached as the app attaches it, one live round per engine.
    private func liveArena(container: ModelContainer, engines: [UsageIntelligenceEngine]) async throws {
        let runtime = ArenaRuntime(container: container, ensureWeights: { _ in },
                                   onRecordLanded: { _, _ in }, onLiveLanded: { _ in })
        await stage("arena: runtime made, engines adopt") {
            for engine in engines { await engine.adopt(arena: runtime.link) }
        }
        await stage("arena: refit + first live round") {
            await Self.refitAll(engines)
            await runtime.live.settle()
        }
        await stage("arena: history and live round again") {
            await Self.refitAll(engines)
            await runtime.live.settle()
        }
        await runtime.stop()
        await stage("arena: stopped") { }
    }

    /// One forecast per large network on the account's real history, on a fresh
    /// runner each: whether anything loads the weights onto the heap, and what a
    /// pass does to resident memory and the disk.
    private func largeNetworks(container: ModelContainer, account: String) async throws {
        let cache = ArenaHistoryCache(container: container)
        let built = await stage("arena: history for one account") { await cache.built(account: account) }
        FMBackends.setBLASThreading(singleThreaded: true)
        let meter = built.store.meters.values.compactMap { $0.last?.tEvent }.max() ?? ArenaCut.millis(Date())
        let cut = ArenaHistory(store: built.store, now: meter, accounts: [account])
        let heavy = ArenaRegistry.all.filter { spec in
            spec.weights.contains { !FMWeights.bundled.contains($0) } && spec.name.hasSuffix("meter")
        }
        var seen = Set<String>()
        for spec in heavy where seen.insert(spec.weights.joined()).inserted {
            let runner = ArenaRunner(registry: ArenaRegistry.all,
                                     services: ArenaServices(weights: ArenaRuntime.defaultWeights))
            for target in [ArenaTarget.meterFiveHour, .meterSevenDay] {
                let request = ArenaRunner.request(history: cut, targets: [target])
                guard !request.targets.isEmpty else { continue }
                await stage("network \(spec.name) \(target == .meterFiveHour ? "5h" : "7d")") {
                    _ = try? runner.forecast(model: spec.name, history: cut, request: request)
                }
            }
            await stage("network \(spec.name) released") { FMScratch.release() }
        }
    }

    /// Off the main actor, as the app's refit is: an `await` from `@MainActor`
    /// resumes the fit inline on the main thread.
    private static func refitOffMain(_ engine: UsageIntelligenceEngine) async {
        await Task.detached(priority: .utility) { await engine.recompute() }.value
    }

    private static func refitAll(_ engines: [UsageIntelligenceEngine]) async {
        await Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                for engine in engines { group.addTask { await engine.recompute() } }
            }
        }.value
    }

    /// Rows of the scoreboard per account, read slim, so the choice of which
    /// accounts to fit leaves nothing resident behind it.
    private static func rowsByAccount(_ container: ModelContainer, accounts: [String]) throws -> [String: Int] {
        let context = ModelContext(container)
        var out: [String: Int] = [:]
        for account in accounts {
            let suffix = EngineScope.account(account).suffix
            out[account] = try context.fetchCount(FetchDescriptor<EngineEvalOutcome>(
                predicate: #Predicate { $0.surface.contains(suffix) }))
        }
        return out
    }
}
