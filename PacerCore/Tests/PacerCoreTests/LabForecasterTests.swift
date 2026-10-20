import Foundation
import Testing
import SwiftData
import Synchronization
@testable import PacerCore

/// External (lab helper) forecasters: a helper's models join the roster, the
/// record, selection and the compare list; a helper that fails or is slow
/// costs only its own models; with no helper nothing changes.
@Suite("Lab helper forecasters")
struct LabForecasterTests {

    static let now = Date(timeIntervalSince1970: 1_752_000_000)
    static let account = "org-lab"
    static let window: TimeInterval = 5 * 3600
    static let completedCycles = 6
    /// Every completed cycle ends here.
    static let peak = 80.0

    static var liveStart: Date { now.addingTimeInterval(-window * 0.25) }

    /// Six completed 5-hour cycles that climb to 80% by half-way and stay
    /// there (a straight line overshoots them early in the window), then a live
    /// cycle a quarter of the way in at 40%.
    static func seeded() throws -> ModelContainer {
        let container = try PacerStore.makeInMemoryContainer()
        let ctx = ModelContext(container)
        ctx.insert(Account(id: account, organizationId: account, displayName: "Lab", isActive: true,
                           firstSeenAt: now.addingTimeInterval(-10 * 86400), lastSeenAt: now))
        func pct(_ frac: Double) -> Double { min(peak, 160 * frac) }
        for c in 0..<completedCycles {
            let start = liveStart.addingTimeInterval(-Double(completedCycles - c) * window)
            let reset = start.addingTimeInterval(window)
            for k in 0...30 {
                let t = start.addingTimeInterval(Double(k) * 600)
                ctx.insert(RateLimitSample(sampledAt: t, window: "five_hour", usedPercentage: pct(Double(k) / 30),
                                           resetsAt: reset, source: "oauth", accountId: account))
            }
        }
        let liveReset = liveStart.addingTimeInterval(window)
        var t = liveStart
        while t <= now {
            ctx.insert(RateLimitSample(sampledAt: t, window: "five_hour",
                                       usedPercentage: pct(t.timeIntervalSince(liveStart) / window),
                                       resetsAt: liveReset, source: "oauth", accountId: account))
            t = t.addingTimeInterval(600)
        }
        try ctx.save()
        return container
    }

    static func engine(_ container: ModelContainer, lab: (any LabForecastFetching)? = nil,
                       liveTimeout: Duration = .milliseconds(1500)) async -> UsageIntelligenceEngine {
        let engine = UsageIntelligenceEngine(modelContainer: container)
        await engine.adopt(scope: .account(account))
        if let lab { await engine.useLabHelperForTesting(lab, liveTimeout: liveTimeout, backfillTimeout: .seconds(5)) }
        return engine
    }

    static func labRows(_ container: ModelContainer, method: String) throws -> [EngineEvalOutcome] {
        try ModelContext(container).fetch(FetchDescriptor<EngineEvalOutcome>()).filter { $0.method == method }
    }

    static let modelA = LabModelInfo(id: "lab-test-a", displayName: "Test model A", summary: "A summary.",
                                     howItWorks: "How A works.", windows: ["five_hour"], complexity: 6)
    static let modelB = LabModelInfo(id: "lab-test-b", displayName: "Test model B", windows: ["*"])

    // MARK: - Roster, record, selection, compare list

    @Test func aHelperModelJoinsTheRosterTheRecordAndTheCompareList() async throws {
        let container = try Self.seeded()
        let stub = StubLabHelper(models: [Self.modelA]) { _, _ in Self.peak }
        let engine = await Self.engine(container, lab: stub)
        await engine.recompute(now: Self.now)

        // One request for the one window it serves: the live cycle (one cut,
        // now) plus the two most recently completed cycles, every scored cut.
        let requests = stub.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.window == "five_hour" && request.account == Self.account && request.models == ["lab-test-a"])
        #expect(request.duration == Self.window)
        #expect(request.cycles.count == 3)
        #expect(request.cycles[0].cuts == [Self.now.timeIntervalSince1970])
        #expect(request.cycles.dropFirst().allSatisfy { $0.cuts.count == 8 && $0.resetsAt < Self.now.timeIntervalSince1970 })

        // Scored on those two cycles, every cut, at the value it named.
        let rows = try Self.labRows(container, method: "lab-test-a")
        #expect(Set(rows.map(\.periodKey)).count == 2 && rows.count == 16)
        #expect(rows.allSatisfy { $0.predicted == Self.peak && $0.truth == Self.peak })

