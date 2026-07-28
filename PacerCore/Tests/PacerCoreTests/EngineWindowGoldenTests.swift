import Foundation
import Testing
@testable import PacerCore

/// Golden-fixture identity gate for the generic window driver.
///
/// The rate-limit engine was generalized from a hard `RateLimitWindowKind`
/// pair to a `WindowSpec`-driven set so scoped per-model windows forecast
/// through the same path. This test pins the fixed 5h/7d output — selection,
/// duration, cycle facts, stratified conformal bands, the end-at-reset
/// `Estimate`, the burn crossing/slope, and the selected trajectory — from a
/// fully deterministic fixture, so any future change that moves the fixed
/// windows fails loudly. The pre-refactor tree produced this exact
/// serialization (verified by a stash/replay before/after diff during the
/// refactor), so it is a genuine "unchanged" gate, not just a snapshot.
struct EngineWindowGoldenTests {

    static let utc = Calendar(identifier: .gregorian).with(timeZone: TimeZone(identifier: "UTC")!)
    static let now = Date(timeIntervalSince1970: 1_752_000_000)

    /// Deterministic ramp cycles for one window: `completed` prior cycles plus a
    /// live one, each ramping 0 → peak, sampled every `stepH` hours.
    static func rows(window: String, duration: TimeInterval, completed: Int,
                     stepH: Double, peak: Double, perStep: Double) -> [EngineFeatures.RateRow] {
        var rate: [EngineFeatures.RateRow] = []
        for c in 0...completed {
            let cycleStart = now.addingTimeInterval(-Double(completed - c) * duration - duration * 0.5)
            let resetsAt = cycleStart.addingTimeInterval(duration)
            var t = cycleStart
            var pct = 0.0
            while t <= min(resetsAt, now) {
                rate.append(.init(window: window, at: t, usedPercentage: min(peak, pct), resetsAt: resetsAt))
                t = t.addingTimeInterval(stepH * 3600)
                pct += perStep
            }
        }
        return rate
    }

    static func fixtureFeatures() -> EngineFeatures {
        var rate: [EngineFeatures.RateRow] = []
        rate += rows(window: "five_hour", duration: 5 * 3600, completed: 12, stepH: 0.25, peak: 82, perStep: 5.5)
        rate += rows(window: "seven_day", duration: 7 * 86400, completed: 6, stepH: 6, peak: 61, perStep: 2.2)
        return EngineFeatures.build(now: now, calendar: utc, daily: [], hourly: [], rate: rate, lastArrivalAt: nil)
    }

    static func f2(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "-" }
        return String(format: "%.4f", v)
    }
    static func rng(_ r: ClosedRange<Double>?) -> String {
        guard let r else { return "nil" }
        return "\(f2(r.lowerBound))...\(f2(r.upperBound))"
    }
    static func rel(_ d: Date?) -> String {
        guard let d else { return "nil" }
        return String(format: "%.1f", d.timeIntervalSince(now) / 60)  // minutes from now
    }

    static func serialize() -> String {
        let f = fixtureFeatures()
        let fit = UsageIntelligenceEngine.makeFit(f)
        var lines: [String] = []
        for (key, kind) in [("five_hour", RateLimitWindowKind.fiveHour), ("seven_day", .sevenDay)] {
            lines.append("== \(key) ==")
            if let rf = fit.rl[key] {
                lines.append("selectedId=\(rf.selectedId ?? "nil") duration=\(f2(rf.duration)) history=\(rf.historyCount)")
                lines.append("cycles obs=\(rf.cyclesObserved) over90=\(rf.cyclesPeakOver90) hit100=\(rf.cyclesHit100)")
                for ck in rf.calibrators.keys.sorted() {
                    let cal = rf.calibrators[ck]!
                    lines.append("cal[\(ck)] n=\(cal.count) q10=\(f2(cal.quantile(0.1))) q50=\(f2(cal.quantile(0.5))) q90=\(f2(cal.quantile(0.9)))")
                }
            } else {
                lines.append("no fit")
            }
            let est = UsageIntelligenceEngine.answer(.rateLimitOutlook(kind), features: f, fit: fit)
            lines.append("outlook value=\(f2(est.isInsufficient ? nil : est.value)) i80=\(rng(est.interval80)) i50=\(rng(est.interval50)) conf=\(est.confidence.rawValue) support=\(est.support) method=\(est.method) note=\(est.note ?? "-")")
            if let o = UsageIntelligenceEngine.burnOutlook(f, fit, windowKey: key) {
                lines.append("burn used=\(f2(o.usedPct)) slope=\(f2(o.slopePercentPerHour)) cross=\(rel(o.projectedFullAt)) early=\(rel(o.projectedFullAtEarliest)) late=\(rel(o.projectedFullAtLatest)) anchor=\(f2(o.anchorShift)) method=\(o.method)")
            } else {
                lines.append("burn nil")
            }
            let traj = UsageIntelligenceEngine.rateLimitTrajectories(f, fit, windowKey: key, accuracy: nil, sampleCount: 24)
            let sel = traj.first { $0.isSelected }
            lines.append("traj n=\(traj.count) selected=\(sel?.modelId ?? "-") pts=\(sel?.trajectory.points.count ?? 0) cross=\(rel(sel?.trajectory.crossesFullAt)) last=\(f2(sel?.trajectory.points.last?.usedPercentage))")
        }
        return lines.joined(separator: "\n")
    }

    static let golden = """
    == five_hour ==
    selectedId=saturating duration=18000.0000 history=12
    cycles obs=12 over90=0 hit100=0
    cal[pooled] n=12 q10=-6.0472 q50=-6.0472 q90=-6.0472
    outlook value=87.4769 i80=81.4297...81.4297 i50=81.4297...81.4297 conf=medium support=12 method=rl-saturating note=-
    burn used=55.0000 slope=22.0000 cross=nil early=nil late=nil anchor=2.4050 method=saturating
    traj n=6 selected=saturating pts=25 cross=nil last=87.4769
    == seven_day ==
    selectedId=linear-recent duration=604800.0000 history=6
    cycles obs=6 over90=0 hit100=0
    cal[pooled] n=6 q10=-0.6000 q50=-0.6000 q90=-0.6000
    outlook value=61.6000 i80=nil i50=nil conf=medium support=6 method=rl-linear-recent note=-
    burn used=30.8000 slope=0.3667 cross=nil early=nil late=nil anchor=0.0000 method=linear-recent
    traj n=6 selected=linear-recent pts=25 cross=nil last=61.6000
    """

    @Test func fixedWindowsAreByteIdenticalToPreRefactor() {
        // Fixed 5h/7d output must exactly match the pre-refactor engine.
        #expect(Self.serialize() == Self.golden)
    }
}

private extension Calendar {
    func with(timeZone: TimeZone) -> Calendar { var c = self; c.timeZone = timeZone; return c }
}
