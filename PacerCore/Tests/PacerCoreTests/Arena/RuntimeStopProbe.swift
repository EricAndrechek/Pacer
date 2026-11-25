import Darwin
import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// How long a stop takes on this Mac as it is now, with the scorer's workers
/// at the classes the app runs them at and nothing standing in for the
/// starving (#446): a pass of busy workers, stopped as a quit stops it, then
/// stopped the way it was before (no raise). Opt-in, because what it measures
/// is the machine; run it while the Mac is loaded:
///
///     PACER_STOP_PROBE=1 PACER_PRODUCTION_QOS=1 PACER_ISOLATED_DEFAULTS=1 \
///       swift test --filter RuntimeStopProbe
///
/// `PACER_STOP_PROBE_WORKERS` sets the worker count (4).
/// `PACER_STOP_PROBE_STARVE=1` makes the starving rather than waiting for it:
/// a utility thread spinning on every core while each stop is measured (at
/// most 15 s a stop), which on Apple silicon leaves background threads no
/// core at all. One line per stop to stdout: the load average, how long it
/// took and whether it wound down.
@Suite("Arena runtime: stop probe", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["PACER_STOP_PROBE"] != nil))
struct RuntimeStopProbe {
    typealias Fixtures = RuntimeEngineTests

    /// About 100 ms of CPU a forecast, checking for a stop every millisecond
    /// or so, as a real model's loops do.
    final class Spinner: ArenaModel {
        let ctx: ArenaContext
        let inner: Fixtures.Peeker
        init(context: ArenaContext) { ctx = context; inner = Fixtures.Peeker(context: context) }
        func fit(_ history: ArenaHistory) { inner.fit(history) }
        func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
            var x = 0.0
            for i in 0..<100 {
                let until = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) + 1_000_000
                while clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) < until { x += Double(i).squareRoot() }
                try ctx.checkCancelled()
            }
            precondition(x.isFinite)
            return try inner.forecast(request)
        }
    }

    static let spinner = ArenaModelSpec(name: "test-spinner", targets: Fixtures.meters, complexity: 2) {
        Spinner(context: $0)
    }

    /// A utility thread spinning on every core until stopped.
    final class Starver: @unchecked Sendable {
        private let stopFlag = ArenaCancelFlag()
        init(threads: Int) {
            for _ in 0..<threads {
                let t = Thread { [stopFlag] in
                    var x = 0.0
                    while !stopFlag.isSet { for i in 0..<10_000 { x += Double(i).squareRoot() } }
                    precondition(x.isFinite)
                }
                t.qualityOfService = .utility
                t.start()
            }
        }
        func stop() { stopFlag.set(true) }
    }

    static func load() -> String {
        var avg = [Double](repeating: 0, count: 3)
        return getloadavg(&avg, 3) == 3 ? String(format: "%.0f/%.0f/%.0f", avg[0], avg[1], avg[2]) : "?"
    }

    @Test func aStopOnThisMacNow() async throws {
        let workers = Int(ProcessInfo.processInfo.environment["PACER_STOP_PROBE_WORKERS"] ?? "") ?? 4
        print("stop probe: background floor \(BackgroundQoS.applied(QOS_CLASS_BACKGROUND) == QOS_CLASS_BACKGROUND ? "background" : "utility"), \(workers) worker(s), \(ProcessInfo.processInfo.activeProcessorCount) cores")
        for raise in [true, false] {
            let container = try Fixtures.seeded(cycles: 12)
            var config = RuntimeWorkersTests.config()
            config.sessionCycleCap = 12
            let rt = RuntimeWorkersTests.runtime(container, config: config,
                                                 roster: ArenaRoster(registry: [Self.spinner]), workers: workers)
            rt.budget.scorerQoS = QOS_CLASS_BACKGROUND
            rt.start(accounts: { [Fixtures.account] })
            let started = await eventually(timeout: .seconds(600)) { rt.scorer.workers.count == workers }
            let starve = ProcessInfo.processInfo.environment["PACER_STOP_PROBE_STARVE"] == "1"
            let starver = starve ? Starver(threads: ProcessInfo.processInfo.activeProcessorCount) : nil
            try await Task.sleep(for: .seconds(1))
            let bound: Duration = starve ? .seconds(15) : .seconds(600)
            let began = ContinuousClock.now
            let wound: Bool
            if raise {
                wound = await rt.stop(within: bound)
            } else {
                // As before #446: the stop set, nothing raised.
                rt.cancel.set(true)
                wound = await BoundedWait.atMost(bound) { await rt.scorer.stop() }
            }
            let took = ContinuousClock.now - began
            starver?.stop()
            print("stop probe: \(raise ? "raised" : "not raised")\(starve ? ", starved" : ""): load \(Self.load()), all workers in: \(started), "
                  + "stop took \(took), wound down: \(wound)")
            #expect(await eventually(timeout: .seconds(600)) { rt.scorer.workers.count == 0 })
        }
    }
}