        // Drawn and listed with its two-cycle record, but it can't take the
        // window until the full-history pass has covered it.
        let early = await engine.rateLimitTrajectories(windowKey: "five_hour")
        #expect(early.first { $0.modelId == "lab-test-a" }.map { $0.canProject && !$0.isSelected } == true)
        #expect(await engine.ask(.rateLimitOutlook(.fiveHour)).method != "rl-lab-test-a")
        _ = await engine.backfillRateLimitRecordIfNeeded(now: Self.now, batch: 2, pause: .zero)
        await engine.recompute(now: Self.now)
        // Every cycle on record now: the refit asks about the live cycle alone.
        #expect(stub.requests.last?.cycles.count == 1)

        // It is exact where every straight line overshoots, so the record picks it.
        let outlook = await engine.ask(.rateLimitOutlook(.fiveHour))
        #expect(outlook.method == "rl-lab-test-a")
        #expect(abs(outlook.value - Self.peak) < 1e-9)
        #expect(await engine.burnOutlook(window: .fiveHour)?.method == "lab-test-a")
        #expect(await engine.snapshot().fiveHour?.endPct.map { abs($0 - Self.peak) < 1e-9 } == true)

        // The compare list carries it with its line and record, by the name it was served under.
        let list = await engine.rateLimitTrajectories(windowKey: "five_hour")
        let lab = try #require(list.first { $0.modelId == "lab-test-a" })
        #expect(lab.canProject && lab.isSelected && lab.complexity == 6)
        #expect(abs((lab.trajectory.points.last?.usedPercentage ?? 0) - Self.peak) < 1e-9)
        #expect(lab.typicalAbsError == 0)
        #expect(list.filter(\.isSelected).count == 1)
        #expect(BurnTrajectory.displayName("lab-test-a") == "Test model A")
        #expect(BurnTrajectory.summary("lab-test-a") == "A summary.")
        #expect(BurnTrajectory.howItWorks("lab-test-a", windowDuration: Self.window) == "How A works.")
        let accuracy = try #require(await engine.selfEvalAccuracy(surface: EngineSelfEval.rlSurface("five_hour")))
        #expect(accuracy.methods.contains { $0.method == "lab-test-a" && $0.periods == Self.completedCycles })
    }

    /// Without the pass, live refits work through the unscored cycles two at a
    /// time, never asking about one twice.
    @Test func liveRefitsTakeTheUnscoredCyclesTwoAtATime() async throws {
        let container = try Self.seeded()
        let stub = StubLabHelper(models: [Self.modelA]) { _, _ in Self.peak }
        let engine = await Self.engine(container, lab: stub)
        for _ in 0..<4 { await engine.recompute(now: Self.now) }
        #expect(stub.requests.map(\.cycles.count) == [3, 3, 3, 1])
        let asked = stub.requests.flatMap { $0.cycles.dropFirst().map(\.resetsAt) }
        #expect(asked.count == Self.completedCycles && Set(asked).count == Self.completedCycles)
        #expect(Set(try Self.labRows(container, method: "lab-test-a").map(\.periodKey)).count == Self.completedCycles)
    }

    @Test func theFullHistoryPassScoresEveryCycleAndANewModelReRunsItAlone() async throws {
        let container = try Self.seeded()
        let stub = StubLabHelper(models: [Self.modelA]) { _, _ in Self.peak }
        let engine = await Self.engine(container, lab: stub)
        await engine.recompute(now: Self.now)
        let builtinRows = try Self.labRows(container, method: "linear-recent").count

        let added = await engine.backfillRateLimitRecordIfNeeded(now: Self.now, batch: 2, pause: .zero)
        #expect(added == (Self.completedCycles - 2) * 8)       // the four cycles the refit left
        #expect(Set(try Self.labRows(container, method: "lab-test-a").map(\.periodKey)).count == Self.completedCycles)
        #expect(try Self.labRows(container, method: "linear-recent").count == builtinRows)
        let marker = try ModelContext(container).fetch(FetchDescriptor<ClaudeCodeMeta>())
            .first { $0.key == "rl_record_backfill|\(Self.account)" }?.value
        #expect(UsageIntelligenceEngine.coveredModels(marker)
                == Set(UsageIntelligenceEngine.recordBackfillBuiltinIds + ["lab-test-a"]))

        // A relaunch with the same helper: covered, no lab request at all.
        let again = StubLabHelper(models: [Self.modelA]) { _, _ in Self.peak }
        let relaunched = await Self.engine(container, lab: again)
        #expect(await relaunched.backfillRateLimitRecordIfNeeded(now: Self.now, batch: 2, pause: .zero) == 0)
        #expect(again.requests.isEmpty)

        // The helper registers another model: the pass runs for it alone.
        let wider = StubLabHelper(models: [Self.modelA, Self.modelB]) { _, _ in 70 }
        let third = await Self.engine(container, lab: wider)
        let addedB = await third.backfillRateLimitRecordIfNeeded(now: Self.now, batch: 2, pause: .zero)
        #expect(addedB == Self.completedCycles * 8)
        #expect(wider.requests.allSatisfy { $0.models == ["lab-test-b"] })
        #expect(Set(try Self.labRows(container, method: "lab-test-b").map(\.periodKey)).count == Self.completedCycles)
        // 70 where the meter is below it; past half-way the meter (80) is the floor.
        #expect(try Self.labRows(container, method: "lab-test-b").allSatisfy { $0.predicted == max(70, min(80, 160 * (Double($0.bucket.dropFirst(4).prefix(4)) ?? 0))) })
        #expect(try Self.labRows(container, method: "linear-recent").count == builtinRows)
    }

    /// A model the helper adds while the app runs sends a finished pass round again.
    @Test func aModelAddedLaterReopensTheFinishedPass() async throws {
        let container = try Self.seeded()
        let stub = MutableLabHelper(models: [Self.modelA])
        let engine = await Self.engine(container, lab: stub.helper)
        await engine.recompute(now: Self.now)
        _ = await engine.backfillRateLimitRecordIfNeeded(now: Self.now, batch: 4, pause: .zero)
        #expect(await engine.backfillRateLimitRecordIfNeeded(now: Self.now, pause: .zero) == 0)  // done

        stub.serve([Self.modelA, Self.modelB])
        await engine.expireLabCatalogForTesting()
        await engine.recompute(now: Self.now)
        let added = await engine.backfillRateLimitRecordIfNeeded(now: Self.now, batch: 4, pause: .zero)
        #expect(added > 0)
        #expect(Set(try Self.labRows(container, method: "lab-test-b").map(\.periodKey)).count == Self.completedCycles)
    }

    // MARK: - A helper that fails or is slow

    /// The reference: the same store, no helper.
    static func reference() async throws -> (Estimate, [BurnTrajectory.ScoredTrajectory]) {
        let engine = await Self.engine(try Self.seeded())
        await engine.recompute(now: Self.now)
        return (await engine.ask(.rateLimitOutlook(.fiveHour)), await engine.rateLimitTrajectories(windowKey: "five_hour"))
    }

    static func sameBuiltIns(_ a: [BurnTrajectory.ScoredTrajectory], _ b: [BurnTrajectory.ScoredTrajectory]) -> Bool {
        let x = a.filter { !LabHelper.isExternal($0.modelId) }, y = b.filter { !LabHelper.isExternal($0.modelId) }
        return x.map(\.modelId) == y.map(\.modelId)
            && zip(x, y).allSatisfy { $0.trajectory == $1.trajectory && $0.isSelected == $1.isSelected
                && $0.typicalAbsError == $1.typicalAbsError && $0.unavailableReason == $1.unavailableReason }
    }

    @Test func aHelperThatIsDownFromTheStartAddsNothing() async throws {
        let (refOutlook, refList) = try await Self.reference()
        let stub = StubLabHelper(models: [Self.modelA], failModels: true) { _, _ in Self.peak }
        let engine = await Self.engine(try Self.seeded(), lab: stub)
        await engine.recompute(now: Self.now)
        #expect(await engine.ask(.rateLimitOutlook(.fiveHour)) == refOutlook)
        let list = await engine.rateLimitTrajectories(windowKey: "five_hour")
        #expect(list.map(\.modelId) == refList.map(\.modelId))
        #expect(Self.sameBuiltIns(list, refList))
        #expect(stub.requests.isEmpty)
    }

    @Test func aHelperThatStopsAnsweringLeavesItsModelsListedWithoutALine() async throws {
        let (refOutlook, refList) = try await Self.reference()
        let stub = StubLabHelper(models: [Self.modelA], failForecasts: true) { _, _ in Self.peak }
        let container = try Self.seeded()
        let engine = await Self.engine(container, lab: stub)
        await engine.recompute(now: Self.now)
        #expect(await engine.ask(.rateLimitOutlook(.fiveHour)) == refOutlook)
        let list = await engine.rateLimitTrajectories(windowKey: "five_hour")
        #expect(Self.sameBuiltIns(list, refList))
        let lab = try #require(list.first { $0.modelId == "lab-test-a" })
        #expect(!lab.canProject && lab.unavailableReason == "lab helper not reachable")
        #expect(try Self.labRows(container, method: "lab-test-a").isEmpty)
    }

    /// A lab model that holds the window and then loses its helper hands the
    /// window back to the built-in pick, its record still on show.
    @Test func aRecordedLabModelThatCannotAnswerDoesNotKeepTheWindow() async throws {
        let (refOutlook, refList) = try await Self.reference()
        let stub = MutableLabHelper(models: [Self.modelA], final: Self.peak)
        let engine = await Self.engine(try Self.seeded(), lab: stub.helper)
        await engine.recompute(now: Self.now)
        _ = await engine.backfillRateLimitRecordIfNeeded(now: Self.now, batch: 4, pause: .zero)
        await engine.recompute(now: Self.now)
        #expect(await engine.ask(.rateLimitOutlook(.fiveHour)).method == "rl-lab-test-a")

        stub.fail(true)
        await engine.recompute(now: Self.now)
        #expect(await engine.ask(.rateLimitOutlook(.fiveHour)) == refOutlook)
        let list = await engine.rateLimitTrajectories(windowKey: "five_hour")
        let lab = try #require(list.first { $0.modelId == "lab-test-a" })
        #expect(!lab.canProject && !lab.isSelected && lab.typicalAbsError == 0)
        #expect(list.filter(\.isSelected).map(\.modelId) == refList.filter(\.isSelected).map(\.modelId))
    }

    @Test func aSlowHelperTimesOutAndTheRefitGoesOn() async throws {
        let (refOutlook, refList) = try await Self.reference()
        let stub = StubLabHelper(models: [Self.modelA], forecastDelay: .seconds(10)) { _, _ in Self.peak }
        let engine = await Self.engine(try Self.seeded(), lab: stub, liveTimeout: .milliseconds(200))
        let started = ContinuousClock.now
        await engine.recompute(now: Self.now)
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(await engine.ask(.rateLimitOutlook(.fiveHour)) == refOutlook)
        let list = await engine.rateLimitTrajectories(windowKey: "five_hour")
        #expect(Self.sameBuiltIns(list, refList))
        #expect(list.first { $0.modelId == "lab-test-a" }?.unavailableReason == "lab helper not reachable")
    }

    // MARK: - No helper: unchanged

    @Test func withoutAHelperTheEngineIsTheOneThatShips() async throws {
        let suite = "pacer.labtests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(LabHelper.configuredURL(environment: [:], defaults: defaults, isTestProcess: false) == nil)
        #expect(LabHelper.configuredURL(environment: ["PACER_LAB_HELPER": "http://127.0.0.1:7231"],
                                        defaults: defaults, isTestProcess: false)?.port == 7231)
        #expect(LabHelper.configuredURL(environment: ["PACER_LAB_HELPER": "http://127.0.0.1:7231"],
                                        defaults: defaults, isTestProcess: true) == nil)
        // Synthetic screenshots never ask; a live render may.
        #expect(LabHelper.configuredURL(environment: ["PACER_LAB_HELPER": "http://127.0.0.1:7231",
                                                      "PACER_SCREENSHOT_MODE": "1"],
                                        defaults: defaults, isTestProcess: false) == nil)
        #expect(LabHelper.configuredURL(environment: ["PACER_LAB_HELPER": "http://127.0.0.1:7231",
                                                      "PACER_SCREENSHOT_MODE": "1", "PACER_RENDER_LIVE": "auto"],
                                        defaults: defaults, isTestProcess: false) != nil)
        defaults.set("http://localhost:9000", forKey: LabHelper.defaultsKey)
        #expect(LabHelper.configuredURL(environment: [:], defaults: defaults, isTestProcess: false)?.port == 9000)
        defaults.set("not a url", forKey: LabHelper.defaultsKey)
        #expect(LabHelper.configuredURL(environment: [:], defaults: defaults, isTestProcess: false) == nil)
        defaults.set("ftp://127.0.0.1", forKey: LabHelper.defaultsKey)
        #expect(LabHelper.configuredURL(environment: [:], defaults: defaults, isTestProcess: false) == nil)
        // A test process never finds one, whatever the machine has set.
        #expect(!LabHelper.isConfigured)

        // The marker rule without a helper is the old one, to the byte.
        #expect(UsageIntelligenceEngine.recordBackfillFingerprint
                == "v1|v2|damped-acceleration,diurnal-rate,kalman-trend,linear-recent,recency-weighted,recent-rate,saturating")
        #expect(UsageIntelligenceEngine.recordBackfillPlan(
            marker: UsageIntelligenceEngine.recordBackfillFingerprint, labIds: nil) == nil)
        #expect(UsageIntelligenceEngine.recordBackfillPlan(
            marker: UsageIntelligenceEngine.recordBackfillFingerprint + ",lab-x", labIds: nil)?.builtins == true)
        #expect(UsageIntelligenceEngine.recordBackfillPlan(marker: nil, labIds: nil)?.builtins == true)
    }

    /// Lab rows a helper once left in the store are ignored once it is gone:
    /// the same answers as a store that never had them.
    @Test func lateLabRecordsAreIgnoredWithoutAHelper() async throws {
        let (refOutlook, refList) = try await Self.reference()
        let container = try Self.seeded()
        let ctx = ModelContext(container)
        let surface = EngineScope.account(Self.account).qualify(EngineSelfEval.rlSurface("five_hour"))
        for c in 0..<Self.completedCycles {
            let reset = Self.liveStart.addingTimeInterval(-Double(Self.completedCycles - c - 1) * Self.window)
            for cf in EngineSelfEval.rlCutFractions {
                ctx.insert(EngineEvalOutcome(surface: surface, method: "lab-ghost", bucket: EngineSelfEval.rlBucket(cf),
                                             periodKey: EngineSelfEval.periodKeyRL(reset),
                                             predicted: Self.peak, truth: Self.peak))
            }
        }
        try ctx.save()
        let engine = await Self.engine(container)
        await engine.recompute(now: Self.now)
        #expect(await engine.ask(.rateLimitOutlook(.fiveHour)) == refOutlook)
        let list = await engine.rateLimitTrajectories(windowKey: "five_hour")
        #expect(list.map(\.modelId) == refList.map(\.modelId))
        #expect(Self.sameBuiltIns(list, refList))
        let accuracy = await engine.selfEvalAccuracy(surface: EngineSelfEval.rlSurface("five_hour"))
        #expect(accuracy?.methods.contains { $0.method == "lab-ghost" } == false)
    }

    // MARK: - Pure pieces

    @Test func theMarkerReadsAsASetOnceAHelperIsConfigured() {
        typealias E = UsageIntelligenceEngine
        let builtins = E.recordBackfillFingerprint
        #expect(E.recordBackfillPlan(marker: builtins, labIds: []) == nil)
        let owed = E.recordBackfillPlan(marker: builtins, labIds: ["lab-a"])
        #expect(owed?.builtins == false && owed?.labIds == ["lab-a"])
        #expect(E.recordBackfillPlan(marker: builtins + ",lab-a", labIds: ["lab-a"]) == nil)
        // A model the helper dropped doesn't re-run anything.
        #expect(E.recordBackfillPlan(marker: builtins + ",lab-a,lab-z", labIds: ["lab-a"]) == nil)
        // Another version's marker owes everything.
        let fresh = E.recordBackfillPlan(marker: "v0|v1|linear-recent", labIds: ["lab-a"])
        #expect(fresh?.builtins == true && fresh?.labIds == ["lab-a"])
        #expect(E.recordBackfillMarker(previous: nil, ranBuiltins: true, labDone: []) == builtins)
        #expect(E.coveredModels(E.recordBackfillMarker(previous: builtins + ",lab-z", ranBuiltins: false,
                                                       labDone: ["lab-a"])).isSuperset(of: ["lab-a", "lab-z"]))
        #expect(E.recordBackfillMarker(previous: nil, ranBuiltins: false, labDone: ["lab-a"]) == "v1|v2|lab-a")
    }

    @Test func aLabModelShowsTheValueItNamedClampedToTheMeter() throws {
        let start = Self.now.addingTimeInterval(-3600), reset = start.addingTimeInterval(Self.window)
        let partial = BurnTrajectory.PartialCycle(
            samples: [.init(at: start.addingTimeInterval(600), usedPercentage: 10),
                      .init(at: Self.now, usedPercentage: 30)],
            now: Self.now, cycleStart: start, resetsAt: reset)
        func model(_ final: Double) -> LabForecastModel {
            LabForecastModel(id: "lab-x", complexity: 6,
                             predictions: [LabKey(resetsAt: reset, cut: Self.now): LabPrediction(final: final)],
                             unavailableNote: "no forecast from the lab model")
        }
        for (final, shown) in [(70.0, 70.0), (12.0, 30.0), (140.0, 100.0)] {
            let line = try #require(model(final).fit(partial))
            #expect(abs(line(Self.now) - 30) < 1e-9)                 // starts on the reading: no anchor
            #expect(abs(BurnTrajectory.displayedAtReset(line, partial: partial) - shown) < 1e-9)
        }
        // Another cut, another cycle: nothing to say.
        let later = BurnTrajectory.PartialCycle(samples: partial.samples, now: Self.now.addingTimeInterval(1),
                                                cycleStart: start, resetsAt: reset)
        #expect(model(70).fit(later) == nil)
        // A reset that jitters by milliseconds is the same cycle.
        #expect(LabKey(resetsAt: reset, cut: Self.now) == LabKey(resetsAt: reset.addingTimeInterval(0.004), cut: Self.now))
    }

    @Test func answersAreMatchedToTheRequestByPosition() {
        let reset = Self.now.addingTimeInterval(3600)
        let cuts = [Self.now.addingTimeInterval(-60), Self.now]
        let request = LabForecastRequest(
            window: "five_hour", duration: Self.window, account: nil,
            cycles: [.init(cycleStart: reset.addingTimeInterval(-Self.window), resetsAt: reset, cuts: cuts)],
            models: ["lab-a"], deadlineMs: nil)
        let response = LabForecastResponse(cycles: [.init(predictions: [
            "lab-a": [LabPrediction(final: 50), nil],
            "lab-unasked": [LabPrediction(final: 99), LabPrediction(final: 99)],
        ])])
        let table = UsageIntelligenceEngine.labPredictions(request: request, response: response)
        #expect(table.keys.sorted() == ["lab-a"])
        #expect(table["lab-a"]?[LabKey(resetsAt: reset, cut: cuts[0])]?.final == 50)
        #expect(table["lab-a"]?[LabKey(resetsAt: reset, cut: cuts[1])] == nil)
    }

    @Test func onlyNamespacedIdsAreUsed() {
        let served = [
            LabModelInfo(id: "lab-ok", displayName: "OK", windows: ["five_hour"]),
            LabModelInfo(id: "recent-rate", displayName: "Shadow", windows: ["five_hour"]),
            LabModelInfo(id: "lab-bad,comma", displayName: "Bad", windows: ["five_hour"]),
            LabModelInfo(id: "lab-nowindows", displayName: "None", windows: []),
            LabModelInfo(id: "lab-ok", displayName: "Duplicate", windows: ["*"]),
        ]
        #expect(LabModelInfo.usable(served).map(\.displayName) == ["OK"])
        #expect(BurnTrajectory.displayName("recent-rate") == "Latest pace, held")
        #expect(BurnTrajectory.displayName("lab-never-served") == "lab-never-served")
    }
}

