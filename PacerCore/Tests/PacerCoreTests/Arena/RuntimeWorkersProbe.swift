import CryptoKit
import Darwin
import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// What several workers really buy, on a copy of a real store: wall time, CPU
/// time, peak footprint and the rows, for a fixed set of cycles and models at a
/// given worker count. One run per process, so the peak is this run's.
///
///     sqlite3 "file:<store>?mode=ro" ".backup <copy>"
///     PACER_ARENA_WORKERS_STORE=<copy> PACER_ARENA_WORKERS=4 PACER_ARENA_WORKERS_SET=heavy \
///       PACER_ARENA_WEIGHTS=<ForecastWeights> swift test -c release -Xswiftc -enable-testing \
///       --filter RuntimeWorkersProbe
///
/// `PACER_ARENA_WORKERS_CYCLES` five-hour cycles and `…_WEEKS` weekly ones per
/// account, on the `PACER_ARENA_WORKERS_ACCOUNTS` accounts with the most
/// readings (or all), as of `PACER_ARENA_WORKERS_NOW` (seconds since 1970; an
/// account that has since lost a window is only graded on it as of before
/// then). `PACER_ARENA_WORKERS_CHURN=<seconds>` changes the worker
/// count on that period through a run, abandoning forecasts, as a speed-up
/// stopped or a pause would. `PACER_ARENA_WORKERS_OUT=<dir>` writes the rows,
/// which hold real data: delete them afterwards. Its hash goes to stdout either
/// way: same hash, same rows. Deletes the arena's rows from the copy it is given.
@Suite("Arena runtime: workers probe", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["PACER_ARENA_WORKERS_STORE"] != nil))
struct RuntimeWorkersProbe {
    static let env = ProcessInfo.processInfo.environment

    /// Cheap on this store (each ≤ 150 ms a forecast, `ArenaModelCosts`): the
    /// first phase of a pass.
    static let cheap: Set<String> = ["naive-flat", "g1-10-fable-analog", "g1-01-sonnet-calibrate123",
                                     "fm-timestral-5m-meter", "g2-06-opus-fmgate2", "g2-07-opus-pool",
                                     "g2-07-opus-limit", "g2-08-fable-burst", "g1-10-fable-mix",
                                     "fm-timestral-28m-meter", "spend-decay-1h"]

    /// Which models a set means. `heavy`: everything else that can be picked,
    /// `sample`: one of each family of heavy model (a calibration layer over a
    /// network, over an analog, over spend; an ensemble; a bare big network; a
    /// structural network; the GBM), about a third of the phase's cost, so a
    /// run with enough cycles to feed eight workers fits in minutes.
    static func models(_ set: String) -> Set<String>? {
        switch set {
        case "cheap": return cheap
        case "heavy": return ArenaRoster.standard.selectableIds.subtracting(cheap)
        case "sample": return ["calib-fm-timestral-5m-meter", "calib-g1-10-fable-analog", "calib-spend-decay-30m",
                               "g1-05-opus-ens-meter-big", "struct-timestral-123m", "fm-timesfm25-meter",
                               "ml-gbm-quantile", "g1-08-opus-fm"]
        default: return nil
        }
    }

