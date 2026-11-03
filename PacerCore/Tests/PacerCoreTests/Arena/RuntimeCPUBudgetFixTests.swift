import Foundation
import Testing
import SwiftData
@testable import PacerCore

/// The arena's CPU fixes (#368): a trained bucket state outlives the live
/// lane's history extensions, so a refit does not retrain it.
@Suite("Arena CPU: trained states across extensions", .serialized)
struct RuntimeCPUBudgetFixTests {
    typealias Log = MLModelTests.Log
    static let account = "S1"

    /// The registered GBM, cut down so a training is quick; the alignment
    /// (72 h seven-day buckets) is the registered one.
    static func spec() -> ArenaModelSpec {
        var s = ArenaRegistry.spec("ml-gbm-quantile")!
        s.config.values["n_estimators"] = 5
        return s
    }

    /// A built history on a synthetic store, as a full build hands it over.
    static func built() -> (ArenaHistoryBuilder.Built, Millis) {
        let store = MLTimingTests.synthetic(days: 30, accounts: [account], seed: 7)
        let end = store.meters.values.compactMap { $0.last?.tKnown }.max()!
        return (ArenaHistoryBuilder.Built(store: store, builtThrough: ArenaTime.date(end), generation: UUID()), end)
    }

    /// The store as a build at `t` would hold it: rows known by then.
    static func through(_ store: ArenaHistoryStore, _ t: Millis) -> ArenaHistoryStore {
        ArenaHistoryStore(meters: store.meters.mapValues { $0.filter { $0.tKnown <= t } },
                          spend: store.spend.mapValues { $0.filter { $0.tKnown <= t } },
                          tzOffsetMin: store.tzOffsetMin, dataStart: store.dataStart)
    }

    /// One seven-day forecast at the built history's end, through a runner as
    /// the live lane makes it.
    static func forecast(_ built: ArenaHistoryBuilder.Built, spec: ArenaModelSpec, log: Log) throws {
        let cut = ArenaHistory(store: built.store, now: ArenaTime.millis(built.builtThrough), accounts: [account])
        let req = ArenaRunner.request(history: cut, targets: [.meterSevenDay])
        try #require(!req.targets.isEmpty)
        let runner = ArenaRunner(registry: [spec], services: ArenaServices(log: { _, m in log.add(m) }))
        _ = try runner.forecast(model: spec.name, history: cut, request: req)
    }

    /// The live lane's shape: a build, then an extension and a forecast every
    /// five minutes for an hour, all in one 72 h bucket. One training, not one
    /// per refit; a full rebuild (a new generation) trains again.
    @Test func aBucketIsTrainedOncePerGenerationNotOncePerRefit() throws {
        let container = try PacerStore.makeInMemoryContainer()
        let spec = Self.spec()
        let log = Log()
        var (built, end) = Self.built()
        // Start early in a bucket so an hour of refits stays in it.
        let bucket = 72 * ArenaTime.hour
        let start = KitMLData.floorDiv(end - 2 * ArenaTime.hour, bucket) * bucket + ArenaTime.hour
        built = .init(store: Self.through(built.store, start), builtThrough: ArenaTime.date(start),
                      generation: built.generation)
        try Self.forecast(built, spec: spec, log: log)
        let trainedFirst = log.trained
        #expect(trainedFirst >= 1, "\(log.lines)")
        for i in 1...12 {
            built = ArenaHistoryBuilder.extend(built, container: container, account: Self.account,
                                               now: ArenaTime.date(start + Millis(i) * 5 * ArenaTime.minute))
            try Self.forecast(built, spec: spec, log: log)
        }
        #expect(log.trained == trainedFirst, "an extension retrained a held bucket: \(log.lines)")
        // A full build is a new generation: its own memo, so it trains.
        let rebuilt = ArenaHistoryBuilder.Built(
            store: ArenaHistoryStore(meters: built.store.meters, spend: built.store.spend,
                                     tzOffsetMin: built.store.tzOffsetMin, dataStart: built.store.dataStart),
            builtThrough: built.builtThrough, generation: UUID())
        try Self.forecast(rebuilt, spec: spec, log: log)
        #expect(log.trained == 2 * trainedFirst)
    }

    /// An hour of live refits (12, five minutes apart) on the registered
    /// model, with the trained states kept across extensions or, as before
    /// #368, lost at each one. `PACER_ML_BENCH=1`, release:
    /// `PACER_ML_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter RuntimeCPUBudgetFixTests`.
    static func refitHour(keep: Bool) throws -> (trainings: Int, cpu: Double) {
        let container = try PacerStore.makeInMemoryContainer()
        let spec = ArenaRegistry.spec("ml-gbm-quantile")!
        let log = Log()
        let (whole, end) = Self.built()
        let bucket = 72 * ArenaTime.hour
        let start = KitMLData.floorDiv(end - 2 * ArenaTime.hour, bucket) * bucket + ArenaTime.hour
        var built = ArenaHistoryBuilder.Built(store: Self.through(whole.store, start), builtThrough: ArenaTime.date(start),
                                              generation: UUID())
        let c0 = MLAlignTests.cpuSeconds()
        try Self.forecast(built, spec: spec, log: log)
        for i in 1...12 {
            built = ArenaHistoryBuilder.extend(built, container: container, account: Self.account,
                                               now: ArenaTime.date(start + Millis(i) * 5 * ArenaTime.minute))
            if !keep {
                let s = built.store
                built = .init(store: ArenaHistoryStore(meters: s.meters, spend: s.spend, tzOffsetMin: s.tzOffsetMin,
                                                       dataStart: s.dataStart),
                              builtThrough: built.builtThrough, generation: built.generation)
            }
            try Self.forecast(built, spec: spec, log: log)
        }
        return (log.trained, MLAlignTests.cpuSeconds() - c0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PACER_ML_BENCH"] != nil))
    func refitHourCost() throws {
        let before = try Self.refitHour(keep: false), after = try Self.refitHour(keep: true)
        print(String(format: "ml-gbm-quantile, 1 build + 12 refits on one seven-day meter (registered model, serial):\n"
                     + "  states lost at each extension: %d trainings, %.2f CPU s\n"
                     + "  states kept (#368):            %d trainings, %.2f CPU s",
                     before.trainings, before.cpu, after.trainings, after.cpu))
    }
}
