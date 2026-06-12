import Foundation
import PacerCore
import PacerUI

/// Shared presentation rules for engine answers, used by every card that
/// renders a forecast (Today tile, live activity, monthly, pace charts,
/// advisor). One home so the dashboard speaks one language:
/// 2-significant-figure forecast rounding, outward-rounded bands, asymmetric
/// anchors, natural-frequency risk copy, and the display gate that decides
/// when a dollar range is worth showing at all.
enum IntelligenceFormatting {

    // MARK: - Rounding (displayed precision must not exceed measured skill)

    /// Forecast value at 2 significant figures, house-compact ("≈" reads
    /// better next to the label than inside the string, so callers add it).
    static func approxCost(_ v: Double) -> String {
        pacerCost(roundSig(v, up: nil))
    }

    /// Bands round OUTWARD so the printed range is never narrower than the
    /// calibrated one.
    static func outward(_ r: ClosedRange<Double>) -> ClosedRange<Double> {
        let lo = roundSig(r.lowerBound, up: false)
        let hi = roundSig(r.upperBound, up: true)
        return min(lo, hi)...max(lo, hi)
    }

    static func costRange(_ r: ClosedRange<Double>) -> String {
        "\(pacerCost(r.lowerBound))–\(pacerCost(r.upperBound))"
    }

    static func roundSig(_ v: Double, up: Bool?) -> Double {
        guard v > 0 else { return v }
        let mag = pow(10, floor(log10(v)) - 1)
        let scaled = v / mag
        let r: Double
        switch up {
        case .some(true):  r = scaled.rounded(.up)
        case .some(false): r = scaled.rounded(.down)
        case .none:        r = scaled.rounded()
        }
        return r * mag
    }

    // MARK: - The display gate

    /// A dollar range is decision-useful once at least half the day is
    /// observed AND the 80% band is no wider than ~2.5× the point. Before
    /// that, surfaces show pace-vs-normal instead of a projection.
    ///
    /// `spendSoFar` is the caller's LIVE spend figure: the engine refits up
    /// to ~20s behind the rollups, so right after a burst its projection can
    /// momentarily sit below the money already on screen — and a "projected
    /// $77" under a "$124 so far" reads broken, full stop. Suppress rather
    /// than display an internally inconsistent pair.
    ///
    /// Screenshot mode pins the evening state so the README shows the full
    /// experience.
    static func rangeIsActionable(_ e: Estimate, spendSoFar: Double = 0) -> Bool {
        guard !e.isInsufficient, let band = e.interval80, e.value > 0 else { return false }
        guard e.value >= spendSoFar * 0.98 else { return false }
        let isScreenshot = ProcessInfo.processInfo.environment["PACER_SCREENSHOT_MODE"] == "1"
        let fractionOfDay = isScreenshot ? 0.8
            : Date().timeIntervalSince(Calendar.current.startOfDay(for: Date())) / 86400
        let widthRatio = (band.upperBound - band.lowerBound) / e.value
        return fractionOfDay >= 0.5 && widthRatio <= 2.5
    }

    /// "at least $480 · could reach $1.9k on a heavy day" — asymmetric
    /// anchors, never a bare symmetric interval.
    static func anchors(_ band: ClosedRange<Double>) -> String {
        let b = outward(band)
        return "at least \(approxCost(b.lowerBound)) · could reach \(approxCost(b.upperBound)) on a heavy day"
    }

    // MARK: - Pace ladder

    /// Five-step pace label from the engine's percentile answer. Pure —
    /// callers that show it persistently should hold the index behind
    /// hysteresis (`heldIndex`).
    static func ladderIndex(_ percentile: Double) -> Int {
        [0.25, 0.60, 0.85, 0.95].filter { percentile >= $0 }.count
    }

    /// Hysteresis: near a boundary (±10 points), keep the previously held
    /// index so the label can't flap intra-day.
    static func heldIndex(_ percentile: Double, held: Int?) -> Int {
        let bounds = [0.25, 0.60, 0.85, 0.95]
        let idx = ladderIndex(percentile)
        if let held, let nearest = bounds.min(by: { abs($0 - percentile) < abs($1 - percentile) }),
           abs(percentile - nearest) < 0.10 {
            return held
        }
        return idx
    }

