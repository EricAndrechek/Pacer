import Foundation
import Testing
import SwiftData
@testable import PacerCore

/// The compare sheet's list of every arena model a window can run
/// (`UsageIntelligenceEngine.arenaModelList`): each with its record, or why it
/// has none yet. The pure listing first, then the engine's accessor over a
/// seeded store with test-double models (`RuntimeEngineTests`).
@Suite("Arena runtime: every model's standing for the compare sheet", .serialized)
struct RuntimeArenaListTests {

    // MARK: Pure listing

    static let meters: Set<ArenaTarget> = [.meterFiveHour, .meterSevenDay, .meterScoped]

    static func spec(_ name: String, weights: [String] = []) -> ArenaModelSpec {
        ArenaModelSpec(name: name, targets: meters, weights: weights) { RuntimeEngineTests.Peeker(context: $0) }
    }

    /// `periods` cycles of records for `method`, each missing by `miss`
    /// points at one mid-window cut.
    static func records(_ method: String, periods: Int, miss: Double) -> [EngineSelfEval.Record] {
        (0..<periods).map { p in
            let reset = Date(timeIntervalSince1970: 1_800_000_000 + Double(p) * 5 * 3600)
            return EngineSelfEval.Record(method: method, bucket: EngineSelfEval.rlBucket(0.5),
                                         periodKey: EngineSelfEval.periodKeyRL(reset),
                                         predicted: 50 + miss, truth: 50)
        }
    }

    static func accuracy(_ rows: [EngineSelfEval.Record], weekly: Bool = false) -> EngineSelfEval.Accuracy {
        EngineSelfEval.accuracy(surface: "rl-five_hour", from: rows, weekly: weekly)
    }

    static func listing(_ specs: [ArenaModelSpec], accuracy: EngineSelfEval.Accuracy? = nil, weekly: Bool = false,
                        pick: String? = nil, drawn: Set<String> = [], failures: [String: String] = [:],
                        missingWeights: Set<String> = []) -> [ArenaModelListing] {
        UsageIntelligenceEngine.arenaListing(
            specs: specs, accuracy: accuracy, weekly: weekly, pick: pick, drawn: drawn,
            liveFailure: { failures[$0] },
            weightsPresent: { spec in spec.weights.allSatisfy { !missingWeights.contains($0) } })
    }

    /// No record at all: every model is still scoring, none with a number,
    /// in a stable order.
    @Test func aWindowWithNoRecordsListsEveryModelAsScoring() {
        let out = Self.listing([Self.spec("test-b"), Self.spec("test-a")])
        #expect(out.map(\.id).count == 2)
        #expect(out.allSatisfy { $0.status == .scoring(cycles: 0, floor: 8) })
        #expect(out.allSatisfy { $0.typicalAbsError == nil && $0.cycles == 0 && !$0.isPick && !$0.isDrawn })
        #expect(out == Self.listing([Self.spec("test-a"), Self.spec("test-b")]))
    }

    /// Below the floor a model says how far its record has come and shows no
    /// accuracy, though the record has one; the deeper record lists first.
    @Test func aPartialRecordCountsCyclesAndShowsNoAccuracy() {
        let acc = Self.accuracy(Self.records("test-a", periods: 3, miss: 2)
                                + Self.records("test-b", periods: 5, miss: 9))
        let out = Self.listing([Self.spec("test-a"), Self.spec("test-b")], accuracy: acc)
        #expect(out.map(\.id) == ["test-b", "test-a"])
        #expect(out[0].status == .scoring(cycles: 5, floor: 8))
        #expect(out[1].status == .scoring(cycles: 3, floor: 8))
        #expect(out.allSatisfy { $0.typicalAbsError == nil })
    }