/// The real client's wire format, against a stubbed transport.
@Suite("Lab helper client", .serialized)
struct LabHelperClientTests {

    static func client() -> LabHelperClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubLabURLProtocol.self]
        return LabHelperClient(baseURL: URL(string: "http://lab.test:7231")!, configuration: cfg)
    }

    @Test func modelsDecodeLeniently() async throws {
        StubLabURLProtocol.respond { request in
            #expect(request.url?.path == "/v1/models" && request.httpMethod == "GET")
            return (200, #"{"models":[{"id":"lab-a","displayName":"A","summary":"s","howItWorks":"h","windows":["five_hour"],"complexity":2},{"id":"lab-b","windows":["*"]}]}"#)
        }
        let models = try await Self.client().models()
        #expect(models.count == 2)
        #expect(models[0] == LabModelInfo(id: "lab-a", displayName: "A", summary: "s", howItWorks: "h",
                                          windows: ["five_hour"], complexity: 2))
        #expect(models[1].displayName == "lab-b" && models[1].complexity == LabHelper.defaultComplexity)
        #expect(models[1].serves("seven_day"))
    }

    @Test func forecastSendsTheBatchAndReadsNullsAsDeclines() async throws {
        let body = DataBox()
        StubLabURLProtocol.respond { request in
            body.value.withLock { $0 = StubLabURLProtocol.body(of: request) }
            #expect(request.url?.path == "/v1/forecast" && request.httpMethod == "POST")
            return (200, #"{"cycles":[{"predictions":{"lab-a":[{"final":61.5,"q10":50,"q90":70},null,{"final":null}]}}]}"#)
        }
        let reset = Date(timeIntervalSince1970: 1_752_003_600)
        let cuts = [1_752_000_000.0, 1_752_000_600.0, 1_752_001_200.0].map(Date.init(timeIntervalSince1970:))
        let request = LabForecastRequest(
            window: "five_hour", duration: 18000, account: "org-a",
            cycles: [.init(cycleStart: reset.addingTimeInterval(-18000), resetsAt: reset, cuts: cuts)],
            models: ["lab-a"], deadlineMs: 1200)
        let response = try await Self.client().forecast(request)
        #expect(response.cycles.count == 1)
        #expect(response.cycles[0].predictions["lab-a"] == [LabPrediction(final: 61.5, q10: 50, q90: 70), nil, nil])

        let sent = try #require(body.value.withLock { $0 })
        let json = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        #expect(Set(json.keys) == ["window", "duration", "account", "cycles", "models", "deadlineMs"])
        let cycle = try #require((json["cycles"] as? [[String: Any]])?.first)
        #expect(Set(cycle.keys) == ["cycleStart", "resetsAt", "cuts"])
        #expect((cycle["cuts"] as? [Double]) == cuts.map(\.timeIntervalSince1970))
    }

    @Test func aServerErrorThrows() async {
        StubLabURLProtocol.respond { _ in (500, "{}") }
        await #expect(throws: LabHelperError.badStatus(500)) { try await Self.client().models() }
        StubLabURLProtocol.respond { _ in (200, "not json") }
        await #expect(throws: LabHelperError.malformed) { try await Self.client().models() }
    }
}

