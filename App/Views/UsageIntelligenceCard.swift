import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// The intelligence engine's home on the dashboard — every number here is an
/// engine answer, presented per the uncertainty-communication research:
///
/// - one plain-language **summary sentence** (the Weather-app pattern), built
///   from the pace percentile ladder;
/// - a **gated hero**: before half the day is observed (or while the
///   calibrated range is wider than ~2.5× the point) a dollar projection is
///   not decision-useful, so the headline is spend-so-far + pace-vs-normal;
///   once the range is actionable, the headline becomes the projection with a
///   Weather-style range bar and asymmetric anchors ("at least … could
///   reach …") — never a bare symmetric interval, whose endpoints users
///   anchor on and misread;
/// - four supporting rows (the System Settings Battery/Storage row pattern):
///   month projection, both rate-limit windows with natural-frequency risk
///   copy ("topped 90% in 1 of 12 cycles — never hit the cap"), and
///   yesterday as a counting statement ("your 3rd-highest day in 10 weeks");
/// - a footer stating the engine's **earned evening accuracy** on this user's
///   own days — the calibration affordance, in plain frequency terms.
///
/// Color is reserved for actionable risk (a projected pre-reset cap hit), not
/// for uncertainty width — wide-but-normal is not danger.
struct UsageIntelligenceCard: View {
    @Environment(\.usageEngine) private var engine

    /// Today's rollup for the spend-so-far headline in early-read mode.
    @Query private var todayAggregates: [DailyAggregate]

    @State private var answers: Answers?
    @State private var reloadToken = 0
    /// Pace-ladder hysteresis: the label only changes once the percentile
    /// moves ≥10 points past a boundary, so it can't flap intra-day.
    @State private var paceLadderIndex: Int?

