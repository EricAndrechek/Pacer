import Foundation
import Testing
import SwiftData
@testable import PacerCore

/// The prediction trail: the change/heartbeat write policy, display-precision
/// signatures, the per-surface drafts, and the actor's end-to-end write path.
@Suite("Prediction snapshot trail")
struct PredictionSnapshotTests {

    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    static let now = utc.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 14, minute: 0))!

    // MARK: - Write policy

    @Test func firstSnapshotAlwaysRecords() {
        #expect(UsageIntelligenceEngine.shouldRecordSnapshot(prev: nil, now: Self.now, signature: "x"))
    }

    @Test func unchangedSignatureWithinHeartbeatIsSkipped() {
        let prev = (at: Self.now.addingTimeInterval(-60), sig: "x")
        #expect(!UsageIntelligenceEngine.shouldRecordSnapshot(prev: prev, now: Self.now, signature: "x"))
    }

    @Test func changedSignatureRecordsImmediately() {
        let prev = (at: Self.now.addingTimeInterval(-60), sig: "x")
        #expect(UsageIntelligenceEngine.shouldRecordSnapshot(prev: prev, now: Self.now, signature: "y"))
    }

    @Test func heartbeatForcesRecordEvenWhenUnchanged() {
        let prev = (at: Self.now.addingTimeInterval(-UsageIntelligenceEngine.snapshotHeartbeat), sig: "x")
        #expect(UsageIntelligenceEngine.shouldRecordSnapshot(prev: prev, now: Self.now, signature: "x"))
    }

    // MARK: - Display-precision signatures

    private func rlDraft(value: Double?, crossingAt: Date? = nil) -> UsageIntelligenceEngine.SnapshotDraft {
        .init(surface: "rl-five_hour", method: "m", periodKey: "p", periodEnd: nil,
              value: value, lo80: nil, hi80: nil, lo50: nil, hi50: nil,
              confidence: "medium", support: 10, note: nil, crossingAt: crossingAt)
    }

    private func costDraft(value: Double?) -> UsageIntelligenceEngine.SnapshotDraft {
        .init(surface: "eod", method: "m", periodKey: "p", periodEnd: nil,
              value: value, lo80: nil, hi80: nil, lo50: nil, hi50: nil,
              confidence: "medium", support: 10, note: nil)
    }

    @Test func utilisationSignatureIsStableWithinTheDisplayedPoint() {
        // 71.2% and 71.4% both display as 71% — same signature; 72.6% differs.
        #expect(rlDraft(value: 71.2).signature == rlDraft(value: 71.4).signature)
        #expect(rlDraft(value: 71.2).signature != rlDraft(value: 72.6).signature)
    }

    @Test func costSignatureIsStableWithinTwoSignificantFigures() {
        // $123 and $124 both display as $120 (2sf); $130 differs.
        #expect(costDraft(value: 123).signature == costDraft(value: 124).signature)
        #expect(costDraft(value: 123).signature != costDraft(value: 131).signature)
    }

    @Test func crossingSignatureBucketsAtFifteenMinutes() {
        let base = Self.now
        #expect(rlDraft(value: 50, crossingAt: base).signature
                == rlDraft(value: 50, crossingAt: base.addingTimeInterval(5 * 60)).signature)
        #expect(rlDraft(value: 50, crossingAt: base).signature
                != rlDraft(value: 50, crossingAt: base.addingTimeInterval(20 * 60)).signature)
    }

    @Test func insufficientValueIsItsOwnSignature() {
        #expect(costDraft(value: nil).signature != costDraft(value: 100).signature)
    }

    // MARK: - Drafts from features

    @Test func draftsCoverCostSurfacesEvenWhenInsufficient() {
        let f = EngineFeatures.build(now: Self.now, calendar: Self.utc, daily: [],
                                     hourly: [], rate: [], lastArrivalAt: nil)
        let fit = UsageIntelligenceEngine.makeFit(f)
        let drafts = UsageIntelligenceEngine.snapshotDrafts(f, fit)
        let surfaces = Set(drafts.map { $0.surface })
        // No rate-limit history ⇒ no rl drafts; the cost surfaces still record
        // their honest "insufficient" answers.
        #expect(surfaces == ["eod", "month"])
        #expect(drafts.allSatisfy { $0.value == nil })
        #expect(drafts.first { $0.surface == "eod" }?.periodKey == "2026-07-06")
        #expect(drafts.first { $0.surface == "month" }?.periodKey == "2026-07")
    }

    @Test func liveRateLimitCycleProducesADraftJoinableToTheEvalTable() {
        // A live 5h cycle: 40% → 60% over the last 90 minutes.
        var rate: [EngineFeatures.RateRow] = []
        let resetsAt = Self.now.addingTimeInterval(2 * 3600)
        for i in 0..<10 {
            let at = Self.now.addingTimeInterval(Double(i - 9) * 10 * 60)
            rate.append(.init(window: "five_hour", at: at,
                              usedPercentage: 40 + Double(i) * 2.2, resetsAt: resetsAt))
        }
        let f = EngineFeatures.build(now: Self.now, calendar: Self.utc, daily: [],
                                     hourly: [], rate: rate, lastArrivalAt: nil)
        let fit = UsageIntelligenceEngine.makeFit(f)
        let drafts = UsageIntelligenceEngine.snapshotDrafts(f, fit)
        let rl = drafts.first { $0.surface == "rl-five_hour" }
        #expect(rl != nil)
        // periodKey must match the self-eval table's cycle key so the replay
        // harness joins prediction → realized truth on equality.
        #expect(rl?.periodKey == EngineSelfEval.periodKeyRL(resetsAt))
        #expect(rl?.usedPct != nil)
        #expect(rl?.method.isEmpty == false)
    }

    // MARK: - Actor end-to-end (write, dedupe, heartbeat)

    @Test func actorWritesOncePerSignatureAndAgainOnHeartbeat() async throws {
        let container = try PacerStore.makeInMemoryContainer()
        let engine = UsageIntelligenceEngine(modelContainer: container)

        await engine.recompute(now: Self.now, calendar: Self.utc)
        let context = ModelContext(container)
        let afterFirst = (try? context.fetch(FetchDescriptor<PredictionSnapshot>()))?.count ?? 0
        #expect(afterFirst == 2)   // eod + month (no rate-limit history)

        // Unchanged answers a minute later: no new rows.
        await engine.recompute(now: Self.now.addingTimeInterval(60), calendar: Self.utc)
        let afterSecond = (try? context.fetch(FetchDescriptor<PredictionSnapshot>()))?.count ?? 0
        #expect(afterSecond == afterFirst)

        // Past the heartbeat: each surface re-records "still saying this".
        await engine.recompute(now: Self.now.addingTimeInterval(UsageIntelligenceEngine.snapshotHeartbeat + 61),
                               calendar: Self.utc)
        let afterHeartbeat = (try? context.fetch(FetchDescriptor<PredictionSnapshot>()))?.count ?? 0
        #expect(afterHeartbeat == afterFirst * 2)

        // Rows carry the version tags the replay harness keys on.
        let rows = (try? context.fetch(FetchDescriptor<PredictionSnapshot>())) ?? []
        #expect(rows.allSatisfy { $0.paramsVersion == EngineParams.version })
    }
}