// MARK: - Stubs

/// A helper that serves fixed models and answers every cut with `final(request, cut)`.
final class StubLabHelper: LabForecastFetching {
    let served: [LabModelInfo]
    let failModels: Bool
    let failForecasts: Bool
    let forecastDelay: Duration?
    let final: @Sendable (LabForecastRequest, Double) -> Double?
    private let log = Mutex<[LabForecastRequest]>([])

    init(models: [LabModelInfo], failModels: Bool = false, failForecasts: Bool = false,
         forecastDelay: Duration? = nil, final: @escaping @Sendable (LabForecastRequest, Double) -> Double?) {
        self.served = models
        self.failModels = failModels
        self.failForecasts = failForecasts
        self.forecastDelay = forecastDelay
        self.final = final
    }

    var requests: [LabForecastRequest] { log.withLock { $0 } }

    func models() async throws -> [LabModelInfo] {
        if failModels { throw URLError(.cannotConnectToHost) }
        return served
    }

    func forecast(_ request: LabForecastRequest) async throws -> LabForecastResponse {
        log.withLock { $0.append(request) }
        if let forecastDelay { try await Task.sleep(for: forecastDelay) }
        if failForecasts { throw URLError(.cannotConnectToHost) }
        return LabForecastResponse(cycles: request.cycles.map { cycle in
            .init(predictions: Dictionary(uniqueKeysWithValues: request.models.map { id in
                (id, cycle.cuts.map { cut in final(request, cut).map { LabPrediction(final: $0) } })
            }))
        })
    }
}

