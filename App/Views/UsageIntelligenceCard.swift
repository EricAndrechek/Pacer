import SwiftUI
import PacerCore
import PacerUI

/// Dashboard surface for the on-device intelligence engine — the first view to
/// actually consume the typed `ask(question) → Estimate` contract. It shows the
/// engine's calibrated answers (point + likely range + which method + an honest
/// "lean on the range" when it's early), and a footer reporting how each method
/// is *actually* doing on this user's own data — the self-improving loop, made
/// visible.
///
/// The engine is a background actor, not a SwiftData model, so this reads it in
/// a `.task` and re-asks whenever a scan cycle lands new data (the engine
/// refits on the same signal). It never blocks the main thread and degrades to
/// a muted "not enough data yet" per row rather than a confident wrong number.
struct UsageIntelligenceCard: View {
    @Environment(\.usageEngine) private var engine
    @State private var answers: Answers?
    @State private var reloadToken = 0

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
            if let footer = answers?.footer {
                Text(footer)
            }
        }
        .task(id: reloadToken) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .pacerScanCycleDidComplete)) { _ in
            reloadToken &+= 1
        }
    }

    // MARK: - Content

    @ViewBuilder private func content(_ a: Answers) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Headline: projected end-of-day cost, with its calibrated band and
            // an honest method/confidence line underneath.
            VStack(alignment: .leading, spacing: 2) {
                MetricTile(value: cost(a.today),
                           label: "projected by end of day",
                           hint: bandHint(a.today),
                           tooltip: exactTip(a.today))
                Text(methodLine(a.today))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider().opacity(0.4)

            VStack(spacing: 9) {
                row("This month", value: cost(a.month), sub: bandHint(a.month))
                row("5-hour limit", value: pct(a.fiveHour), sub: rlSub(a.fiveHour))
                row("7-day limit", value: pct(a.sevenDay), sub: rlSub(a.sevenDay))
                row("Pace today", value: phrase(a.pace), sub: paceSub(a.pace))
                row("Typical for today", value: cost(a.typical), sub: bandHint(a.typical))
                row("Yesterday", value: phrase(a.anomaly))
            }
        }
    }

    private func row(_ label: String, value: String, sub: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(value).font(.subheadline).monospacedDigit()
                if let sub, !sub.isEmpty {
                    Text(sub).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Load (ask the engine)

    private func load() async {
        guard let engine else { return }
        let today = await engine.ask(.projectedCost(.today))
        let month = await engine.ask(.projectedCost(.thisMonth))
        let fiveHour = await engine.ask(.rateLimitOutlook(.fiveHour))
        let sevenDay = await engine.ask(.rateLimitOutlook(.sevenDay))
        let pace = await engine.ask(.pace)
        let typical = await engine.ask(.typicalUsage)
        let anomaly = await engine.ask(.isAnomalous)
        let eodAcc = await engine.selfEvalAccuracy()
        let rlAcc = await engine.selfEvalAccuracy(surface: EngineSelfEval.rlSurface(RateLimitWindowKind.sevenDay.rawValue))
        answers = Answers(today: today, month: month, fiveHour: fiveHour, sevenDay: sevenDay,
                          pace: pace, typical: typical, anomaly: anomaly,
                          footer: Self.footer(eod: eodAcc, sevenDay: rlAcc))
    }

    // MARK: - Formatting

    private func cost(_ e: Estimate) -> String { e.isInsufficient ? "—" : pacerCost(e.value) }
    private func pct(_ e: Estimate) -> String { e.isInsufficient ? "—" : "\(Int(e.value.rounded()))%" }
    private func phrase(_ e: Estimate) -> String { e.isInsufficient ? "—" : (e.note ?? "—") }

    private func bandHint(_ e: Estimate) -> String? {
        guard !e.isInsufficient, let b = e.interval80 else { return nil }
        return "likely \(pacerCost(b.lowerBound))–\(pacerCost(b.upperBound))"
    }

    private func rlSub(_ e: Estimate) -> String? {
        guard !e.isInsufficient else { return nil }
        var parts: [String] = []
        if let b = e.interval80 {
            parts.append("\(Int(b.lowerBound.rounded()))–\(Int(b.upperBound.rounded()))% range")
        }
        if let note = e.note { parts.append(note) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func paceSub(_ e: Estimate) -> String? {
        guard !e.isInsufficient else { return nil }
        return "\(Int((e.value * 100).rounded()))th percentile of your days"
    }

    private func methodLine(_ e: Estimate) -> String {
        guard !e.isInsufficient else { return e.note ?? "not enough history yet" }
        var line = "via \(Self.displayName(e.method)) · \(e.confidence.rawValue) confidence"
        if let note = e.note { line += " · \(note)" }
        return line
    }

    private func exactTip(_ e: Estimate) -> String? {
        e.isInsufficient ? nil : pacerCostExact(e.value)
    }

    static func displayName(_ method: String) -> String {
        switch method {
        case "eod-clock", "average-rate":          return "clock-linear"
        case "regime-gated-eod":                   return "hour-of-day shape"
        case "eod-done-gate":                      return "day looks done"
        case "monthly-daily-sum":                  return "daily-sum"
        case "monthly-flat", "monthly":            return "flat average"
        case "rl-diurnal-rate", "diurnal-rate":    return "diurnal"
        case "rl-saturating", "saturating":        return "saturating"
        case "rl-linear-recent", "linear-recent":  return "linear"
        case "rl-recency-weighted", "recency-weighted": return "recency-weighted"
        case "rl-damped-acceleration", "damped-acceleration": return "damped"
        default:                                   return method
        }
    }

    /// "Learned from your data: end-of-day via X (~N% off, Md) · 7-day via Y (~N%)"
    /// — the accumulated per-user track record that drives selection.
    static func footer(eod: EngineSelfEval.Accuracy?, sevenDay: EngineSelfEval.Accuracy?) -> String? {
        func part(_ label: String, _ acc: EngineSelfEval.Accuracy?) -> String? {
            guard let m = acc?.methods.first, m.medianAbsPctError.isFinite, m.periods > 0 else { return nil }
            return "\(label) via \(displayName(m.method)) (~\(Int(m.medianAbsPctError.rounded()))% off, \(m.periods)d)"
        }
        let parts = [part("end-of-day", eod), part("7-day limit", sevenDay)].compactMap { $0 }
        return parts.isEmpty ? nil : "Learned from your data — " + parts.joined(separator: " · ")
    }

    struct Answers {
        let today, month, fiveHour, sevenDay, pace, typical, anomaly: Estimate
        let footer: String?
    }
}
