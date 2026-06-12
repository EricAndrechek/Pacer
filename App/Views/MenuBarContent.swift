import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// What renders in the menu bar status item. The displayed content is
/// driven by `PacerSettings.menuBarChips()` — an ordered list the user
/// configures in Settings → Menu bar. Any combination of:
///
///   - `.icon`         — `MenuBarIconStyle`-driven SF Symbol; color
///                       warms with the 5-hour usage band.
///   - `.fiveHourPct`  — current 5-hour rate-limit utilization.
///   - `.sevenDayPct`  — current 7-day rate-limit utilization.
///   - `.todayCost`    — today's spend in USD.
///   - `.todayTokens`  — today's token total (K / M / B suffixed).
///   - `.activeModel`  — model name of the most recent TokenSample.
///
/// Empty chip list = host tears the NSStatusItem down (handled in
/// `PacerAppDelegate.rebuildMenuBarForCurrentChips`).
struct MenuBarLabel: View {
    /// Cap the fetch — we only ever look at the most-recent sample per
    /// window. Without the cap, every SwiftData save materialized the
    /// full ~4k-row history just to fire the menu-bar label re-render.
    @Query(MenuBarLabel.recentRateLimitDescriptor)
    private var rateSamples: [RateLimitSample]

    /// Today's aggregates for cost / tokens chips. Filtered by date so
    /// the daemon's per-scan re-fire stays bounded (~5 model rows max).
    @Query private var todayAggregates: [DailyAggregate]

    /// Single most recent TokenSample, for the active-model chip. Cap
    /// to 1 — we never need any other field besides `model`.
    @Query(MenuBarLabel.recentTokenSampleDescriptor)
    private var recentSamples: [TokenSample]

    init() {
        let today = TokenSample.formatDate(Date())
        _todayAggregates = Query(
            filter: #Predicate<DailyAggregate> { $0.date == today }
        )
    }

    private static let recentRateLimitDescriptor: FetchDescriptor<RateLimitSample> = {
        var d = FetchDescriptor<RateLimitSample>(
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
        )
        d.fetchLimit = 8
        return d
    }()

    private static let recentTokenSampleDescriptor: FetchDescriptor<TokenSample> = {
        var d = FetchDescriptor<TokenSample>(
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
        )
        d.fetchLimit = 1
        return d
    }()

    @AppStorage(PacerSettings.Key.menuBarChips, store: PacerSettings.store)
    private var chipsRaw: String = "icon,five_hour_pct"

    @AppStorage(PacerSettings.Key.menuBarIconStyle, store: PacerSettings.store)
    private var iconRaw: String = PacerSettings.MenuBarIconStyle.gaugeNeedle.rawValue

    /// Last band we rendered. When this jumps to a warmer band (yellow
    /// → orange → red) we kick a one-shot scale pulse so the icon
    /// visibly reacts to the threshold crossing. Without it the only
    /// signal of "we just went over 75%" was the banner notification —
    /// which the user might have dismissed on a different screen.
    @State private var lastBand: UsageBand?
    @State private var pulse: Bool = false
    /// Reduce-motion suppression: the icon color escalation alone
    /// already communicates warming; the scale pulse is decorative.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Derived state

    private var chips: [PacerSettings.MenuBarChip] {
        // Re-parse from the @AppStorage CSV so SwiftUI body-eval picks
        // up changes immediately (PacerSettings.menuBarChips() reads
        // the same store but isn't reactive on its own).
        var seen = Set<PacerSettings.MenuBarChip>()
        var ordered: [PacerSettings.MenuBarChip] = []
        for token in chipsRaw.split(separator: ",") {
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            guard let chip = PacerSettings.MenuBarChip(rawValue: trimmed),
                  !seen.contains(chip) else { continue }
            seen.insert(chip)
            ordered.append(chip)
        }
        return ordered
    }

    private var fiveHour: RateLimitSample? {
        rateSamples.first { $0.window == "five_hour" }
    }

    private var sevenDay: RateLimitSample? {
        rateSamples.first { $0.window == "seven_day" }
    }

