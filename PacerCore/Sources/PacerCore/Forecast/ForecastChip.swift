import Foundation

/// The forecast chip on a window's card, "≈52% at reset" / "limit in 7 hr",
/// and the crossing words every surface shares (#318).
///
/// **One colour rule.** The colour says where the window ends up, through
/// the canonical `UsageBand` mapping. How sure the forecast is goes in the
/// words only ("may", the tooltip's calibrated range), never in the colour:
///
///     ≈39% at reset            green     ends under 50%
///     ≈65% at reset            yellow    50–75%
///     ≈84% at reset            orange    75–90%
///     limit around reset       red       ends at 99.5%+, no crossing before the reset
///     limit in 9 hr            red       crosses before the reset, claimed
///     may hit limit in 9 hr    red       crosses before the reset, not claimed yet
///     holds until reset        grey      idle: the forecast keeps it where it is
///
/// "may hit limit" used to be orange and the at-reset value was tinted by how
/// fast the window climbed, so the same outcome came in three colours and a
/// weekly window at 97% read "≈100% at reset" in green. A slope-only chip
/// ("+1.2%/hr") is gone too: it told the speed, which the burn-rate chip
/// beside it now says (`RecentBurn.chipText`), and a speed has no "where it
/// ends up" to colour by.
///
/// Pure and in PacerCore so the rule is tested; the app maps `Tint` to its
/// colours.
public struct ForecastChip: Sendable, Equatable {

    public enum Tint: Sendable, Equatable {
        /// Where the window ends up.
        case band(UsageBand)
        /// No movement: grey.
        case neutral
    }

    public let text: String
    public let tint: Tint
    public let help: String

    public init(text: String, tint: Tint, help: String) {
        self.text = text
        self.tint = tint
        self.help = help
    }

    /// The forecast ends at or past this: said as the limit, not as a number
    /// that rounds to 100.
    public static let limitAroundResetFloor = 99.5

    /// The chip for a window's outlook, or nil when there is nothing to say
    /// (a window at 0% that is not moving, or no forecast of where it ends).
    ///
    /// `usedPct` is the number the card shows (the live estimate or the
    /// reading), separate from `outlook.usedPct`, the engine's last-refit
    /// snapshot: at 100% shown, no future crossing is projected.
    public static func make(
        outlook: UsageIntelligenceEngine.BurnOutlook,
        endEstimate: Estimate?,
        duration: TimeInterval,
        usedPct: Double,
        now: Date
    ) -> ForecastChip? {
        // Whole points: readings are whole, and an estimate of 99.6% has not
        // reached the limit.
        if usedPct.rounded(.down) >= 100 {
            return ForecastChip(
                text: "at the limit", tint: .band(.red),
                help: "You're at the top of this window — usage can't climb further until it resets.")
        }
        let ratio = capPaceRatio(slopePercentPerHour: outlook.slopePercentPerHour, windowSeconds: duration)
        let atReset = endEstimate.flatMap { $0.isInsufficient ? nil : $0.value }
        guard ratio >= BurnRate.idleFractionOfCapPace else {
            let quiet = WindowSpec.isWeeklyScale(duration: duration) ? "day" : "90 minutes"
            switch BurnRate.idleVerdict(usedPct: usedPct, atReset: atReset) {
            case .holds?:
                return ForecastChip(
                    text: "holds until reset", tint: .neutral,
                    help: "No movement in the last \(quiet), so the forecast keeps it here until it resets.")
            case .atReset(let end)?:
                return atResetChip(
                    Double(end),
                    help: "Quiet for the last \(quiet), but your usual rhythm picks up again before the reset.")
            case nil:
                return nil
            }
        }
        var help = capPaceHelp(slopePercentPerHour: outlook.slopePercentPerHour, windowSeconds: duration)
        if outlook.willHitLimitBeforeReset, let eta = relativeCrossing(outlook.projectedFullAt, now: now) {
            if let phrase = crossingPhrase(outlook, now: now) {
                let when = phrase
                    .replacingOccurrences(of: "→ may hit limit ", with: "")
                    .replacingOccurrences(of: "→ limit ", with: "")
                help += " Crossing projected \(when), at your typical rhythm."
            }
            return ForecastChip(text: "limit \(eta)", tint: .band(.red), help: help)
        }
        // The line crosses before the reset but the claim is withheld: the
        // crossing, hedged in the words. The outcome is still the limit, so
        // the colour is the limit's.
        if let withheld = outlook.hitWithheld, let eta = relativeCrossing(outlook.projectedFullAt, now: now) {
            help += " The forecast line reaches 100% \(eta). " + withheldReason(withheld)
            return ForecastChip(text: "may hit limit \(eta)", tint: .band(.red), help: help)
        }
        guard let e = endEstimate, !e.isInsufficient else { return nil }
        if let band = e.interval80 {
            help += String(format: " Calibrated range at reset: %.0f–%.0f%%.",
                           band.lowerBound, band.upperBound)
        }
        return atResetChip(e.value, help: help)
    }

