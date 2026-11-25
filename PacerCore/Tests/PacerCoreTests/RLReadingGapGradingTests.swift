import Foundation
import Testing
import SwiftData
@testable import PacerCore

/// Grading and calibration only where the readings show the meter (#424). A
/// cut inside a gap in the readings (`ReadingCoverage.maxGap`) is a moment
/// nobody was reading: it is not graded, it feeds no residual, and what the
/// record held there before is taken out of it. A cycle whose readings
/// stopped before its reset is still graded against its highest reading:
/// measured, the meter seldom moves while nothing reads it, and dropping
/// those cycles made every forecast worse (`BurnTrajectory.Cycle.gradedFinal`).
@Suite("Rate-limit grading across reading gaps")
struct RLReadingGapGradingTests {

    static let utc = Calendar(identifier: .gregorian).with(timeZone: TimeZone(identifier: "UTC")!)
    static let week: TimeInterval = 7 * 86400
    static let start = Date(timeIntervalSince1970: 1_752_000_000)
    static let grid = Array(repeating: Array(repeating: 1.0, count: 24), count: 7)

    /// A weekly cycle read every 10 minutes, climbing 0.3 points an hour,
    /// with no reading inside `gap` (hours into the cycle) and none after
    /// `stop` hours.
    static func cycle(_ index: Int = 0, gap: ClosedRange<Double>? = nil, stop: Double = 168) -> BurnTrajectory.Cycle {
        let s = start.addingTimeInterval(Double(index) * week)
        var samples: [BurnTrajectory.Sample] = []
        for k in 0...(168 * 6) {
            let h = Double(k) / 6
            if let gap, gap.contains(h), h != gap.lowerBound, h != gap.upperBound { continue }
            if h > stop { break }
            samples.append(.init(at: s.addingTimeInterval(h * 3600), usedPercentage: (h * 0.3 * 10).rounded() / 10))
        }
        return .init(samples: samples, cycleStart: s, resetsAt: s.addingTimeInterval(week))
    }

    static func grades(_ cycles: [BurnTrajectory.Cycle]) -> [EngineSelfEval.NewOutcome] {
        EngineSelfEval.newOutcomesRL(window: "seven_day", cycles: cycles, activityGrid: grid, calendar: utc,
                                     existingKeys: [], includeDiurnal: true)
    }

    // MARK: Cuts

    /// A six-hour gap from hour 40 to 46: cut 0.25 (hour 42) is inside it,
    /// two hours after the last reading. No model is graded there; every
    /// other cut is.
    @Test func aCutInsideASixHourGapHasNoGrade() throws {
        let gappy = Self.cycle(gap: 40...46)
        let cutInGap = Self.start.addingTimeInterval(Self.week * 0.25)
        #expect(gappy.gradedReadings(at: cutInGap) == nil)
        #expect(gappy.gradedCuts(EngineSelfEval.rlGrading.cuts).count == EngineSelfEval.rlGrading.cuts.count - 1)

        let out = Self.grades([gappy])
        let buckets = Set(out.map(\.bucket))
        #expect(!buckets.contains(EngineSelfEval.rlBucket(0.25)))
        #expect(buckets == Set(EngineSelfEval.rlGrading.cuts.filter { $0 != 0.25 }.map(EngineSelfEval.rlBucket)))
        // The calibrator's walk skips it the same way.
        let model = BurnTrajectory.LinearRecent()
        let cal = UsageIntelligenceEngine.stratifiedRLCalibrators(
            model: model, history: [gappy], duration: Self.week, calendar: Self.utc)
        let bandCuts = EngineSelfEval.rlGrading.cuts.filter { UsageIntelligenceEngine.isBandCut($0) && $0 != 0.25 }
        // One cycle: the block rule makes it one median residual.
        #expect(cal["pooled"]?.count == 1)
        #expect(bandCuts.count == 8)
    }