/// A helper whose served models can change, as a helper restarted with a new
/// predictor does.
final class MutableLabHelper: Sendable {
    private let current: Mutex<[LabModelInfo]>
    private let failing = Mutex(false)
    let final: Double
    init(models: [LabModelInfo], final: Double = 75) { current = Mutex(models); self.final = final }
    func serve(_ models: [LabModelInfo]) { current.withLock { $0 = models } }
    func fail(_ on: Bool) { failing.withLock { $0 = on } }
    var isFailing: Bool { failing.withLock { $0 } }
    var helper: StubLabHelperView { StubLabHelperView(owner: self) }
    var models: [LabModelInfo] { current.withLock { $0 } }
}

struct StubLabHelperView: LabForecastFetching {
    let owner: MutableLabHelper
    func models() async throws -> [LabModelInfo] { owner.models }
    func forecast(_ request: LabForecastRequest) async throws -> LabForecastResponse {
        if owner.isFailing { throw URLError(.cannotConnectToHost) }
        let final = owner.final
        return LabForecastResponse(cycles: request.cycles.map { cycle in
            .init(predictions: Dictionary(uniqueKeysWithValues: request.models.map { id in
                (id, cycle.cuts.map { _ in LabPrediction(final: final) })
            }))
        })
    }
}

final class DataBox: Sendable { let value = Mutex<Data?>(nil) }

