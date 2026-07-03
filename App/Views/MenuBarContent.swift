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

    private var todayCost: Double {
        todayAggregates.reduce(0) { $0 + $1.totalCostUSD }
    }

    private var todayTokens: Int64 {
        todayAggregates.reduce(0) {
            $0 + $1.inputTokens + $1.outputTokens
        }
    }

    private var activeModel: String? {
        recentSamples.first.map { pacerModelDisplayName($0.model) }
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

    /// The fully-resolved render payload — exactly what the status item
    /// draws. Recomputed on every @Query refresh (cheap: capped fetches
    /// + small derivations), but the NSStatusItem only re-rasterizes when
    /// this value changes, because the chrome below is wrapped in an
    /// EquatableView. SwiftData @Query invalidation is entity-agnostic,
    /// so without this gate the always-visible menu-bar item re-rendered
    /// (and re-rasterized via `cacheDisplayInRect`) on every store save
    /// all day — including token-only saves that touch no displayed
    /// value, and changes to values that aren't even on screen. Same
    /// remedy as the PR #102 toolbar pill.
    private var rendered: Render {
        Render(items: chips.map(resolve), tooltip: tooltip)
    }

    private func resolve(_ chip: PacerSettings.MenuBarChip) -> Render.Item {
        switch chip {
        case .icon:
            return iconStyle == .activityRings
                ? .rings(five: fiveHour?.usedPercentage ?? 0,
                         seven: sevenDay?.usedPercentage ?? 0)
                : .symbol(name: symbolName, band: band)
        case .fiveHourPct:
            return .percent(prefix: fiveHourNeedsPrefix ? "5h " : nil,
                            pct: fiveHour?.usedPercentage)
        case .sevenDayPct:
            return .percent(prefix: "7d ", pct: sevenDay?.usedPercentage)
        case .todayCost:
            return .text(pacerCost(todayCost))
        case .todayTokens:
            return .text(pacerTokens(todayTokens))
        case .activeModel:
            return .text(activeModel ?? "—")
        }
    }

    var body: some View {
        // `.equatable()` gates AppKit's re-rasterization: the outer view
        // still re-evaluates on every save (cheap), but the hosted status
        // item only redraws when `rendered` actually differs.
        MenuBarLabelContent(rendered: rendered).equatable()
    }

    /// Equatable render payload — captures exactly what the status item
    /// draws (resolved per-chip items + tooltip) so the chrome only
    /// re-renders on a real change.
    struct Render: Equatable {
        enum Item: Equatable {
            /// SF Symbol icon (gauge / ring-fill / dot styles); `band` tints it.
            case symbol(name: String, band: UsageBand?)
            /// Dual activity-ring icon (outer 5h, inner 7d). Raw percentages
            /// drive both ring fill and per-ring band color.
            case rings(five: Double, seven: Double)
            /// Window utilization chip; nil pct renders "—". `prefix` is the
            /// "5h " / "7d " disambiguator.
            case percent(prefix: String?, pct: Double?)
            /// Plain text chip (cost / tokens / model).
            case text(String)
        }
        var items: [Item]
        var tooltip: String
    }
}

/// The status-item chrome, isolated behind `Equatable` so a no-op @Query
/// refresh is a true no-op down to AppKit's `cacheDisplayInRect`. There
/// is deliberately NO animation — the colored icon and numbers carry the
/// signal; the old one-shot scale pulse was removed as wasted per-frame
/// work in an always-on status item.
private struct MenuBarLabelContent: View, Equatable {
    let rendered: MenuBarLabel.Render

    nonisolated static func == (lhs: MenuBarLabelContent, rhs: MenuBarLabelContent) -> Bool {
        lhs.rendered == rhs.rendered
    }

    var body: some View {
        // No outer padding — the NSStatusBarButton already adds the
        // menu-bar's standard side margins. Spacing between chips comes
        // from the HStack's own `spacing:`.
        HStack(spacing: 6) {
            ForEach(Array(rendered.items.enumerated()), id: \.offset) { _, item in
                itemView(item)
            }
        }
        .help(rendered.tooltip)
    }

    @ViewBuilder
    private func itemView(_ item: MenuBarLabel.Render.Item) -> some View {
        switch item {
        case let .symbol(name, band):
            // `.monochrome` (not `.palette`) so the symbol renders in one
            // solid tint at full strength like Battery / Wi-Fi.
            Image(systemName: name)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Self.bandColor(band))
        case let .rings(five, seven):
            // Apple Watch-style dual-ring icon. Outer = 5h, inner = 7d.
            ActivityRings(rings: [
                ActivityRings.Ring(progress: five / 100,
                                   color: UsageBand(percentage: five).color),
                ActivityRings.Ring(progress: seven / 100,
                                   color: UsageBand(percentage: seven).color)
            ])
            .frame(width: 14, height: 14)
        case let .percent(prefix, pct):
            // Percent text warms to red only at the red band — yellow /
            // orange stay primary (colored text reads poorly in the menu
            // bar); the icon carries the band coloring.
            if let pct {
                Text((prefix ?? "") + "\(Int(pct.rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(UsageBand(percentage: pct) == .red ? Color.red : Color.primary)
            } else {
                Text((prefix ?? "") + "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        case let .text(text):
            Text(text)
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
    }

    /// Icon tint by band. `.primary` at green/nil so Pacer reads as a
    /// healthy, active item next to Battery / Wi-Fi rather than greyed
    /// out at the common low-usage state.
    private static func bandColor(_ band: UsageBand?) -> Color {
        switch band {
        case .green, nil: return .primary
        case .yellow:     return .yellow
        case .orange:     return .orange
        case .red:        return .red
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
    /// trailing caption goes red "limit in 6 hr" when a pre-reset hit is
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
                    if s.usedPercentage.rounded() >= 100 {
                        // Already at the cap (as displayed): say so, never a
                        // future crossing. The outlook's last-refit snapshot can
                        // lag a point behind the live reading and would
                        // otherwise read "limit in N min" beside a "100%".
                        Text("at the limit")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    } else if let o = outlook, let eta = IntelligenceFormatting.relativeCrossingPhrase(o) {
                        Text("limit \(eta)")
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