    /// "≈52% at reset" in the band it ends in, or "limit around reset" once
    /// it rounds to the limit without crossing it first.
    static func atResetChip(_ end: Double, help: String) -> ForecastChip {
        if end >= limitAroundResetFloor {
            return ForecastChip(text: "limit around reset", tint: .band(.red), help: help)
        }
        let shown = end.rounded()
        return ForecastChip(text: "≈\(Int(shown))% at reset",
                            tint: .band(UsageBand(percentage: shown)), help: help)
    }

    // MARK: - Crossing words

    /// "in 45 min" / "in 7 hr" / "in 3 days": the relative form of the
    /// crossing for the chip, the menu bar and notification titles. A POINT,
    /// deliberately (points not ranges, 2026-07-06): the chip surfaces are
    /// glanceable and a "5 min–32 hr" range there reads broken, while the
    /// coarse units already say "approximately". The calibrated range speaks
    /// where there is room to explain it: `crossingPhrase` in the tooltip.
    public static func relativeCrossing(_ hit: Date?, now: Date) -> String? {
        guard let hit else { return nil }
        return "in \(coarseEta(hit, now: now))"
    }

    /// Coarse duration words: minutes under 90 (rounded to 5), hours under
    /// 48, days beyond. Crossing forecasts carry hours of uncertainty; finer
    /// units would be false precision.
    static func coarseEta(_ d: Date, now: Date) -> String {
        let s = max(0, d.timeIntervalSince(now))
        if s < 90 * 60 {
            return "\(max(5, Int((s / 300).rounded()) * 5)) min"
        }
        if s < 48 * 3600 {
            return "\(max(2, Int((s / 3600).rounded()))) hr"
        }
        return "\(max(2, Int((s / 86400).rounded()))) days"
    }

    /// The crossing as window-scaled copy, leading with the conformal
    /// earliest–latest range whenever the engine has one: the point crossing
    /// alone over-promises (model selection optimizes end-of-cycle error, and
    /// the candidates' crossing *times* legitimately spread hours apart).
    /// Same-day ranges read as clock times ("→ limit 4 PM–9 PM"), multi-day
    /// ones as day labels ("→ limit tomorrow–Sat"). When the lower band never
    /// crosses (the reset may genuinely win) the phrasing softens to "may
    /// hit limit". "Limit", not "cap": it matches the chip and Anthropic's
    /// own term.
    public static func crossingPhrase(_ o: UsageIntelligenceEngine.BurnOutlook, now: Date) -> String? {
        crossingPhrase(at: o.projectedFullAt, earliest: o.projectedFullAtEarliest,
                       latest: o.projectedFullAtLatest, usedPct: o.usedPct, now: now)
    }