    /// At the floor the record's own number shows, the one the drawn rows
    /// show; recorded models list first, best first. Weekly windows need 3.
    @Test func aFullRecordShowsTheRecordsAccuracyBestFirst() {
        let rows = Self.records("test-a", periods: 8, miss: 6) + Self.records("test-b", periods: 12, miss: 2)
            + Self.records("test-c", periods: 7, miss: 1)
        let acc = Self.accuracy(rows)
        let out = Self.listing([Self.spec("test-a"), Self.spec("test-b"), Self.spec("test-c")], accuracy: acc)
        #expect(out.map(\.id) == ["test-b", "test-a", "test-c"])
        #expect(out[0].status == .recorded && out[0].cycles == 12)
        #expect(out[0].typicalAbsError == acc.methods.first { $0.method == "test-b" }?.typicalAbsError)
        #expect(out[0].typicalAbsError == 2)
        #expect(out[2].status == .scoring(cycles: 7, floor: 8))

        let weekly = Self.listing([Self.spec("test-c")], accuracy: Self.accuracy(rows, weekly: true), weekly: true)
        #expect(weekly.first?.status == .recorded)
        #expect(weekly.first?.typicalAbsError == 1)
    }

    @Test func thePickAndTheDrawnAreMarked() {
        let acc = Self.accuracy(Self.records("test-a", periods: 9, miss: 1) + Self.records("test-b", periods: 9, miss: 3))
        let out = Self.listing([Self.spec("test-a"), Self.spec("test-b"), Self.spec("test-c")], accuracy: acc,
                               pick: "test-b", drawn: ["test-a", "test-b"])
        #expect(out.filter(\.isPick).map(\.id) == ["test-b"])
        #expect(Set(out.filter(\.isDrawn).map(\.id)) == ["test-a", "test-b"])
    }

    /// Weights not on this Mac: downloading, listed last, unless the model
    /// already has its record (the record is still its standing). A stale
    /// "downloading" from the live cache does not outlive the weights' arrival.
    @Test func missingWeightsReadDownloading() {
        let pinned = Self.spec("test-pinned", weights: ["acme/net@abc"])
        let acc = Self.accuracy(Self.records("test-a", periods: 2, miss: 1))
        let out = Self.listing([pinned, Self.spec("test-a")], accuracy: acc, missingWeights: ["acme/net@abc"])
        #expect(out.map(\.id) == ["test-a", "test-pinned"])
        #expect(out[1].status == .downloading)

        let recorded = Self.accuracy(Self.records("test-pinned", periods: 8, miss: 1))
        #expect(Self.listing([pinned], accuracy: recorded, missingWeights: ["acme/net@abc"]).first?.status == .recorded)

        let arrived = Self.listing([pinned], failures: ["test-pinned": "downloading"])
        #expect(arrived.first?.status == .scoring(cycles: 0, floor: 8))
    }

    /// A live failure the runtime reported is shown in its words; a model with
    /// no record while another has its floor declined every cycle it was given.
    @Test func declinedModelsSayWhy() {
        let acc = Self.accuracy(Self.records("test-a", periods: 8, miss: 1))
        let out = Self.listing([Self.spec("test-a"), Self.spec("test-b"), Self.spec("test-c", weights: ["acme/x@1"]),
                                Self.spec("test-d")],
                               accuracy: acc, failures: ["test-d": "no forecast this cycle"],
                               missingWeights: ["acme/x@1"])
        #expect(out.map(\.id) == ["test-a", "test-b", "test-d", "test-c"])
        #expect(out[1].status == .declined(UsageIntelligenceEngine.arenaNoForecastsReason))
        #expect(out[2].status == .declined("no forecast this cycle"))
        // The deepest record that counts is among models that could run: a
        // downloading model's old record does not make the rest decliners.
        let stale = Self.accuracy(Self.records("test-c", periods: 9, miss: 1))
        let held = Self.listing([Self.spec("test-b"), Self.spec("test-c", weights: ["acme/x@1"])],
                                accuracy: stale, missingWeights: ["acme/x@1"])
        #expect(held.first { $0.id == "test-b" }?.status == .scoring(cycles: 0, floor: 8))
    }