    static func processCPU() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) * 1e-6
    }

    static func hex(_ v: Double?) -> String { v.map { String($0.bitPattern, radix: 16) } ?? "-" }

    /// What this process has read, and what it has paged in: a network's
    /// weights are memory maps, so footprint alone says nothing of them.
    static func io() -> (bytesRead: UInt64, pageins: UInt64) {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return rc == 0 ? (info.ri_diskio_bytesread, info.ri_pageins) : (0, 0)
    }

    /// The kernel's own high-water marks, MB: resident in all, file-backed
    /// (mapped weights, shared by every thread) and compressed.
    static func peaks() -> (resident: Double, fileBacked: Double, compressed: Double) {
        var vm = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let rc = withUnsafeMutablePointer(to: &vm) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard rc == KERN_SUCCESS else { return (0, 0, 0) }
        return (Double(vm.resident_size_peak) / 1e6, Double(vm.external_peak) / 1e6, Double(vm.compressed_peak) / 1e6)
    }

    @Test func aFixedSetOfCyclesAtOneWorkerCount() async throws {
        let url = URL(fileURLWithPath: Self.env["PACER_ARENA_WORKERS_STORE"]!)
        let workers = Int(Self.env["PACER_ARENA_WORKERS"] ?? "") ?? 1
        let set = Self.env["PACER_ARENA_WORKERS_SET"] ?? "cheap"
        let label = Self.env["PACER_ARENA_WORKERS_LABEL"] ?? "\(set)-\(workers)"
        let container = try PacerStore.makeModelContainer(at: url)
        let setup = ModelContext(container)
        let accounts = try setup.fetch(FetchDescriptor<Account>()).map(\.id)
        var readings: [String: Int] = [:]
        for a in accounts {
            readings[a] = try setup.fetchCount(FetchDescriptor<RateLimitSample>(predicate: #Predicate { $0.accountId == a }))
        }
        let chosen = Array(readings.sorted { $0.value > $1.value }.map(\.key)
            .prefix(Int(Self.env["PACER_ARENA_WORKERS_ACCOUNTS"] ?? "") ?? 1))
        if Self.env["PACER_ARENA_WORKERS_KEEP_ROWS"] != "1" {
            try setup.delete(model: EngineEvalOutcome.self, where: #Predicate { !$0.surface.contains("eod") })
            try setup.save()
        }

        var config = ArenaRecordScorer.Config()
        config.dutyCycle = 1
        config.adaptiveBudget = false
        config.sessionCycleCap = Int(Self.env["PACER_ARENA_WORKERS_CYCLES"] ?? "") ?? 16
        config.weeklyCycleCap = Int(Self.env["PACER_ARENA_WORKERS_WEEKS"] ?? "") ?? 4
        if let m = Int(Self.env["PACER_ARENA_WORKERS_MEMO"] ?? "") { config.memoLimitValues = m }
        // Everything inside the depth is due: a fixed set, whatever the store
        // held, not a fingerprint's idea of what changed since.
        let costs = ArenaModelCosts(defaults: nil)
        let roster = ArenaRoster(registry: ArenaRegistry.all, only: Self.models(set))
        let rt = ArenaRuntime(container: container, roster: roster, weights: RuntimeRegistryProbe.weights(),
                              ensureWeights: { _ in }, config: config, costs: costs,
                              progress: ArenaScoringProgressBoard(), speedUp: ArenaSpeedUp(), maxWorkers: workers,
                              pressure: MemoryPressure(), onRecordLanded: { _, _ in },
                              onLiveLanded: { _ in })
        rt.budget.rate = Double(workers)
        rt.budget.scorerWorkers = workers
        // What a speed-up runs at. The default, background, keeps every worker
        // on the efficiency cores. `PACER_ARENA_WORKERS_QOS=userInitiated`: on a
        // Mac whose other work leaves utility threads little, what the code
        // itself can do, apart from what is left over for it.
        rt.budget.scorerQoS = Self.env["PACER_ARENA_WORKERS_QOS"] == "userInitiated" ? QOS_CLASS_USER_INITIATED : QOS_CLASS_UTILITY

        let churn = Double(Self.env["PACER_ARENA_WORKERS_CHURN"] ?? "") ?? 0
        let churning = Task.detached {
            guard churn > 0 else { return }
            let plan = [1, workers, 0, max(1, workers / 2), workers]
            var i = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(churn))
                rt.budget.scorerWorkers = plan[i % plan.count]
                i += 1
            }
        }

        let cpu0 = Self.processCPU(), clock = ContinuousClock(), t0 = clock.now, io0 = Self.io()
        let peak0 = ProcessMemory.current().peakFootprint
        let now = Double(Self.env["PACER_ARENA_WORKERS_NOW"] ?? "").map(Date.init(timeIntervalSince1970:)) ?? Date()
        let r = await rt.scorer.pass(accounts: chosen, now: now)
        let wall = RuntimePerfProbe.seconds(clock.now - t0)
        churning.cancel()
        let cpu = Self.processCPU() - cpu0
        let mem = ProcessMemory.current()
        let io1 = Self.io(), peaks = Self.peaks()
        let memo = rt.scorer.memo

        // The rows, every field a grade has but when it was written.
        var lines: [String] = []
        let rows = try ModelContext(container).fetch(FetchDescriptor<EngineEvalOutcome>(
            predicate: #Predicate { !$0.surface.contains("eod") }))
        for o in rows where Self.models(set)?.contains(o.method) ?? true {
            lines.append([o.surface, o.method, o.bucket, o.periodKey, Self.hex(o.predicted), Self.hex(o.truth),
                          o.inputs ?? "-", Self.hex(o.reading)].joined(separator: "\t"))
        }
        lines.sort()
        let joined = lines.joined(separator: "\n")
        let hash = SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        if let out = Self.env["PACER_ARENA_WORKERS_OUT"] {
            try joined.write(toFile: "\(out)/rows-\(label).tsv", atomically: true, encoding: .utf8)
        }
        print(String(format: "[workers] %@ n=%d: %d cycles, %d forecasts, %d outcomes, %d declined; "
                     + "wall %.1f s (read %.1f s, %.1f CPU), grade %.1f s, process CPU %.1f s, forecast CPU %.1f s; "
                     + "peak %.0f MB (before %.0f MB), now %.0f MB; memo %d hits %d misses, cut cache %d hits %d made; "
                     + "budget slept %.1f s; rows %d hash %@", label, workers, r.cycles, r.forecasts, r.outcomes,
                     r.declined, wall, r.readSeconds, r.readCPUSeconds, wall - r.readSeconds, cpu,
                     r.modelCPUSeconds.values.reduce(0, +), Double(mem.peakFootprint) / 1e6, Double(peak0) / 1e6,
                     Double(mem.footprint) / 1e6, memo.hits, memo.misses, FMCalCutCache.shared.hits,
                     FMCalCutCache.shared.puts, rt.budget.totals.slept, lines.count, String(hash)))
        print(String(format: "[workers]   memory: resident peak %.0f MB, file-backed peak %.0f MB, compressed peak %.0f MB; "
                     + "read %.2f GB, page-ins %d (+%d pages), scratch largest %.0f MB",
                     peaks.resident, peaks.fileBacked, peaks.compressed, Double(io1.bytesRead - io0.bytesRead) / 1e9,
                     io1.pageins, io1.pageins - io0.pageins, Double(FMScratch.largestBytes) / 1e6))
        // A caught-up Mac's next pass, every 15 minutes (`Config.rescanInterval`).
        if Self.env["PACER_ARENA_WORKERS_AGAIN"] == "1" {
            let io2 = Self.io(), cpu2 = Self.processCPU(), t2 = clock.now
            let again = await rt.scorer.pass(accounts: chosen, now: now)
            let io3 = Self.io()
            print(String(format: "[workers]   the next pass: %.1f s, %.2f CPU s, %d forecasts, read %.3f GB, +%d page-ins",
                         RuntimePerfProbe.seconds(clock.now - t2), Self.processCPU() - cpu2, again.forecasts,
                         Double(io3.bytesRead - io2.bytesRead) / 1e9, io3.pageins - io2.pageins))
        }
        var windows: [String: Int] = [:]
        for l in lines { windows[String(l.prefix { $0 != "#" && $0 != "|" }), default: 0] += 1 }
        print("[workers]   rows by window: \(windows.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        for (id, s) in r.modelCPUSeconds.sorted(by: { $0.value > $1.value }).prefix(12) {
            print(String(format: "[workers]   %@: %.0f ms CPU/forecast over %d, %.0f s", id,
                         s * 1000 / Double(max(1, r.modelForecasts[id] ?? 1)), r.modelForecasts[id] ?? 0, s))
        }
    }
}