    init() {
        let today = TokenSample.formatDate(Date())
        _todayAggregates = Query(filter: #Predicate<DailyAggregate> { $0.date == today })
    }

    struct Answers {
        let today, month, pace, typical: Estimate
        let fiveHour, sevenDay: UsageIntelligenceEngine.BurnOutlook?
        let record: UsageIntelligenceEngine.TrackRecord?
        let yesterday: (cost: Double, rankFromTop: Int, of: Int)?
        let trainingDays: Int
    }

    var body: some View {
        PacerCard("Usage intelligence") {
            if let a = answers {
                content(a)
            } else {
                Text("Warming up…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            footerText
        }
        .task(id: reloadToken) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .pacerEngineDidRecompute)) { _ in
            reloadToken &+= 1
        }
    }

    private func load() async {
        guard let engine else { return }
        let today = await engine.ask(.projectedCost(.today))
        let month = await engine.ask(.projectedCost(.thisMonth))
        let pace = await engine.ask(.pace)
        let typical = await engine.ask(.typicalUsage)
        let fiveHour = await engine.burnOutlook(window: .fiveHour)
        let sevenDay = await engine.burnOutlook(window: .sevenDay)
        let record = await engine.eveningTrackRecord()
        let yesterday = await engine.yesterdayRank()
        let days = await engine.trainingDayCount()
        answers = Answers(today: today, month: month, pace: pace, typical: typical,
                          fiveHour: fiveHour, sevenDay: sevenDay,
                          record: record, yesterday: yesterday, trainingDays: days)
    }

    // MARK: - Content

    @ViewBuilder private func content(_ a: Answers) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(summary(a))
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if rangeIsActionable(a.today) {
                projectionHero(a)
            } else {
                earlyReadHero(a)
            }

            Divider().opacity(0.4)

            VStack(spacing: 10) {
                monthRow(a.month)
                limitRow(label: "5-hour limit", outlook: a.fiveHour)
                limitRow(label: "7-day limit", outlook: a.sevenDay)
                yesterdayRow(a)
            }
        }
    }

    /// Evening hero: the projection, its range bar in the context of the
    /// user's own typical range, and asymmetric anchors.
    @ViewBuilder private func projectionHero(_ a: Answers) -> some View {
        let e = a.today
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(approxCost(e.value))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .help(pacerCostExact(e.value))
                Text("projected by end of day")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let band = e.interval80 {
                RangeBar(domain: heroDomain(a),
                         range: outward(band),
                         point: e.value,
                         reference: a.typical.isInsufficient ? nil : a.typical.value)
                    .help(rangeHelp(a))
                Text(anchors(band))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Early-read hero: spend so far + pace vs the user's own days. A dollar
    /// projection this early would be a range too wide to act on, so the
    /// engine's rank skill (which IS supported this early) leads instead.
    @ViewBuilder private func earlyReadHero(_ a: Answers) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(pacerCost(todayCost))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .help(pacerCostExact(todayCost))
                Text("so far today")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text("Too early to call today's total — check back this evening.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func monthRow(_ e: Estimate) -> some View {
        row(label: "This month",
            value: e.isInsufficient ? "—" : approxCost(e.value),
            sub: e.interval80.map { "likely \(costRange(outward($0)))" },
            valueHelp: e.isInsufficient ? nil : pacerCostExact(e.value))
    }

    @ViewBuilder private func limitRow(label: String, outlook: UsageIntelligenceEngine.BurnOutlook?) -> some View {
        if let o = outlook {
            let projected = o.willHitLimitBeforeReset ? 100 : nil as Double?
            let tint: Color = o.willHitLimitBeforeReset ? .red : .primary
            row(label: label,
                value: "\(Int(o.usedPct.rounded()))%",
                valueDetail: hitOrResetPhrase(o),
                sub: frequencyLine(o),
                tint: tint)
                .help(projected != nil ? "Projected to reach the cap before this window resets" : "")
        } else {
            row(label: label, value: "—", sub: nil)
        }
    }

    @ViewBuilder private func yesterdayRow(_ a: Answers) -> some View {
        if let y = a.yesterday {
            let weeks = max(1, Int((Double(y.of) / 7.0).rounded()))
            let notable = y.rankFromTop <= max(3, y.of / 10)
            row(label: "Yesterday",
                value: pacerCost(y.cost),
                valueDetail: nil,
                sub: notable ? "your \(ordinal(y.rankFromTop))-highest day in \(weeks) weeks" : "a typical day for you",
                valueHelp: pacerCostExact(y.cost))
        }
    }

    private func row(label: String, value: String, valueDetail: String? = nil,
                     sub: String?, tint: Color = .primary, valueHelp: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 5) {
                    Text(value).font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(tint)
                    if let valueDetail {
                        Text(valueDetail).font(.subheadline).foregroundStyle(tint == .primary ? .secondary : tint)
                    }
                }
                .help(valueHelp ?? "")
                if let sub, !sub.isEmpty {
                    Text(sub).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Copy

    /// "On pace for a typical Wednesday — about $650 by tonight."
    private func summary(_ a: Answers) -> String {
        let dayName = Date().formatted(.dateTime.weekday(.wide))
        guard !a.pace.isInsufficient else {
            return "Learning your rhythm — \(a.trainingDays) days observed so far."
        }
        if rangeIsActionable(a.today) {
            let label = ladderLabel(percentile: a.pace.value, dayName: dayName)
            return "\(label) — about \(approxCost(a.today.value)) by tonight."
        }
        // Early in the day the projection percentile is honest but a flat
        // claim reads over-eager ("busier than usual" at 00:15 because most
        // days are $0 at midnight) — frame it as pace, not verdict.
        return earlyLadderLabel(percentile: a.pace.value, dayName: dayName) + "."
    }

    /// Early-day framing of the same ladder — pace, not verdict.
    private func earlyLadderLabel(percentile: Double, dayName: String) -> String {
        switch heldLadderIndex(percentile) {
        case 0:  return "A quiet start to \(dayName)"
        case 1:  return "Tracking like a typical \(dayName) so far"
        case 2:  return "Running ahead of your usual \(dayName) so far"
        case 3:  return "On pace for one of your heavier days"
        default: return "On your heaviest pace in weeks"
        }
    }

    /// Five-step pace ladder with hysteresis so the label can't flap.
    private func ladderLabel(percentile: Double, dayName: String) -> String {
        switch heldLadderIndex(percentile) {
        case 0:  return "A quiet \(dayName)"
        case 1:  return "On pace for a typical \(dayName)"
        case 2:  return "Busier than your usual \(dayName)"
        case 3:  return "One of your heavier days"
        default: return "Your heaviest pace in weeks"
        }
    }

    /// Ladder index with hysteresis: near a boundary, keep the held label.
    private func heldLadderIndex(_ percentile: Double) -> Int {
        let bounds = [0.25, 0.60, 0.85, 0.95]
        var idx = bounds.filter { percentile >= $0 }.count
        if let held = paceLadderIndex, abs(percentile - nearestBoundary(percentile)) < 0.10 {
            idx = held
        }
        if paceLadderIndex != idx {
            // Defer the state write out of view evaluation.
            let target = idx
            Task { @MainActor in paceLadderIndex = target }
        }
        return idx
    }

    private func nearestBoundary(_ p: Double) -> Double {
        [0.25, 0.60, 0.85, 0.95].min { abs($0 - p) < abs($1 - p) } ?? 0.6
    }

    /// "at least $480 · could reach $1.9k on a heavy day"
    private func anchors(_ band: ClosedRange<Double>) -> String {
        let b = outward(band)
        return "at least \(approxCost(b.lowerBound)) · could reach \(approxCost(b.upperBound)) on a heavy day"
    }

    /// "→ cap around 7 PM" / "resets in 3 days" — window-scaled, color carried
    /// by the row tint.
    private func hitOrResetPhrase(_ o: UsageIntelligenceEngine.BurnOutlook) -> String? {
        if let hit = o.projectedFullAt {
            if hit.timeIntervalSinceNow < 22 * 3600 {
                return "→ cap around \(hit.formatted(.dateTime.hour()))"
            }
            return "→ cap \(hit.formatted(.dateTime.weekday(.abbreviated))) \(dayPart(hit))"
        }
        return nil
    }

    /// "topped 90% in 1 of 12 cycles — never hit the cap" (Beta-smoothed
    /// phrasing rules: never claim 0% from a short record).
    private func frequencyLine(_ o: UsageIntelligenceEngine.BurnOutlook) -> String? {
        guard o.cyclesObserved >= 5 else { return "still learning this window" }
        var parts: [String] = []
        if o.cyclesPeakOver90 == 0 {
            parts.append("never topped 90% in \(o.cyclesObserved) cycles")
        } else {
            parts.append("topped 90% in \(o.cyclesPeakOver90) of \(o.cyclesObserved) cycles")
        }
        parts.append(o.cyclesHit100 == 0 ? "never hit the cap"
                     : "hit the cap \(o.cyclesHit100)×")
        return parts.joined(separator: " — ")
    }

    @ViewBuilder private var footerText: some View {
        if let a = answers {
            if let r = a.record {
                Text("Evening projections have landed within ~\(Int(r.medianAbsPctError.rounded()))% for you · \(r.days) days scored")
            } else {
                Text("Still calibrating — \(a.trainingDays) days observed")
            }
        }
    }

    // MARK: - Helpers

    private var todayCost: Double { todayAggregates.reduce(0) { $0 + $1.totalCostUSD } }

    /// The display gate: a range is decision-useful once at least half the
    /// day is observed AND the 80% range is no wider than ~2.5× the point.
    /// Screenshot mode pins the evening state so the README always shows the
    /// full projection hero.
    private func rangeIsActionable(_ e: Estimate) -> Bool {
        guard !e.isInsufficient, let band = e.interval80, e.value > 0 else { return false }
        let isScreenshot = ProcessInfo.processInfo.environment["PACER_SCREENSHOT_MODE"] == "1"
        let fractionOfDay = isScreenshot ? 0.8
            : Date().timeIntervalSince(Calendar.current.startOfDay(for: Date())) / 86400
        let widthRatio = (band.upperBound - band.lowerBound) / e.value
        return fractionOfDay >= 0.5 && widthRatio <= 2.5
    }

    private func heroDomain(_ a: Answers) -> ClosedRange<Double> {
        var hi = a.today.value * 1.2
        if let band = a.today.interval80 { hi = max(hi, band.upperBound * 1.05) }
        if !a.typical.isInsufficient, let t80 = a.typical.interval80 { hi = max(hi, t80.upperBound) }
        return 0...max(hi, 1)
    }

    private func rangeHelp(_ a: Answers) -> String {
        var s = "80% range: \(costRange(a.today.interval80 ?? a.today.value...a.today.value))"
        if !a.typical.isInsufficient {
            s += " · tick = your typical \(Date().formatted(.dateTime.weekday(.wide))) (\(pacerCost(a.typical.value)))"
        }
        return s
    }

    /// Round a forecast to 2 significant figures — displayed precision should
    /// not exceed measured skill.
    private func approxCost(_ v: Double) -> String {
        pacerCost(roundSig(v, up: nil))
    }

    private func costRange(_ r: ClosedRange<Double>) -> String {
        "\(pacerCost(r.lowerBound))–\(pacerCost(r.upperBound))"
    }

    /// Bands round OUTWARD so the printed range is never narrower than the
    /// calibrated one.
    private func outward(_ r: ClosedRange<Double>) -> ClosedRange<Double> {
        let lo = roundSig(r.lowerBound, up: false)
        let hi = roundSig(r.upperBound, up: true)
        return min(lo, hi)...max(lo, hi)
    }

    /// 2-significant-figure rounding; `up` forces ceiling/floor for bands.
    private func roundSig(_ v: Double, up: Bool?) -> Double {
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

    private func dayPart(_ d: Date) -> String {
        switch Calendar.current.component(.hour, from: d) {
        case ..<12: return "morning"
        case ..<17: return "afternoon"
        default:    return "evening"
        }
    }

    private func ordinal(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .ordinal
        return f.string(from: NSNumber(value: n)) ?? "\(n)th"
    }
}