    /// Helpers never compete, so they are never listed.
    @Test func helpersAreNotListed() {
        let roster = ArenaRoster(registry: [
            Self.spec("test-a"), RuntimeEngineTests.helper, Self.spec("port-live-meter"),
            Self.spec("fm-test-spend"),
            ArenaModelSpec(name: "test-hidden", targets: Self.meters, config: ["selectable": .bool(false)]) {
                RuntimeEngineTests.Peeker(context: $0)
            },
        ])
        let out = Self.listing(roster.specs(for: .meterFiveHour))
        #expect(out.map(\.id) == ["test-a"])
    }

    // MARK: The engine's accessor

    static func engine(roster: [ArenaModelSpec]) async throws
        -> (UsageIntelligenceEngine, ArenaRuntime, ModelContainer) {
        let container = try RuntimeEngineTests.seeded()
        let engine = await RuntimeEngineTests.engine(container)
        let rt = RuntimeEngineTests.runtime(container, roster: roster, engine: engine)
        await engine.adopt(arena: rt.link)
        return (engine, rt, container)
    }

    /// Before the first refit, for an engine with no account, and for a
    /// window it does not know: nothing to list.
    @Test func nothingIsListedWithoutAFitOrAnAccount() async throws {
        let (engine, _, container) = try await Self.engine(roster: [RuntimeEngineTests.peeker])
        #expect(await engine.arenaModelList(windowKey: "five_hour").isEmpty)
        await engine.recompute(now: RuntimeEngineTests.now)
        #expect(await engine.arenaModelList(windowKey: "no-such-window").isEmpty)

        let global = UsageIntelligenceEngine(modelContainer: container)
        await global.adopt(scope: .allAccounts)
        await global.recompute(now: RuntimeEngineTests.now)
        #expect(await global.arenaModelList(windowKey: "five_hour").isEmpty)
    }

    /// The whole path: before the scorer runs every selectable model is
    /// listed as scoring, helpers left out; after a pass each has its record,
    /// the same number the engine's accuracy carries, and the pick is marked.
    @Test func theAccessorListsEveryModelFromTheEnginesRecord() async throws {
        let pinned = ArenaModelSpec(name: "test-pinned", targets: Self.meters, weights: ["acme/net@abc"]) {
            RuntimeEngineTests.Peeker(context: $0)
        }
        let roster = [RuntimeEngineTests.oracle, RuntimeEngineTests.peeker, RuntimeEngineTests.helper, pinned]
        let (engine, rt, _) = try await Self.engine(roster: roster)
        await engine.recompute(now: RuntimeEngineTests.now)
        let before = await engine.arenaModelList(windowKey: "five_hour", weights: { _ in nil })
        #expect(Set(before.map(\.id)) == ["test-oracle", "test-peeker", "test-pinned"])
        #expect(before.first { $0.id == "test-pinned" }?.status == .downloading)
        #expect(before.filter { $0.id != "test-pinned" }.allSatisfy { $0.status == .scoring(cycles: 0, floor: 8) })

        _ = await rt.scorer.pass(accounts: [RuntimeEngineTests.account], now: RuntimeEngineTests.now)
        await engine.recompute(now: RuntimeEngineTests.now)
        let after = await engine.arenaModelList(windowKey: "five_hour", weights: { _ in nil })
        let accuracy = await engine.selfEvalAccuracy(surface: EngineSelfEval.rlSurface("five_hour"))
        let oracle = try #require(after.first { $0.id == "test-oracle" })
        #expect(oracle.status == .recorded)
        #expect(oracle.cycles >= 8)
        #expect(oracle.typicalAbsError == accuracy?.methods.first { $0.method == "test-oracle" }?.typicalAbsError)
        #expect(after.first?.id == "test-oracle")
        #expect(await engine.resolvedMethod(windowKey: "five_hour").selected == "test-oracle")
        #expect(after.filter(\.isPick).map(\.id) == ["test-oracle"])
        #expect(after.first { $0.id == "test-pinned" }?.status == .downloading)
        #expect(after.contains { $0.name == "test-oracle" })   // no display name: its id
    }
}