    /// A reading 30 minutes before the cut still shows it; one more second
    /// does not.
    @Test func theCutRuleIsTheGapRule() {
        let s = Self.start, reset = s.addingTimeInterval(5 * 3600)
        let samples = [0.0, 300, 600, 900].map { BurnTrajectory.Sample(at: s.addingTimeInterval($0), usedPercentage: $0 / 300) }
        let c = BurnTrajectory.Cycle(samples: samples + [.init(at: reset, usedPercentage: 9)], cycleStart: s, resetsAt: reset)
        #expect(c.gradedReadings(at: s.addingTimeInterval(900 + 1800))?.count == 4)
        #expect(c.gradedReadings(at: s.addingTimeInterval(900 + 1801)) == nil)
        #expect(c.gradedReadings(at: s.addingTimeInterval(599)) == nil)     // three readings at least, as before
    }

    // MARK: An end nobody read

    /// Readings that stop two hours before the reset: the cuts before then
    /// are graded against the highest reading, as before; only the last cut,
    /// inside those two hours, is not.
    @Test func anEndNobodyReadIsGradedAgainstItsLastReading() {
        let unread = Self.cycle(stop: 166)
        #expect(unread.gradedFinal == unread.final)
        let cuts = EngineSelfEval.rlGrading.cuts
        // Cut 0.925 is hour 155.4, read; none falls in the last two hours.
        #expect(unread.gradedCuts(cuts) == cuts)
        let stopsEarlier = Self.cycle(stop: 150)
        #expect(stopsEarlier.gradedCuts(cuts) == cuts.filter { $0 != 0.925 })
        #expect(Self.grades([stopsEarlier]).allSatisfy { $0.truth == stopsEarlier.final })
        #expect(!Self.grades([stopsEarlier]).contains { $0.bucket == EngineSelfEval.rlBucket(0.925) })
        // Nothing used: nothing to grade against.
        let idle = BurnTrajectory.Cycle(samples: unread.samples.map { .init(at: $0.at, usedPercentage: 0) },
                                        cycleStart: unread.cycleStart, resetsAt: unread.resetsAt)
        #expect(idle.gradedFinal == nil && idle.gradedCuts(cuts).isEmpty)
    }

    /// The cold backtest reads the same rule: a cut inside a gap is not a
    /// case.
    @Test func theColdBacktestSkipsCutsInsideAGap() {
        let gappy = Self.cycle(gap: 80...90)    // cut 0.5 is hour 84
        let clean = Self.cycle()
        let m: [any BurnTrajectory.Model] = [BurnTrajectory.LinearRecent()]
        let g = BurnTrajectory.score(models: m, cycles: [gappy], cutFractions: [0.5, 0.6])
        let c = BurnTrajectory.score(models: m, cycles: [clean], cutFractions: [0.5, 0.6])
        #expect(g.first?.scoredCount == 1)
        #expect(c.first?.scoredCount == 2)
    }

    // MARK: Clean cycles

    /// A cycle read throughout is graded exactly as before the rule: every
    /// cut, every model, the same values.
    @Test func aCleanCyclesGradesAreUnchanged() throws {
        let prior = Self.cycle(0), clean = Self.cycle(1)
        let out = Self.grades([prior, clean]).filter { $0.periodKey == EngineSelfEval.periodKeyRL(clean.resetsAt) }
        // What the grader did before #424, for this cycle.
        var roster = BurnTrajectory.defaultModels
        roster.append(DiurnalBurnModel(rate: DiurnalBurnModel.rateTable(cycles: [prior], calendar: Self.utc, prior: Self.grid),
                                       calendar: Self.utc))
        var expected: [String: Double] = [:]
        for cf in EngineSelfEval.rlGrading.cuts {
            let now = clean.cycleStart.addingTimeInterval(Self.week * cf)
            let seen = clean.samples.filter { $0.at <= now }
            guard seen.count >= 3 else { continue }
            let partial = BurnTrajectory.PartialCycle(samples: seen, now: now, cycleStart: clean.cycleStart,
                                                      resetsAt: clean.resetsAt)
            for m in roster {
                guard let p = m.fit(partial) else { continue }
                expected["\(m.id)|\(EngineSelfEval.rlBucket(cf))"] = BurnTrajectory.displayedAtReset(p, partial: partial)
            }
        }
        let got = Dictionary(uniqueKeysWithValues: out.map { ("\($0.method)|\($0.bucket)", $0.predicted) })
        #expect(!expected.isEmpty)
        #expect(got == expected)
        #expect(out.allSatisfy { $0.truth == clean.final })
        #expect(EngineSelfEval.ungradedBuckets(clean, gradings: [EngineSelfEval.rlGrading]).isEmpty)
    }