    private var iconStyle: PacerSettings.MenuBarIconStyle {
        PacerSettings.MenuBarIconStyle(rawValue: iconRaw) ?? .gaugeNeedle
    }

    private var band: UsageBand? {
        fiveHour.map { UsageBand(percentage: $0.usedPercentage) }
    }

    /// Color the SF Symbol picks up via `.palette` rendering. Critical
    /// difference vs the prior version: at green / nil, we now use
    /// `.primary` instead of `.secondary` so Pacer reads as a healthy,
    /// active item next to battery / Wi-Fi / time. The previous muted
    /// look made it look broken or inactive when usage was low —
    /// which is the *common* state, not the exception.
    private var bandColor: Color {
        switch band {
        case .green, nil: return .primary
        case .yellow:     return .yellow
        case .orange:     return .orange
        case .red:        return .red
        }
    }

    private var symbolName: String {
        switch iconStyle {
        case .gaugeNeedle:
            switch band {
            case .green:        return "gauge.with.dots.needle.0percent"
            case .yellow:       return "gauge.with.dots.needle.33percent"
            case .orange:       return "gauge.with.dots.needle.67percent"
            case .red:          return "gauge.with.dots.needle.100percent"
            case nil:           return "gauge.with.dots.needle.0percent"
            }
        case .ringFill:
            switch band {
            case .green, nil:   return "circle.dotted"
            case .yellow:       return "circle.lefthalf.filled"
            case .orange:       return "circle.righthalf.filled"
            case .red:          return "circle.fill"
            }
        case .dot:
            return "circle.fill"
        case .activityRings:
            // Unused — `.activityRings` renders an ActivityRings view
            // instead of an SF Symbol. Returning a value keeps the
            // switch exhaustive without forcing a runtime guard
            // around the symbol-name property.
            return "circle.fill"
        }
    }

    // MARK: - Chip data

    /// Activity-ring data for the menu-bar icon when `MenuBarIconStyle
    /// == .activityRings`. Outer = 5h, inner = 7d. nil samples render
    /// as empty tracks (still distinguishable as rings) rather than
    /// vanishing entirely.
    private var ringsForMenuBar: [ActivityRings.Ring] {
        let fiveHourPct = fiveHour?.usedPercentage ?? 0
        let sevenDayPct = sevenDay?.usedPercentage ?? 0
        return [
            ActivityRings.Ring(
                progress: fiveHourPct / 100,
                color: UsageBand(percentage: fiveHourPct).color
            ),
            ActivityRings.Ring(
                progress: sevenDayPct / 100,
                color: UsageBand(percentage: sevenDayPct).color
            )
        ]
    }

    private var todayCost: Double {
        todayAggregates.reduce(0) { $0 + $1.totalCostUSD }
    }

    private var todayTokens: Int64 {
        todayAggregates.reduce(0) {
            $0 + $1.inputTokens + $1.outputTokens
        }
    }

    private var activeModel: String? {
        recentSamples.first.map { pacerShortModel($0.model) }
    }

    /// Whether the 5h-percent chip should prefix itself with "5h ". When
    /// it's the only window chip on screen, the prefix is redundant;
    /// when 7-day is also visible, the prefix removes ambiguity.
    private var fiveHourNeedsPrefix: Bool {
        chips.contains(.sevenDayPct)
    }

    /// Tooltip shown on hover. Apple's Battery / Wi-Fi / Volume status
    /// items all surface a one-line summary on hover; ours had nothing.
    /// We dump whatever the chips don't already show so the user can
    /// hover for the "everything else."
    private var tooltip: String {
        var parts: [String] = []
        if let f = fiveHour {
            parts.append("5h: \(Int(f.usedPercentage.rounded()))%")
        }
        if let s = sevenDay {
            parts.append("7d: \(Int(s.usedPercentage.rounded()))%")
        }
        // Tooltip's reset hint reads from the 5-hour sample. When that
        // sample's cycle has already ended (Pacer hasn't ingested a fresh
        // one — see #3/#4), don't show "resets X ago" — that confuses
        // "ago" as a past event when it's actually "Pacer is behind."
        if let resets = fiveHour?.resetsAt {
            let cycle = DisplayCycle.resolve(resetsAt: resets, duration: 5 * 3600)
            parts.append(cycle.isAwaiting
                ? "5h cycle reset, awaiting fresh sample"
                : "resets \(pacerRelative(resets))")
        }
        if parts.isEmpty {
            return "Pacer — collecting…"
        }
        return parts.joined(separator: " • ")
    }