    /// Pace-framed copy (safe at any time of day).
    static func paceLabel(index: Int, dayName: String) -> String {
        switch index {
        case 0:  return "a quiet \(dayName) so far"
        case 1:  return "tracking a typical \(dayName)"
        case 2:  return "ahead of your usual \(dayName)"
        case 3:  return "one of your heavier days"
        default: return "your heaviest pace in weeks"
        }
    }

    // MARK: - Rate-limit copy

    /// "topped 90% in 3 of 73 cycles · capped 1×" — natural-frequency risk,
    /// never a fitted probability; never "0%" from a short record.
    static func frequencyLine(_ o: UsageIntelligenceEngine.BurnOutlook) -> String? {
        guard o.cyclesObserved >= 5 else { return nil }
        let top = o.cyclesPeakOver90 == 0
            ? "never topped 90% in \(o.cyclesObserved) cycles"
            : "topped 90% in \(o.cyclesPeakOver90) of \(o.cyclesObserved) cycles"
        let cap = o.cyclesHit100 == 0 ? "never capped" : "capped \(o.cyclesHit100)×"
        return "\(top) · \(cap)"
    }

    /// The crossing as window-scaled copy: same-day → clock time, later →
    /// weekday + day-part; with the earliest–latest range when it's tight
    /// enough to be meaningful.
    static func crossingPhrase(_ o: UsageIntelligenceEngine.BurnOutlook) -> String? {
        guard let hit = o.projectedFullAt else { return nil }
        let point = hit.timeIntervalSinceNow < 22 * 3600
            ? "around \(hit.formatted(.dateTime.hour()))"
            : "\(hit.formatted(.dateTime.weekday(.abbreviated))) \(dayPart(hit))"
        if let early = o.projectedFullAtEarliest, let late = o.projectedFullAtLatest,
           late.timeIntervalSince(early) < 12 * 3600,
           early.timeIntervalSinceNow < 22 * 3600, late.timeIntervalSinceNow < 22 * 3600 {
            return "→ cap \(early.formatted(.dateTime.hour()))–\(late.formatted(.dateTime.hour()))"
        }
        return "→ cap \(point)"
    }

    /// Burn rate framed against the **sustainable pace** — the rate you could
    /// hold and exactly NOT hit the cap before the window resets (100% ÷
    /// window length). Raw "%/hr" means nothing without that referent:
    /// +13%/hr is leisurely for a 5-hour window (sustainable 20%/hr) and a
    /// blowout for a 7-day one (sustainable ~0.6%/hr). Number + referent:
    /// "0.3× sustainable pace".
    static func capPaceLabel(slopePercentPerHour slope: Double, windowSeconds: TimeInterval) -> String? {
        let ratio = capPaceRatio(slopePercentPerHour: slope, windowSeconds: windowSeconds)
        guard ratio >= 0.05 else { return nil }          // effectively idle — say nothing
        return "\(multiple(ratio)) sustainable pace"
    }

    static func capPaceRatio(slopePercentPerHour slope: Double, windowSeconds: TimeInterval) -> Double {
        let capPace = 100.0 / (windowSeconds / 3600)
        return capPace > 0 ? slope / capPace : 0
    }

    /// "0.3×" / "1.8×" / "12×" — one decimal below ten, whole above.
    static func multiple(_ ratio: Double) -> String {
        ratio >= 10 ? String(format: "%.0f×", ratio) : String(format: "%.1f×", ratio)
    }

    /// Tooltip companion for `capPaceLabel` — the raw numbers, for anyone who
    /// wants them.
    static func capPaceHelp(slopePercentPerHour slope: Double, windowSeconds: TimeInterval) -> String {
        let capPace = 100.0 / (windowSeconds / 3600)
        return String(format: "burning %+.1f%%/hr — the sustainable pace for this window is %.1f%%/hr (any faster hits the cap before reset)", slope, capPace)
    }

    static func dayPart(_ d: Date) -> String {
        switch Calendar.current.component(.hour, from: d) {
        case ..<12: return "morning"
        case ..<17: return "afternoon"
        default:    return "evening"
        }
    }

    static func ordinal(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .ordinal
        return f.string(from: NSNumber(value: n)) ?? "\(n)th"
    }
}