    // MARK: The stored record

    static let account = "org-gaps"
    static let now = start.addingTimeInterval(3 * week + 3600)

    /// Three weekly cycles in the live table: clean, one with a six-hour gap
    /// over cut 0.25, one whose readings stop at hour 150 (cut 0.925 is 155.4).
    /// Each carries rows graded before the rule, for an engine method and an
    /// arena model, at cuts 0.25, 0.55 and 0.925.
    static func seeded() throws -> (ModelContainer, [BurnTrajectory.Cycle]) {
        let container = try PacerStore.makeInMemoryContainer()
        let ctx = ModelContext(container)
        ctx.insert(Account(id: account, organizationId: account, displayName: "A", isActive: true,
                           firstSeenAt: start.addingTimeInterval(-86400), lastSeenAt: now))
        let cycles = [cycle(0), cycle(1, gap: 40...46), cycle(2, stop: 150)]
        // And the live cycle, an hour in: the newest reset is the current
        // cycle, never graded.
        for c in cycles + [cycle(3, stop: 1)] {
            for s in c.samples {
                ctx.insert(RateLimitSample(sampledAt: s.at, window: "seven_day", usedPercentage: s.usedPercentage,
                                           resetsAt: c.resetsAt, source: "oauth", accountId: account))
            }
        }
        let surface = EngineScope.account(account).qualify(EngineSelfEval.rlSurface("seven_day"))
        for c in cycles {
            for method in ["linear-recent", "arena-model"] {
                for cf in [0.25, 0.55, 0.925] {
                    ctx.insert(EngineEvalOutcome(surface: surface, method: method, bucket: EngineSelfEval.rlBucket(cf),
                                                 periodKey: EngineSelfEval.periodKeyRL(c.resetsAt), predicted: 40,
                                                 truth: c.final, recordedAt: start, inputs: "m0", reading: 10))
                }
            }
        }
        try ctx.save()
        return (container, cycles)
    }

    static func ungradedRows(_ container: ModelContainer, _ cycles: [BurnTrajectory.Cycle]) throws -> [EngineEvalOutcome] {
        let gappy = EngineSelfEval.periodKeyRL(cycles[1].resetsAt), unread = EngineSelfEval.periodKeyRL(cycles[2].resetsAt)
        return try ModelContext(container).fetch(FetchDescriptor<EngineEvalOutcome>()).filter {
            ($0.periodKey == gappy && $0.bucket == EngineSelfEval.rlBucket(0.25))
                || ($0.periodKey == unread && $0.bucket == EngineSelfEval.rlBucket(0.925))
        }
    }

    static func marker(_ container: ModelContainer) throws -> String? {
        try ModelContext(container).fetch(FetchDescriptor<ClaudeCodeMeta>())
            .first { $0.key == "rl_record_backfill|\(Self.account)" }?.value
    }