/// URLProtocol stub for `LabHelperClient`. One handler at a time: the suite
/// using it is serialized.
final class StubLabURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, String))?

    static func respond(_ handler: @escaping @Sendable (URLRequest) -> (Int, String)) { self.handler = handler }

    /// URLSession moves a request's body into a stream before a protocol sees it.
    static func body(of request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            guard n > 0 else { break }
            data.append(buffer, count: n)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, text) = Self.handler?(request) ?? (404, "")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The real client against a real helper. Skipped unless `PACER_LAB_E2E_URL`
/// names one (e.g. `PACER_LAB_PORT=7299 make lab-helper`, then
/// `PACER_LAB_E2E_URL=http://127.0.0.1:7299 swift test --filter LabHelperEndToEnd`).
@Suite("Lab helper end to end")
struct LabHelperEndToEndTests {
    static let url = ProcessInfo.processInfo.environment["PACER_LAB_E2E_URL"].flatMap(URL.init(string:))

    @Test(.enabled(if: url != nil)) func theSwiftClientAndThePythonHelperAgreeOnTheWire() async throws {
        let client = LabHelperClient(baseURL: try #require(Self.url))
        let models = LabModelInfo.usable(try await client.models())
        #expect(models.contains { $0.id == "lab-recent-rate-py" })
        let now = Date()
        let reset = now.addingTimeInterval(3 * 3600)
        let past = reset.addingTimeInterval(-5 * 3600)
        let request = LabForecastRequest(
            window: "five_hour", duration: 5 * 3600,
            account: ProcessInfo.processInfo.environment["PACER_LAB_E2E_ACCOUNT"],
            cycles: [.init(cycleStart: reset.addingTimeInterval(-5 * 3600), resetsAt: reset, cuts: [now]),
                     .init(cycleStart: past.addingTimeInterval(-5 * 3600), resetsAt: past,
                           cuts: [0.2, 0.5, 0.9].map { past.addingTimeInterval(-5 * 3600 * (1 - $0)) })],
            models: models.map(\.id), deadlineMs: 1200)
        let started = ContinuousClock.now
        let response = try await client.forecast(request)
        #expect(ContinuousClock.now - started < .seconds(1.5))
        #expect(response.cycles.count == 2)
        for (cycle, sent) in zip(response.cycles, request.cycles) {
            #expect(Set(cycle.predictions.keys) == Set(models.filter { $0.serves("five_hour") }.map(\.id)))
            #expect(cycle.predictions.values.allSatisfy { $0.count == sent.cuts.count })
        }
    }
}

/// The plumbing check on real data: the engine and a real helper over a frozen
/// copy of a real store, the helper reading that same copy. The helper's
/// `lab-recent-rate-py` is the built-in `recent-rate` rule in Python, so on
/// every (cycle, cut) both have scored, the two should agree. Skipped unless
/// `PACER_LAB_E2E_STORE` (the copy; the test writes outcomes into it) and
/// `PACER_LAB_E2E_URL` (a helper started with `--store` on that copy) are set;
/// `PACER_LAB_E2E_ACCOUNT` picks the account (default: the active one).
@Suite("Lab helper on a real store")
struct LabRealStoreTests {
    static let env = ProcessInfo.processInfo.environment
    static let enabled = env["PACER_LAB_E2E_STORE"] != nil && env["PACER_LAB_E2E_URL"] != nil

