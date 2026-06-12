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

    /// "topped 90% in 3 of 73 cycles · hit the limit 1×" — natural-frequency
    /// risk, never a fitted probability; never "0%" from a short record.
    static func frequencyLine(_ o: UsageIntelligenceEngine.BurnOutlook) -> String? {
        guard o.cyclesObserved >= 5 else { return nil }
        let top = o.cyclesPeakOver90 == 0
            ? "never topped 90% in \(o.cyclesObserved) cycles"
            : "topped 90% in \(o.cyclesPeakOver90) of \(o.cyclesObserved) cycles"
        let cap = o.cyclesHit100 == 0 ? "never hit the limit" : "hit the limit \(o.cyclesHit100)×"
        return "\(top) · \(cap)"
    }

    /// The crossing as window-scaled copy, leading with the conformal
    /// earliest–latest range whenever the engine has one: the point crossing
    /// alone over-promises (model selection optimizes end-of-cycle error, and
    /// the candidates' crossing *times* legitimately spread hours apart).
    /// Same-day ranges read as clock times ("→ limit 4 PM–9 PM"), multi-day
    /// ones as day labels ("→ limit tomorrow–Sat"). When the lower band never
    /// crosses — the reset may genuinely win — the phrasing softens to "may
    /// hit limit". ("Limit", not "cap": Eric flagged "cap" as a poor word,
    /// and "limit" matches the hero chip + Anthropic's own term.)
    static func crossingPhrase(_ o: UsageIntelligenceEngine.BurnOutlook) -> String? {
        crossingPhrase(at: o.projectedFullAt, earliest: o.projectedFullAtEarliest,
                       latest: o.projectedFullAtLatest, usedPct: o.usedPct)
    }

    static func crossingPhrase(at hit: Date?, earliest: Date?, latest: Date?, usedPct: Double) -> String? {
        guard let hit else { return nil }
        if let earliest, let latest, latest > earliest {
            let bothToday = earliest.timeIntervalSinceNow < 22 * 3600
                && latest.timeIntervalSinceNow < 22 * 3600
            if bothToday {
                // Keep minutes when the whole range lands within ~3 hours —
                // "around 10 AM" for a 25-minute-away crossing reads stale.
                let fmt: Date.FormatStyle = latest.timeIntervalSinceNow < 3 * 3600
                    ? .dateTime.hour().minute() : .dateTime.hour()
                let lo = earliest.formatted(fmt)
                let hi = latest.formatted(fmt)
                return lo == hi ? "→ limit around \(lo)" : "→ limit \(lo)–\(hi)"
            }
            let lo = dayLabel(earliest), hi = dayLabel(latest)
            if lo == hi {
                let dp0 = dayPart(earliest), dp1 = dayPart(latest)
                return dp0 == dp1 ? "→ limit \(lo) \(dp0)" : "→ limit \(lo) \(dp0)–\(dp1)"
            }
            return "→ limit \(lo)–\(hi)"
        }
        let pointFmt: Date.FormatStyle = hit.timeIntervalSinceNow < 3 * 3600
            ? .dateTime.hour().minute() : .dateTime.hour()
        let point = hit.timeIntervalSinceNow < 22 * 3600
            ? "around \(hit.formatted(pointFmt))"
            : "\(hit.formatted(.dateTime.weekday(.abbreviated))) \(dayPart(hit))"
        // A calibrated earliest with no latest-plausible crossing means the
        // lower band says the reset might come first — assert the cap only
        // when usage is already so high it's near-inevitable; otherwise say
        // "may". (No bands at all keeps the plain assertion: there's no
        // evidence either way, and the point is the model's best answer.)
        if earliest != nil, latest == nil, usedPct < 90 {
            return "→ may hit limit \(point)"
        }
        return "→ limit \(point)"
    }

    /// "in 45 min" / "in 3–8 hr" / "in 2–4 days" — the relative form of the
    /// crossing for the hero-tile chip, the menu bar, and notification
    /// titles. Same honesty rule as `crossingPhrase`: lead with the
    /// calibrated range, collapsing to a point only when both ends round to
    /// the same words.
    static func relativeCrossingPhrase(_ o: UsageIntelligenceEngine.BurnOutlook) -> String? {
        relativeCrossingPhrase(at: o.projectedFullAt, earliest: o.projectedFullAtEarliest,
                               latest: o.projectedFullAtLatest)
    }

    static func relativeCrossingPhrase(at hit: Date?, earliest: Date?, latest: Date?) -> String? {
        guard let hit else { return nil }
        if let earliest, let latest, latest > earliest {
            let a = coarseEta(earliest), b = coarseEta(latest)
            if a.text == b.text { return "in \(a.text)" }
            if a.unit == b.unit { return "in \(a.amount)–\(b.amount) \(b.unit)" }
            return "in \(a.text)–\(b.text)"
        }
        return "in \(coarseEta(hit).text)"
    }

    /// Coarse duration words — minutes under 90 (rounded to 5), hours under
    /// 48, days beyond. Crossing forecasts carry hours of uncertainty;
    /// finer-grained units would be false precision.
    private static func coarseEta(_ d: Date) -> (amount: String, unit: String, text: String) {
        let s = max(0, d.timeIntervalSinceNow)
        if s < 90 * 60 {
            let m = max(5, Int((s / 300).rounded()) * 5)
            return ("\(m)", "min", "\(m) min")
        }
        if s < 48 * 3600 {
            let h = max(2, Int((s / 3600).rounded()))
            return ("\(h)", "hr", "\(h) hr")
        }
        let days = max(2, Int((s / 86400).rounded()))
        return ("\(days)", "days", "\(days) days")
    }

    /// "today" / "tomorrow" / "Sat" — day-scale label for multi-day
    /// crossing ranges.
    static func dayLabel(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "today" }
        if cal.isDateInTomorrow(d) { return "tomorrow" }
        return d.formatted(.dateTime.weekday(.abbreviated))
    }

    /// Current burn relative to the rate that exactly reaches 100% at reset
    /// (100% ÷ window length). >1 means the limit comes before the reset if
    /// the rate holds. Kept as the *color* driver for the burn chip; the
    /// "0.5× sustainable pace" text form it used to feed read as jargon
    /// (Eric, 2026-06-12) and is gone — chips now say what happens instead
    /// ("≈52% at reset" / "limit in 7 hr").
    static func capPaceRatio(slopePercentPerHour slope: Double, windowSeconds: TimeInterval) -> Double {
        let capPace = 100.0 / (windowSeconds / 3600)
        return capPace > 0 ? slope / capPace : 0
    }

    /// "0.3×" / "1.8×" / "12×" — one decimal below ten, whole above.
    static func multiple(_ ratio: Double) -> String {
        ratio >= 10 ? String(format: "%.0f×", ratio) : String(format: "%.1f×", ratio)
    }

    /// Burn-chip tooltip: the raw rate plus what it means in plain words.
    static func capPaceHelp(slopePercentPerHour slope: Double, windowSeconds: TimeInterval) -> String {
        let capPace = 100.0 / (windowSeconds / 3600)
        return String(format: "Burning %+.1f%%/hr. A steady %.1f%%/hr would land exactly at 100%% when this window resets — anything faster hits the limit early.", slope, capPace)
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