    /// The full-history pass takes out every row the rule leaves without a
    /// grade, the arena's too, and keeps the rest; the engine's grade at the
    /// clean cut is graded again in place.
    @Test func theRecordLosesWhatHasNoGradeAndKeepsTheRest() async throws {
        let (container, cycles) = try Self.seeded()
        let engine = UsageIntelligenceEngine(modelContainer: container)
        await engine.adopt(scope: .account(Self.account))
        _ = await engine.backfillRateLimitRecordIfNeeded(now: Self.now, calendar: Self.utc, pause: .zero)
        await engine.settleRecordCleanup()

        let rows = try ModelContext(container).fetch(FetchDescriptor<EngineEvalOutcome>())
            .filter { $0.surface.hasPrefix(EngineSelfEval.rlSurface("seven_day")) }
        func has(_ c: BurnTrajectory.Cycle, _ method: String, _ cf: Double) -> Bool {
            rows.contains { $0.periodKey == EngineSelfEval.periodKeyRL(c.resetsAt) && $0.method == method
                && $0.bucket == EngineSelfEval.rlBucket(cf) }
        }
        let (clean, gappy, unread) = (cycles[0], cycles[1], cycles[2])
        for method in ["linear-recent", "arena-model"] {
            #expect(has(clean, method, 0.25) && has(clean, method, 0.55) && has(clean, method, 0.925))
            #expect(!has(gappy, method, 0.25))                    // inside the gap
            #expect(has(gappy, method, 0.55))                     // read again by then
            #expect(has(unread, method, 0.55))                    // read then; graded against the last reading
            #expect(!has(unread, method, 0.925))                  // after the readings stopped
        }
        // The engine's own rows were graded again with the current inputs;
        // the arena's are left as the arena graded them.
        let engineRow = rows.first { $0.periodKey == EngineSelfEval.periodKeyRL(clean.resetsAt)
            && $0.method == "linear-recent" && $0.bucket == EngineSelfEval.rlBucket(0.25) }
        #expect(engineRow?.inputs == RateLimitRoster.engineInputs("linear-recent"))
        #expect(rows.first { $0.method == "arena-model" && $0.periodKey == EngineSelfEval.periodKeyRL(clean.resetsAt) }?
            .inputs == "m0")
    }

    /// The marker that says the record is done is saved only after the
    /// ungraded rows' delete has committed: when the pass returns, both are
    /// in the store, with no wait on the background delete. Saved before it,
    /// a quit in between left the rows for good, since the next launch skips
    /// the pass.
    @Test func theMarkerIsSavedOnlyOnceTheDeleteHasCommitted() async throws {
        let (container, cycles) = try Self.seeded()
        #expect(try Self.ungradedRows(container, cycles).count == 4)
        let engine = UsageIntelligenceEngine(modelContainer: container)
        await engine.adopt(scope: .account(Self.account))
        _ = await engine.backfillRateLimitRecordIfNeeded(now: Self.now, calendar: Self.utc, pause: .zero)
        #expect(try Self.marker(container) == UsageIntelligenceEngine.recordBackfillFingerprint)
        #expect(try Self.ungradedRows(container, cycles).isEmpty)
    }

    /// A pass cut short (a quit, a crash, a relaunch) leaves its marker
    /// unsaved, the way an earlier build's marker is: the next launch runs it
    /// again and takes out what the first one did not get to.
    @Test func aPassCutShortRunsAgainNextLaunch() async throws {
        let (container, cycles) = try Self.seeded()
        let ctx = ModelContext(container)
        ctx.insert(ClaudeCodeMeta(key: "rl_record_backfill|\(Self.account)", value: "v3|older"))
        try ctx.save()
        let engine = UsageIntelligenceEngine(modelContainer: container)
        await engine.adopt(scope: .account(Self.account))
        _ = await engine.backfillRateLimitRecordIfNeeded(now: Self.now, calendar: Self.utc, pause: .zero)
        #expect(try Self.ungradedRows(container, cycles).isEmpty)
        #expect(try Self.marker(container) == UsageIntelligenceEngine.recordBackfillFingerprint)
    }
}

private extension Calendar {
    func with(timeZone: TimeZone) -> Calendar { var c = self; c.timeZone = timeZone; return c }
}