    @Test(.enabled(if: enabled)) func thePythonPortOfRecentRateScoresWhatTheBuiltInScores() async throws {
        let storeURL = URL(fileURLWithPath: try #require(Self.env["PACER_LAB_E2E_STORE"]))
        let helperURL = try #require(Self.env["PACER_LAB_E2E_URL"].flatMap(URL.init(string:)))
        let container = try ModelContainer(for: Schema(PacerStore.allModelTypes),
                                           configurations: ModelConfiguration(url: storeURL))
        let account = try #require(Self.env["PACER_LAB_E2E_ACCOUNT"] ?? Account.activeId(in: ModelContext(container)))
        let engine = UsageIntelligenceEngine(modelContainer: container)
        await engine.adopt(scope: .account(account))
        await engine.useLabHelperForTesting(LabHelperClient(baseURL: helperURL),
                                            liveTimeout: .seconds(10), backfillTimeout: .seconds(120))
        let now = Date()
        let started = ContinuousClock.now
        await engine.recompute(now: now)
        let refit = ContinuousClock.now - started
        let added = await engine.backfillRateLimitRecordIfNeeded(now: now, pause: .zero)
        print("[lab e2e] refit \(refit), backfill added \(added) outcome(s) in \(ContinuousClock.now - started - refit)")

        let lab = "lab-recent-rate-py", builtin = "recent-rate"
        let rows = try ModelContext(container).fetch(FetchDescriptor<EngineEvalOutcome>(
            predicate: #Predicate { $0.method == lab || $0.method == builtin }))
        for window in ["five_hour", "seven_day"] {
            let surface = EngineScope.account(account).qualify(EngineSelfEval.rlSurface(window))
            var byKey: [String: [String: Double]] = [:]
            for r in rows where r.surface == surface && EngineSelfEval.isCurrentRLBucket(r.bucket) {
                byKey["\(r.periodKey)|\(r.bucket)", default: [:]][r.method] = r.predicted
            }
            let pairs = byKey.values.compactMap { m -> Double? in
                guard let a = m[lab], let b = m[builtin] else { return nil }
                return abs(a - b)
            }.sorted()
            let labOnly = byKey.values.filter { $0[lab] != nil && $0[builtin] == nil }.count
            let builtinOnly = byKey.values.filter { $0[lab] == nil && $0[builtin] != nil }.count
            guard !pairs.isEmpty else { print("[lab e2e] \(window): no pairs"); continue }
            let agree = Double(pairs.filter { $0 < 0.01 }.count) / Double(pairs.count)
            print("[lab e2e] \(window): \(pairs.count) pairs, \(String(format: "%.1f", agree * 100))% within 0.01 pp, "
                  + "p95 \(String(format: "%.3f", pairs[pairs.count * 95 / 100])) pp, max \(String(format: "%.3f", pairs.last!)) pp; "
                  + "lab-only \(labOnly), built-in-only \(builtinOnly)")
            if pairs.count >= 20 { #expect(agree >= 0.95, "\(window): the port disagrees with the built-in") }
        }
        func summary(_ list: [BurnTrajectory.ScoredTrajectory]) -> String {
            list.map { "\($0.modelId)\($0.isSelected ? "*" : "")=\(String(format: "%.2f", $0.typicalAbsError))" }
                .joined(separator: " ")
        }
        print("[lab e2e] after the first refit: \(summary(await engine.rateLimitTrajectories(windowKey: "five_hour")))")
        await engine.recompute(now: Date())
        let list = await engine.rateLimitTrajectories(windowKey: "five_hour")
        let row = list.first { $0.modelId == lab }
        print("[lab e2e] after the pass: \(summary(list))")
        #expect(row != nil)
        #expect(BurnTrajectory.displayName(lab) == "Latest pace, held (lab)")
    }
}