    public static func crossingPhrase(at hit: Date?, earliest: Date?, latest: Date?, usedPct: Double,
                                      now: Date) -> String? {
        guard let hit else { return nil }
        if let earliest, let latest, latest > earliest {
            let bothToday = earliest.timeIntervalSince(now) < 22 * 3600
                && latest.timeIntervalSince(now) < 22 * 3600
            if bothToday {
                // Keep minutes when the whole range lands within ~3 hours:
                // "around 10 AM" for a 25-minute-away crossing reads stale.
                let fmt: Date.FormatStyle = latest.timeIntervalSince(now) < 3 * 3600
                    ? .dateTime.hour().minute() : .dateTime.hour()
                let lo = earliest.formatted(fmt)
                let hi = latest.formatted(fmt)
                return lo == hi ? "→ limit around \(lo)" : "→ limit \(lo)–\(hi)"
            }
            let lo = dayLabel(earliest, now: now), hi = dayLabel(latest, now: now)
            if lo == hi {
                let dp0 = dayPart(earliest), dp1 = dayPart(latest)
                return dp0 == dp1 ? "→ limit \(lo) \(dp0)" : "→ limit \(lo) \(dp0)–\(dp1)"
            }
            return "→ limit \(lo)–\(hi)"
        }
        let pointFmt: Date.FormatStyle = hit.timeIntervalSince(now) < 3 * 3600
            ? .dateTime.hour().minute() : .dateTime.hour()
        let point = hit.timeIntervalSince(now) < 22 * 3600
            ? "around \(hit.formatted(pointFmt))"
            : "\(hit.formatted(.dateTime.weekday(.abbreviated))) \(dayPart(hit))"
        // A calibrated earliest with no latest-plausible crossing means the
        // lower band says the reset might come first: assert the limit only
        // when usage is already so high it's near-inevitable; otherwise say
        // "may". (No bands at all keeps the plain assertion: there's no
        // evidence either way, and the point is the model's best answer.)
        if earliest != nil, latest == nil, usedPct < 90 {
            return "→ may hit limit \(point)"
        }
        return "→ limit \(point)"
    }

    /// "today" / "tomorrow" / "Sat": day-scale label for multi-day crossing
    /// ranges.
    static func dayLabel(_ d: Date, now: Date) -> String {
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return "today" }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(d, inSameDayAs: tomorrow) {
            return "tomorrow"
        }
        return d.formatted(.dateTime.weekday(.abbreviated))
    }

    static func dayPart(_ d: Date) -> String {
        switch Calendar.current.component(.hour, from: d) {
        case ..<12: return "morning"
        case ..<17: return "afternoon"
        default:    return "evening"
        }
    }

    // MARK: - Pace against the limit

    /// Current burn relative to the rate that exactly reaches 100% at reset
    /// (100% ÷ window length). >1 means the limit comes before the reset if
    /// the rate holds. Only the idle test reads it now; the chip's colour is
    /// where the window ends up.
    public static func capPaceRatio(slopePercentPerHour slope: Double, windowSeconds: TimeInterval) -> Double {
        let capPace = 100.0 / (windowSeconds / 3600)
        return capPace > 0 ? slope / capPace : 0
    }

    /// The tooltip's opening: the raw rate plus what it means in plain words.
    static func capPaceHelp(slopePercentPerHour slope: Double, windowSeconds: TimeInterval) -> String {
        let capPace = 100.0 / (windowSeconds / 3600)
        return String(format: "Burning %+.1f%%/hr. A steady %.1f%%/hr would land exactly at 100%% when this window resets — anything faster hits the limit early.", slope, capPace)
    }

    static func withheldReason(_ w: UsageIntelligenceEngine.BurnOutlook.HitWithheld) -> String {
        switch w {
        case .earlyInWindow:
            return String(format: "Not called below %.0f%% used: early bursts usually slow down.",
                          BurnRate.warningUsedFloor)
        case .slowEndResetsFirst:
            return "Not called yet: at the slow end of its usual error, the window resets first."
        case .unconfirmed:
            return "Called once it holds on the next update."
        }
    }
}
