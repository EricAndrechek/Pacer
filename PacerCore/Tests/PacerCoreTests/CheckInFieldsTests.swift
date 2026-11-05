import Foundation
import Testing
@testable import PacerCore

@Suite struct CheckInFieldsTests {
    @Test func plansAreSortedDistinctAndUnprefixed() {
        #expect(CheckInFields.plans(tiers: []) == "none")
        #expect(CheckInFields.plans(tiers: ["default_claude_max_20x"]) == "max_20x")
        #expect(CheckInFields.plans(tiers: ["default_claude_max_20x", "default_claude_max_5x", "default_claude_max_20x"])
                == "max_20x+max_5x")
        #expect(CheckInFields.plans(tiers: ["unknown", "default_claude_pro"]) == "pro+unknown")
    }

    @Test func fiveHourGatingStaysIntact() {
        // One account: its own flag.
        #expect(!CheckInFields.reportsFiveHour(scopedHasNoFiveHour: true, allHaveNoFiveHour: [true, false], scopedToAccount: true))
        #expect(CheckInFields.reportsFiveHour(scopedHasNoFiveHour: false, allHaveNoFiveHour: [true, false], scopedToAccount: true))
        #expect(CheckInFields.reportsFiveHour(scopedHasNoFiveHour: nil, allHaveNoFiveHour: [], scopedToAccount: true))
        // All accounts: only when every one lacks it is it dropped.
        #expect(CheckInFields.reportsFiveHour(scopedHasNoFiveHour: nil, allHaveNoFiveHour: [true, false], scopedToAccount: false))
        #expect(!CheckInFields.reportsFiveHour(scopedHasNoFiveHour: nil, allHaveNoFiveHour: [true, true], scopedToAccount: false))
        #expect(CheckInFields.reportsFiveHour(scopedHasNoFiveHour: nil, allHaveNoFiveHour: [], scopedToAccount: false))
    }

    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func date(_ s: String) -> Date { CheckInFields.parse(s, calendar: utc)! }

    @Test func installDateBackfillRule() {
        let now = date("2026-11-03")
        // Stored wins, nothing to save.
        var r = CheckInFields.installFirstSeen(stored: "2026-05-01", earliestEvidence: date("2026-01-01"), now: now, calendar: utc)
        #expect(r.day == "2026-05-01" && !r.save)
        // No stored value: earliest evidence, saved.
        r = CheckInFields.installFirstSeen(stored: nil, earliestEvidence: date("2026-02-14"), now: now, calendar: utc)
        #expect(r.day == "2026-02-14" && r.save)
        // Garbage stored value is replaced.
        r = CheckInFields.installFirstSeen(stored: "nope", earliestEvidence: nil, now: now, calendar: utc)
        #expect(r.day == "2026-11-03" && r.save)
        // Evidence from the future (clock skew) is capped at now.
        r = CheckInFields.installFirstSeen(stored: nil, earliestEvidence: date("2027-01-01"), now: now, calendar: utc)
        #expect(r.day == "2026-11-03")
    }

    @Test func installAge() {
        let now = date("2026-11-03").addingTimeInterval(3600 * 15)
        #expect(CheckInFields.installAgeDays(firstSeen: "2026-11-03", now: now, calendar: utc) == 0)
        #expect(CheckInFields.installAgeDays(firstSeen: "2026-10-04", now: now, calendar: utc) == 30)
        #expect(CheckInFields.installAgeDays(firstSeen: "2027-01-01", now: now, calendar: utc) == 0)
    }
}

@Suite struct MacModelNameTests {
    @Test func knownAndUnknown() {
        #expect(MacModelName.name(for: "Mac16,7") == "MacBook Pro 16-inch (M4 Pro, 2024)")
        #expect(MacModelName.name(for: "Mac16,8") == "MacBook Pro 14-inch (M4 Pro, 2024)")
        #expect(MacModelName.name(for: "Mac99,1") == "Mac99,1")
        #expect(MacModelName.name(for: "unknown") == "unknown")
    }
}

@Suite struct ArenaPassTelemetryTests {
    @Test func passThatGradedNothingReportsNothing() {
        // The incremental pass every 15 minutes: cycles visited, all models
        // already graded. This used to send two zero distributions.
        var r = ArenaRecordScorer.Report()
        r.cycles = 12
        #expect(ArenaRecordScorer.passMetrics(r) == nil)
    }

    @Test func passThatGradedReportsItsTotals() {
        var r = ArenaRecordScorer.Report()
        r.cycles = 3; r.forecasts = 5; r.busySeconds = 12.5
        r.modelSeconds = ["a": 2, "b": 9]
        r.modelCPUSeconds = ["a": 1, "b": 3]
        let m = ArenaRecordScorer.passMetrics(r)
        #expect(m?.passSeconds == 12.5)
        #expect(m?.cpuSeconds == 4)
        #expect(m?.modelsGraded == 2)
        #expect(m?.slowestModel == "b")
    }

    @Test func cpuModeNames() {
        #expect(ArenaBudgetPolicy.telemetryName(.fullCore) == "full")
        #expect(ArenaBudgetPolicy.telemetryName(.share(.battery)) == "fifth")
    }
}

/// The check-in goes once a local day, and again on the day a new release
/// first runs, so its adoption shows that day.
@Suite("Check-in schedule")
struct CheckInScheduleTests {

    private let release = "com.ericandrechek.pacer@0.8.3+1"

    @Test("a new day is due; the same day on the same release is not")
    func daily() {
        #expect(CheckInSchedule.due(lastDay: "2026-11-04", lastRelease: release,
                                    today: "2026-11-05", release: release) == .day)
        #expect(CheckInSchedule.due(lastDay: "2026-11-05", lastRelease: release,
                                    today: "2026-11-05", release: release) == nil)
    }

    @Test("a new release the same day is due again, once")
    func newRelease() {
        let old = "com.ericandrechek.pacer@0.8.2+1"
        #expect(CheckInSchedule.due(lastDay: "2026-11-05", lastRelease: old,
                                    today: "2026-11-05", release: release) == .version)
        // Both are stored together before the work, so the next look finds nothing due.
        #expect(CheckInSchedule.due(lastDay: "2026-11-05", lastRelease: release,
                                    today: "2026-11-05", release: release) == nil)
    }

    @Test("a first run is a day check-in; an update from before the release key is a version one")
    func missingKeys() {
        #expect(CheckInSchedule.due(lastDay: nil, lastRelease: nil,
                                    today: "2026-11-05", release: release) == .day)
        #expect(CheckInSchedule.due(lastDay: "2026-11-05", lastRelease: nil,
                                    today: "2026-11-05", release: release) == .version)
    }

    @Test("a new day on a new release is a day check-in")
    func dayWins() {
        #expect(CheckInSchedule.due(lastDay: "2026-11-04", lastRelease: "x",
                                    today: "2026-11-05", release: release) == .day)
    }
}
