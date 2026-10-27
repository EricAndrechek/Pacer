import Foundation
import Testing
import SwiftData
@testable import PacerCore

/// What the unified record costs at full size, measured: one heavy five-hour
/// window graded by 40 models at 12 cuts over the shared depth, ranked as a
/// refit ranks it; the bytes a graded row takes on disk; and retiring a
/// previous grading's rows. Opt-in (`PACER_UNIFIED_PROBE=1`): it writes a
/// store of a hundred thousand rows.
@Suite("Runtime: unified record cost probe", .serialized)
struct RuntimeUnifiedCostProbe {

    static var enabled: Bool { ProcessInfo.processInfo.environment["PACER_UNIFIED_PROBE"] == "1" }

    static func period(_ p: Int) -> String {
        EngineSelfEval.periodKeyRL(Date(timeIntervalSince1970: 1_800_000_000 + Double(p) * 5 * 3600))
    }

    @Test func rankingAFullWindow() {
        guard Self.enabled else { return }
        let depth = EngineSelfEval.rlDepth(weekly: false)
        let cuts = EngineSelfEval.rlCutFractions
        var rows: [EngineSelfEval.Record] = []
        // The engine's seven over a year of cycles, 33 arena models over the depth.
        for m in 0..<7 {
            for p in 0..<1500 { for c in cuts {
                rows.append(.init(method: "engine-\(m)", bucket: EngineSelfEval.rlBucket(c), periodKey: Self.period(p),
                                  predicted: 50 + Double((p * 7 + m) % 11), truth: 50))
            } }
        }
        for m in 0..<33 {
            for p in (1500 - depth)..<1500 { for c in cuts {
                rows.append(.init(method: "arena-\(m)", bucket: EngineSelfEval.rlBucket(c), periodKey: Self.period(p),
                                  predicted: 50 + Double((p * 3 + m) % 13) * 0.7, truth: 50))
            } }
        }
        let clock = ContinuousClock()
        var r: EngineSelfEval.RLRanking?
        let took = clock.measure {
            r = EngineSelfEval.rankRL(rows, weekly: false, at: 0.4, depth: depth, tieRelative: 0.05)
        }
        print("PROBE rank \(rows.count) rows: \(took), span \(r?.span?.cycles ?? 0), ranked \(r?.ranked.count ?? 0)")
        #expect(r?.ranked.count == 40)
    }

    @Test func rowBytesAndRetiring() throws {
        guard Self.enabled else { return }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString).sqlite")
        let container = try ModelContainer(for: EngineEvalOutcome.self, configurations: ModelConfiguration(url: url))
        func size() -> Int {
            ["", "-wal", "-shm"].reduce(0) { total, suffix in
                total + ((try? FileManager.default.attributesOfItem(atPath: url.path + suffix)[.size] as? Int) ?? 0)
            }
        }
        let surface = "rl-five_hour#acct-0123456789abcdef"
        func insert(_ grading: EngineSelfEval.RLGrading, cycles: Int, inputs: String?) throws {
            let ctx = ModelContext(container)
            for m in 0..<40 {
                for p in 0..<cycles { for c in grading.cuts {
                    ctx.insert(EngineEvalOutcome(surface: surface, method: "model-name-\(m)-of-typical-length",
                                                 bucket: grading.bucket(c), periodKey: Self.period(p),
                                                 predicted: 51.25, truth: 50, inputs: inputs))
                } }
                try ctx.save()
            }
        }
        let empty = size()
        try insert(EngineSelfEval.previousRLGrading, cycles: 120, inputs: nil)
        let afterPrevious = size()
        try insert(EngineSelfEval.rlGrading, cycles: 120, inputs: "m1.p7.h12")
        let afterCurrent = size()
        let prevRows = 40 * 120 * 8, curRows = 40 * 120 * 12
        print("PROBE bytes/row previous \((afterPrevious - empty) / prevRows), current \((afterCurrent - afterPrevious) / curRows)")
        let clock = ContinuousClock()
        var removed = 0
        let took = clock.measure {
            removed = UsageIntelligenceEngine.deletePreviousGradings(container: container, surfaces: [surface])
        }
        let left = try ModelContext(container).fetchCount(FetchDescriptor<EngineEvalOutcome>())
        print("PROBE retired \(removed) rows in \(took); \(left) left")
        #expect(removed == prevRows)
        #expect(left == curRows)
    }
}