    // MARK: - Layout

    var body: some View {
        // No outer padding — the NSStatusBarButton already adds the
        // menu-bar's standard side margins, and any SwiftUI padding
        // here just ate into the content area without enlarging the
        // button (NSStatusItem's `variableLength` measures the
        // button's native intrinsic content size, not a custom
        // subview's). Spacing between chips comes from `HStack`'s
        // own `spacing:`.
        HStack(spacing: 6) {
            ForEach(chips) { chip in
                chipView(chip)
            }
        }
        .help(tooltip)
        .onChange(of: band) { oldValue, newValue in
            // Pulse only on warming (green→yellow, yellow→orange, etc.).
            // Cooling (band drops at cycle reset) shouldn't draw the eye.
            guard let newValue, isWarming(from: oldValue, to: newValue) else {
                lastBand = newValue
                return
            }
            lastBand = newValue
            // Skip the scale pulse under Reduce Motion — color escalation
            // is enough.
            guard !reduceMotion else { return }
            pulse = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                pulse = false
            }
        }
    }

    @ViewBuilder
    private func chipView(_ chip: PacerSettings.MenuBarChip) -> some View {
        switch chip {
        case .icon:
            if iconStyle == .activityRings {
                // Apple Watch-style dual-ring icon. Outer = 5h, inner
                // = 7d. 14pt fits the menu-bar height comfortably
                // alongside chip text without crowding adjacent
                // items. Each ring's color is band-driven so the
                // icon escalates the same way the gauge/dot styles
                // would.
                ActivityRings(rings: ringsForMenuBar)
                    .frame(width: 14, height: 14)
                    .scaleEffect(pulse ? 1.15 : 1.0)
                    .animation(
                        .spring(response: 0.35, dampingFraction: 0.55),
                        value: pulse
                    )
            } else {
                // `.monochrome` (not `.palette`) so the SF Symbol
                // renders in one solid tint — the gauge needle
                // family has a body layer that `.palette` was
                // painting with `.secondary.opacity(0.5)`, which read
                // as "greyed out" even at full health. Monochrome
                // with `bandColor` makes the whole icon read at full
                // strength like Battery / Wi-Fi when the band is
                // green.
                Image(systemName: symbolName)
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(bandColor)
                    .scaleEffect(pulse ? 1.15 : 1.0)
                    .animation(
                        .spring(response: 0.35, dampingFraction: 0.55),
                        value: pulse
                    )
            }

        case .fiveHourPct:
            percentChip(
                prefix: fiveHourNeedsPrefix ? "5h " : nil,
                sample: fiveHour
            )

        case .sevenDayPct:
            percentChip(prefix: "7d ", sample: sevenDay)

        case .todayCost:
            textChip(pacerCost(todayCost))

        case .todayTokens:
            textChip(pacerTokens(todayTokens))

        case .activeModel:
            if let model = activeModel {
                textChip(model)
            } else {
                textChip("—")
            }
        }
    }

    /// Percent chip with an optional window prefix ("5h " / "7d "). The
    /// percent text warms to red at the red band — yellow / orange
    /// stay primary because colored text in the menu bar reads poorly
    /// (especially at the high-contrast accessibility setting). The
    /// icon chip carries the band coloring; this one only escalates at
    /// the red/critical threshold.
    @ViewBuilder
    private func percentChip(prefix: String?, sample: RateLimitSample?) -> some View {
        if let s = sample {
            let band = UsageBand(percentage: s.usedPercentage)
            let pct = "\(Int(s.usedPercentage.rounded()))%"
            Text((prefix ?? "") + pct)
                .monospacedDigit()
                .foregroundStyle(band == .red ? Color.red : Color.primary)
        } else {
            Text((prefix ?? "") + "—")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func textChip(_ text: String) -> some View {
        Text(text)
            .monospacedDigit()
            .foregroundStyle(.primary)
    }

    private func isWarming(from old: UsageBand?, to new: UsageBand) -> Bool {
        guard let old else { return new != .green }
        return new.severity > old.severity
    }
}

private extension UsageBand {
    /// Higher = warmer / more urgent. Used to detect upward crossings
    /// for the pulse animation.
    var severity: Int {
        switch self {
        case .green:  return 0
        case .yellow: return 1
        case .orange: return 2
        case .red:    return 3
        }
    }
}

/// The "data" portion of the status-bar NSMenu — pace rows for 5h /
/// 7d and today's spend / tokens. Hosted in a single `NSMenuItem.view`
/// (see `PacerAppDelegate.buildStatusMenu`) so the action items
/// (Open / Settings / Quit) below it can be real `NSMenuItem`s with
/// native chrome, keyboard shortcuts, and macOS's automatic
/// menu-bar handoff behavior.
///
/// Why this exists separately from `MenuBarLabel`: the label is what
/// shows in the menu bar all the time (gauge + chips); this is what
/// drops down when the user clicks. The label is reactive at the
/// chip level via @AppStorage; this view is reactive at the data
/// level via @Query.
struct MenuStatusContent: View {
    @Query(MenuStatusContent.recentDescriptor)
    private var rateLimits: [RateLimitSample]
    @Query private var todayAggregates: [DailyAggregate]

    /// Engine answers for the outlook touches: per-window crossing (the
    /// trailing caption goes red "cap ~6 PM" when a pre-reset hit is
    /// projected) and the fixed Outlook row (projection once actionable,
    /// pace-vs-normal before). Row COUNT stays constant — NSMenuItem.view
    /// is measured at attach time, so conditional rows would clip.
    @Environment(\.usageEngine) private var engine
    @State private var outlooks: [String: UsageIntelligenceEngine.BurnOutlook] = [:]
    @State private var todayEOD: Estimate?
    @State private var pacePercentile: Double?

    private func refreshEngine() async {
        guard let engine else { return }
        var next: [String: UsageIntelligenceEngine.BurnOutlook] = [:]
        for w in RateLimitWindowKind.allCases {
            if let o = await engine.burnOutlook(window: w) { next[w.rawValue] = o }
        }
        outlooks = next
        todayEOD = await engine.ask(.projectedCost(.today))
        let pace = await engine.ask(.pace)
        pacePercentile = pace.isInsufficient ? nil : pace.value
    }

    private static let recentDescriptor: FetchDescriptor<RateLimitSample> = {
        var d = FetchDescriptor<RateLimitSample>(
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
        )
        d.fetchLimit = 8
        return d
    }()

    init() {
        let today = TokenSample.formatDate(Date())
        _todayAggregates = Query(
            filter: #Predicate<DailyAggregate> { $0.date == today }
        )
    }

    private var fiveHour: RateLimitSample? { rateLimits.first { $0.window == "five_hour" } }
    private var sevenDay: RateLimitSample? { rateLimits.first { $0.window == "seven_day" } }

    private var todayCost: Double {
        todayAggregates.reduce(0) { $0 + $1.totalCostUSD }
    }

    private var todayTokens: Int64 {
        todayAggregates.reduce(0) {
            $0 + $1.inputTokens + $1.outputTokens
        }
    }

    var body: some View {
        // Width is fixed because the host (`NSMenuItem.view`) doesn't
        // re-measure when the SwiftUI body changes size — the menu
        // tracks the view's frame at attach time. 280pt is wide enough
        // for "pace 50% · resets in 2 hr." without truncating and
        // matches typical Apple status menu widths (Wi-Fi ~280pt,
        // Battery ~260pt).
        VStack(alignment: .leading, spacing: 4) {
            paceRow(label: "5-HOUR", sample: fiveHour, duration: 5 * 3600,
                    outlook: outlooks[RateLimitWindowName.fiveHour])
            paceRow(label: "7-DAY", sample: sevenDay, duration: 7 * 86400,
                    outlook: outlooks[RateLimitWindowName.sevenDay])
            // Native NSMenu items don't have inset separators; ours
            // here is a SwiftUI Divider that runs the content width —
            // close enough that the eye doesn't catch it as "off."
            Divider()
                .padding(.vertical, 4)
            todayValueRow(label: "Today", value: pacerCost(todayCost), tooltip: pacerCostExact(todayCost))
            todayValueRow(label: "Tokens", value: pacerTokens(todayTokens), tooltip: "\(pacerTokensExact(todayTokens)) tokens")
            outlookRow
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: 280, alignment: .leading)
        .task { await refreshEngine() }
        .onReceive(NotificationCenter.default.publisher(for: .pacerEngineDidRecompute)) { _ in
            Task { await refreshEngine() }
        }
    }

    /// Fixed Outlook row, same language as the dashboard's Today tile:
    /// "≈$650 by tonight" once the range is actionable, the pace phrase
    /// before that, an em dash while warming up (constant row count).
    @ViewBuilder private var outlookRow: some View {
        let value: String = {
            if let e = todayEOD, IntelligenceFormatting.rangeIsActionable(e, spendSoFar: todayCost) {
                return "≈\(IntelligenceFormatting.approxCost(e.value)) by tonight"
            }
            if let p = pacePercentile {
                return IntelligenceFormatting.paceLabel(
                    index: IntelligenceFormatting.ladderIndex(p),
                    dayName: Date().formatted(.dateTime.weekday(.wide)))
            }
            return "—"
        }()
        HStack(spacing: 8) {
            Text("Outlook")
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .frame(width: 48, alignment: .leading)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func paceRow(label: String, sample: RateLimitSample?, duration: TimeInterval,
                         outlook: UsageIntelligenceEngine.BurnOutlook? = nil) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(0.5)
                .frame(width: 48, alignment: .leading)

            if let s = sample, let resets = s.resetsAt {
                let cycle = DisplayCycle.resolve(resetsAt: resets, duration: duration)
                if cycle.isAwaiting {
                    // Stale cycle (Pacer hasn't polled a fresh one yet).
                    // Show a muted "awaiting" line — no pace math from
                    // prior-cycle numbers.
                    CircularGauge(
                        percentage: s.usedPercentage,
                        lineWidth: 3,
                        labelFont: .system(size: 8, weight: .bold, design: .rounded)
                    )
                    .frame(width: 22, height: 22)
                    .opacity(0.4)

                    Text("—")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 32, alignment: .trailing)

                    Text("awaiting new cycle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)
                } else {
                    let pacePct = cycle.paceFraction * 100
                    let band = PaceBand(usedPct: s.usedPercentage, paceEndPct: pacePct)

                    CircularGauge(
                        percentage: s.usedPercentage,
                        lineWidth: 3,
                        labelFont: .system(size: 8, weight: .bold, design: .rounded)
                    )
                    .frame(width: 22, height: 22)

                    Text("\(Int(s.usedPercentage.rounded()))%")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .frame(width: 32, alignment: .trailing)

                    Text("pace \(Int(pacePct.rounded()))%")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(band.color)

                    Spacer(minLength: 4)

                    // The trailing caption escalates to the projected cap hit
                    // when the engine sees one coming — same answer the
                    // dashboard tiles and the notification share.
                    if let hit = outlook?.projectedFullAt {
                        Text("cap \(pacerRelative(hit, style: .short))")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    } else {
                        Text("resets \(pacerRelative(resets, style: .short))")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } else {
                Text("collecting…")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func todayValueRow(label: String, value: String, tooltip: String? = nil) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .frame(width: 48, alignment: .leading)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .help(tooltip ?? value)
        }
    }
}
