import Foundation
import Testing
@testable import PacerCore

@Suite("Walk-forward harness")
struct WalkForwardHarnessTests {

    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func day(_ ymd: String, _ h: Int = 0) -> Date {
        let p = ymd.split(separator: "-").compactMap { Int($0) }
        var dc = DateComponents(); dc.year = p[0]; dc.month = p[1]; dc.day = p[2]; dc.hour = h
        return utc.date(from: dc)!
    }
    private func input(now: Date, soFar: Double) -> ForecastInput {
        ForecastInput(now: now, periodStart: day("2026-05-10"), periodEnd: day("2026-05-11"),
                      calendar: utc, elapsed: [.init(at: now, cumulative: soFar)], priorPeriods: [])
    }

    // Synthetic forecasters with deterministic output.
    private struct Constant: Forecaster { let id: String; let v: Double; let complexity = 0
        func projectTotal(_ i: ForecastInput) -> Double? { v } }
    private struct NilModel: Forecaster { let id = "nil"; let complexity = 0
        func projectTotal(_ i: ForecastInput) -> Double? { nil } }

    // MARK: - per-bucket isolation

    @Test func scoresEachBucketOnItsOwnCases() {
        let inA = input(now: day("2026-05-10", 12), soFar: 50)
        let inB = input(now: day("2026-05-10", 12), soFar: 50)
        // Bucket A: truth 100 (Constant(100) is perfect). Bucket B: truth 200 (Constant 50% low).
        let cases = (0..<10).map { _ in WalkForward.Case(input: inA, truth: 100, bucket: "A") }
                  + (0..<10).map { _ in WalkForward.Case(input: inB, truth: 200, bucket: "B") }
        let scores = WalkForward.score(models: [Constant(id: "c100", v: 100)], cases: cases)
        let a = scores.first { $0.bucket == "A" }!
        let b = scores.first { $0.bucket == "B" }!
        #expect(a.medianAbsPctError == 0)        // 100 vs truth 100
        #expect(abs(b.medianAbsPctError - 50) < 1e-9)   // 100 vs truth 200
        #expect(a.n == 10 && b.n == 10)
        #expect(a.coverage == 1.0)
    }

    @Test func identicalErrorsGiveDegenerateCI() {
        let inp = input(now: day("2026-05-10", 12), soFar: 50)
        let cases = (0..<12).map { _ in WalkForward.Case(input: inp, truth: 100, bucket: "A") }
        let s = WalkForward.score(models: [Constant(id: "c", v: 120)], cases: cases).first!
        #expect(abs(s.medianAbsPctError - 20) < 1e-9)
        #expect(abs(s.ciLow - 20) < 1e-9 && abs(s.ciHigh - 20) < 1e-9)  // no spread → tight CI
    }

    @Test func ciBracketsMedianWithSpread() {
        // Two distinct truths in one bucket → spread of APEs → CI brackets median.
        let inp = input(now: day("2026-05-10", 12), soFar: 50)
        let cases = (0..<15).map { WalkForward.Case(input: inp, truth: $0 % 2 == 0 ? 100 : 150, bucket: "A") }
        let s = WalkForward.score(models: [Constant(id: "c", v: 100)], cases: cases, bootstrap: 2000).first!
        #expect(s.ciLow <= s.medianAbsPctError + 1e-9)
        #expect(s.ciHigh >= s.medianAbsPctError - 1e-9)
        #expect(s.ciLow < s.ciHigh)   // genuine spread
    }

    @Test func coverageDropsWhenModelDeclines() {
        let inp = input(now: day("2026-05-10", 12), soFar: 50)
        let cases = (0..<10).map { _ in WalkForward.Case(input: inp, truth: 100, bucket: "A") }
        let s = WalkForward.score(models: [NilModel()], cases: cases).first!
        #expect(s.coverage == 0)
        #expect(s.n == 0)
    }

    // MARK: - paired

    @Test func pairedFavoursTheCloserModel() {
        let inp = input(now: day("2026-05-10", 12), soFar: 50)
        let cases = (0..<10).map { _ in WalkForward.Case(input: inp, truth: 100, bucket: "A") }
        // model 105 (5% off) vs baseline 130 (30% off): model strictly closer everywhere.
        let p = WalkForward.paired(model: Constant(id: "m", v: 105),
                                   baseline: Constant(id: "b", v: 130), cases: cases).first!
        #expect(p.winFraction == 1.0)
        #expect(p.medianDelta < 0)          // model APE − baseline APE < 0 ⇒ model better
        #expect(p.ciHigh < 0)               // CI entirely below zero ⇒ decisive
        #expect(p.n == 10)
    }

    // MARK: - case builder

    @Test func caseBuilderTagsCutAndRegimeAndRespectsHistory() {
        // Two prior "days", each a flat cumulative ramp to a known total.
        func ramp(_ ymd: String, total: Double) -> ForecastInput.PriorPeriod {
            var cum = 0.0
            let pts = (0..<24).map { h -> ForecastInput.Point in
                cum += total / 24
                return .init(at: day(ymd, h).addingTimeInterval(3599), cumulative: cum)
            }
            return .init(start: day(ymd), points: pts)
        }
        let periods = [ramp("2026-05-01", total: 90), ramp("2026-05-02", total: 120)]
        let cases = WalkForward.cases(
            periods: periods,
            periodEnd: { $0.start.addingTimeInterval(86400) },
            cutFractions: [0.5],
            calendar: utc,
            regime: { self.utc.component(.day, from: $0.periodStart) == 1 ? "first" : "second" })

        #expect(cases.count == 2)   // one cut per period
        #expect(cases.contains { $0.bucket == "cut=0.50|first" })
        #expect(cases.contains { $0.bucket == "cut=0.50|second" })
        // Truth = each period's realized total.
        let first = cases.first { $0.bucket.hasSuffix("first") }!
        #expect(abs(first.truth - 90) < 1e-6)
        // The earliest period sees no priors; the second sees one.
        #expect(first.input.priorPeriods.isEmpty)
        let second = cases.first { $0.bucket.hasSuffix("second") }!
        #expect(second.input.priorPeriods.count == 1)
        // At cut 0.5 (noon), ~half the ramp is observed.
        #expect(abs(first.input.soFar - 45) < 90.0 / 24)
    }
}
