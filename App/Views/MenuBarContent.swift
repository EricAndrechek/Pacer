import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// Builds the ordered menu-bar window set from live samples: the fixed 5-hour
/// and 7-day blocks (always present, even before the first sample lands) plus
/// every scoped per-model window in the latest poll (a "Fable" weekly cap and
/// the like). Shared by the status-item label (icon-driver resolution), the
/// dropdown (row listing), and Settings' driver picker so all three agree on
/// the exact same dynamic set. Fully dynamic — no window is named or counted
/// here; a scoped window Anthropic adds appears with zero code change and one
/// that vanishes drops out of the next `latestBatch`.
enum MenuBarWindowSource {
    /// `live` is the account's live meter values (`LiveMeterBoard`), read by
    /// the caller in its `body` so a new value redraws it; each window's
    /// number goes through `LiveMeterReadout` with the reading loaded here.
    static func items(
        fiveHour: LimitSamplePoint?,
        sevenDay: LimitSamplePoint?,
        scoped: [ScopedWindowRow],
        live: [String: LiveMeterValue] = [:],
        now: Date = Date()
    ) -> [MenuBarWindowItem] {
        func readout(_ key: String, _ at: Date?, _ pct: Double?, _ resets: Date?) -> LiveMeterReadout? {
            guard let at, let pct else { return nil }
            return LiveMeterReadout(reading: MeterReading(at: at, percent: pct, resetsAt: resets),
                                    live: live[key], now: now)
        }
        var items: [MenuBarWindowItem] = [
            MenuBarWindowItem(
                key: RateLimitWindowName.fiveHour, displayName: "5-hour",
                usedPercentage: fiveHour?.usedPercentage, resetsAt: fiveHour?.resetsAt,
                duration: MenuBarWindows.fiveHourDuration, group: "",
                isScoped: false, isActive: false,
                readout: readout(RateLimitWindowName.fiveHour, fiveHour?.sampledAt,
                                 fiveHour?.usedPercentage, fiveHour?.resetsAt)),
            MenuBarWindowItem(
                key: RateLimitWindowName.sevenDay, displayName: "7-day",
                usedPercentage: sevenDay?.usedPercentage, resetsAt: sevenDay?.resetsAt,
                duration: MenuBarWindows.sevenDayDuration, group: "",
                isScoped: false, isActive: false,
                readout: readout(RateLimitWindowName.sevenDay, sevenDay?.sampledAt,
                                 sevenDay?.usedPercentage, sevenDay?.resetsAt)),
        ]
        // Latest poll only. Account-wide `session`/`weekly_all` rows are
        // excluded in the fetch (`LimitScope.modelScopedLimits`) rather than
        // here — they duplicate 5h/7d and were two thirds of the rows.
        for row in scoped.latestBatch() {
            items.append(MenuBarWindowItem(
                key: row.identity, displayName: row.label,
                usedPercentage: row.percent, resetsAt: row.resetsAt,
                duration: WindowSpec.scopedDuration(group: row.group), group: row.group,
                isScoped: true, isActive: row.isActive,
                readout: readout(row.identity, row.sampledAt, row.percent, row.resetsAt)))
        }
        return MenuBarWindows.ordered(items)
    }

    /// Bounded newest-first fetch for the scoped `limits[]` history — enough to
    /// resolve the latest poll's batch without scanning the append-only table.
    /// One poll writes a handful of scoped rows; 64 covers far more scoped
    /// windows than an account realistically has.
    /// A function rather than a `static let` because the bound and the scope
    /// have to be applied together. With every account writing this table, an
    /// unscoped "newest 64" can be entirely the other login's rows, and the
    /// caller would render its windows as this account's.
    static func recentScoped(account: String?) -> FetchDescriptor<UsageLimitSample> {
        LimitScope.modelScopedLimits(account: account, limit: 64)
    }

    /// The menu bar's window inputs, fetched once per change rather than once
    /// per body evaluation.
    ///
    /// These were `@Query`s. A `@Query` re-executes whenever the model context
    /// changes, and Pacer's context changes every scan cycle — so the menu bar
    /// re-ran two predicated fetches every couple of seconds, on the main
    /// thread, forever. A profile put **91 of the 92 main-thread samples in
    /// `MenuStatusContent.body` inside those two fetches**, and `windows` is
    /// computed more than once per body, so each evaluation paid twice.
    ///
    /// They were cheap before this session because they had no predicate and
    /// CoreData could serve them from its row cache. Adding `accountId == x`
    /// made every one a real fetch. The fix is not to un-scope them — that
    /// would show the wrong account's windows — but to stop re-running them
    /// when nothing has changed, which is the same signal-gated shape
    /// `PaceChartCard` uses and documents.
    @MainActor
    static func load(_ context: ModelContext, account: String?)
        -> (fixed: [LimitSamplePoint], scoped: [ScopedWindowRow]) {
        let fixed = ((try? context.fetch(LimitScope.rateLimits(account: account, limit: 8))) ?? [])
            .map(\.limitPoint)
        let scoped = ((try? context.fetch(recentScoped(account: account))) ?? [])
            .map(\.scopedWindowRow)
        return (fixed, scoped)
    }
}

/// What renders in the menu bar status item. The displayed content is
/// driven by `PacerSettings.menuBarChipItems()` — an ordered list the user
/// configures in Settings → Menu bar. Any combination of:
///
///   - `.icon`         — `MenuBarIconStyle`-driven SF Symbol; color
///                       warms with the 5-hour usage band.
///   - `.fiveHourPct`  — current 5-hour rate-limit utilization.
///   - `.sevenDayPct`  — current 7-day rate-limit utilization.
///   - `.todayCost`    — today's spend in USD.
///   - `.todayTokens`  — today's token total (K / M / B suffixed).
///   - `.activeModel`  — model name of the most recent TokenSample.
///   - a scoped per-model window chip (`scoped_pct:<identity>`) — that
///                       window's live utilization as "<name> <pct>%"
///                       (e.g. "Fable 49%"); dormant (dropped) when the
///                       window isn't in the account's latest poll.
///
/// Empty chip list = host tears the NSStatusItem down (handled in
/// `PacerAppDelegate.rebuildMenuBarForCurrentChips`).
struct MenuBarLabel: View {
    /// Cap the fetch — we only ever look at the most-recent sample per
    /// window. Without the cap, every SwiftData save materialized the
    /// full ~4k-row history just to fire the menu-bar label re-render.
    @State private var rateSamples: [LimitSamplePoint] = []

    /// Today's aggregates for cost / tokens chips. Filtered by date so
    /// the daemon's per-scan re-fire stays bounded (~5 model rows max).
    @Query private var globalToday: [DailyAggregate]
    @Query private var scopedToday: [AccountDailyAggregate]
    @State private var menuScope = UsageScope.shared

    /// Follows the window's account scope. The menu bar is ambient, so an
    /// argument exists for it always showing every account — but two numbers
    /// on screen at once disagreeing about "today's cost" is worse than
    /// either answer, and the scope is a deliberate choice the user made.
    private var todayAggregates: [DailyRow] {
        menuScope.isAll ? globalToday.map(\.dailyRow) : scopedToday.map(\.dailyRow)
    }

    /// Single most recent TokenSample, for the active-model chip. Cap
    /// to 1 — we never need any other field besides `model`.
    ///
    /// Two of them, chosen at read time, the same shape as the today
    /// aggregates above: unscoped this named whichever account wrote last, so
    /// a menu bar scoped to one account showed the other's model.
    @Query(MenuBarLabel.recentTokenSampleDescriptor)
    private var recentSamples: [TokenSample]
    @Query private var scopedRecentSamples: [TokenSample]

    /// Recent scoped `limits[]` rows — the source of the per-model windows the
    /// icon driver can point at. Bounded so this always-visible label never
    /// scans the append-only scoped history.
    @State private var scopedSamples: [ScopedWindowRow] = []

    /// "Something was written" — see `RateLimitWriteSignal`. The scoped fetch
    /// it gates is the expensive part, and runs once per write rather than once
    /// per body evaluation.
    @Environment(\.modelContext) private var menuModelContext

    /// What `reloadWindows` reads, as one key. Each part is read here so that
    /// its change re-runs the load: the write signal, whose account's limits
    /// (through the observable scope, so a scope or login switch counts; the
    /// store lookup is only the cold-start fallback), and the accounts chips
    /// are pinned to, so a chip added in Settings shows at once rather than
    /// after the next poll.
    var reloadKey: String {
        let account = menuScope.limitAccountId ?? UsageScope.limitAccountId(in: menuModelContext)
        let pinned = Set(chipItems.compactMap(\.pinnedAccountId)).sorted().joined(separator: ",")
        return "\(RateLimitWriteSignal.shared.generation):\(account ?? "none"):\(pinned)"
    }

    @MainActor
    func reloadWindows() {
        let account = UsageScope.limitAccountId(in: menuModelContext)
        let loaded = MenuBarWindowSource.load(menuModelContext, account: account)
        rateSamples = loaded.fixed
        scopedSamples = loaded.scoped
        loadedAccount = account

        // Chips pinned to a named account need that account's own windows, not
        // the scoped one's. Loaded only for accounts a chip actually names, so
        // a user who pins nothing pays nothing — the ordinary case.
        var pinned: [String: (fixed: [LimitSamplePoint], scoped: [ScopedWindowRow])] = [:]
        for id in Set(chipItems.compactMap(\.pinnedAccountId)) {
            pinned[id] = MenuBarWindowSource.load(menuModelContext, account: id)
        }
        pinnedLoaded = pinned
        let all = (try? menuModelContext.fetch(FetchDescriptor<Account>())) ?? []
        accountLabels = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.shortLabel) })
    }

    /// Called with the tooltip text whenever it changes, and once on appear.
    ///
    /// The status item mirrors this onto `NSStatusItem.button.toolTip`, the
    /// only tooltip the item has: on macOS 26+ a `.help()` inside SwiftUI
    /// content hosted in a menu-bar surface produces no tooltip at all, and
    /// on macOS 15, where it does, it sat over the button's and showed text
    /// frozen at the last redraw. AppKit's `NSView.toolTip` works on every OS
    /// Pacer supports, and this keeps its ages current (#318).
    private let onTooltipChange: ((String) -> Void)?

    init(onTooltipChange: ((String) -> Void)? = nil) {
        self.onTooltipChange = onTooltipChange
        let today = TokenSample.formatDate(Date())
        // Read from the shared store rather than taken as a parameter: the
        // menu bar is constructed by AppKit, not by a parent view that could
        // pass it down. Its host is built once and kept, so a scope change
        // reaches this only because `MenuBarKeyedContent` rebuilds the view
        // when the scope moves.
        let acct = UsageScope.storedAccountId ?? UsageScope.noAccountSentinel
        _globalToday = Query(
            filter: #Predicate<DailyAggregate> { $0.date == today }
        )
        _scopedToday = Query(
            filter: #Predicate<AccountDailyAggregate> {
                $0.date == today && $0.accountId == acct
            }
        )
        var scopedRecent = FetchDescriptor<TokenSample>(
            predicate: #Predicate<TokenSample> { $0.accountId == acct },
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)])
        scopedRecent.fetchLimit = 1
        _scopedRecentSamples = Query(scopedRecent)
    }

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

    /// Which window's utilization paints the single-glyph icon (gauge / ring /
    /// dot). Chosen explicitly; default is the 5-hour window's key. A scoped
    /// identity when the user picked a per-model window; falls back to the
    /// 5-hour window if that window vanishes. (A legacy "" still resolves to
    /// 5-hour.) Unused by the `.activityRings` style, which draws `ringWindowKeys`.
    @AppStorage(PacerSettings.Key.menuBarIconDriver, store: PacerSettings.store)
    private var iconDriverRaw: String = MenuBarWindows.defaultDriverKey

    /// Ordered CSV of up to 3 window keys the `.activityRings` icon draws as
    /// concentric rings (outer → inner). Default is the fixed 5h+7d pair.
    @AppStorage(PacerSettings.Key.menuBarRingWindows, store: PacerSettings.store)
    private var ringWindowsRaw: String = "five_hour,seven_day"

    // MARK: - Derived state

    /// The readings of each account a chip names, keyed by account id.
    @State private var pinnedLoaded: [String: (fixed: [LimitSamplePoint], scoped: [ScopedWindowRow])] = [:]

    /// Those accounts' windows, each through its own live values. Built in
    /// `body`, so a new live value redraws the chip.
    private func pinnedWindows(_ id: String) -> [MenuBarWindowItem]? {
        guard let loaded = pinnedLoaded[id] else { return nil }
        return MenuBarWindowSource.items(
            fiveHour: loaded.fixed.first { $0.window == RateLimitWindowName.fiveHour },
            sevenDay: loaded.fixed.first { $0.window == RateLimitWindowName.sevenDay },
            scoped: loaded.scoped,
            live: LiveMeterBoard.shared.values[id] ?? [:])
    }
    /// Short names for those accounts, so a chip reads "personal 42%".
    @State private var accountLabels: [String: String] = [:]

    private var chipItems: [PacerSettings.MenuBarChipItem] {
        // Re-parse from the @AppStorage CSV so SwiftUI body-eval picks
        // up changes immediately (PacerSettings.menuBarChipItems() reads
        // the same store but isn't reactive on its own). Unknown/empty
        // tokens skipped, duplicates collapsed, order preserved.
        PacerSettings.MenuBarChipItem.parseList(chipsRaw)
    }

    private var fiveHour: LimitSamplePoint? {
        rateSamples.first { $0.window == "five_hour" }
    }

    private var sevenDay: LimitSamplePoint? {
        rateSamples.first { $0.window == "seven_day" }
    }

    /// `windows` is read several times per body (the icon driver, the chips,
    /// the rings), so fold it once.
    private var windowsCache: [MenuBarWindowItem] { windows }

    private var iconStyle: PacerSettings.MenuBarIconStyle {
        PacerSettings.MenuBarIconStyle(rawValue: iconRaw) ?? .gaugeNeedle
    }

    /// Every rate-limit window currently in play (5h, 7d, each scoped) — the
    /// candidate set the icon driver picks from — each at its live value.
    /// The board is read here, inside `body`'s evaluation, so a new live
    /// value redraws the label; `Render`'s equality keeps that from
    /// re-rasterizing the status item unless a drawn number moved.
    private var windows: [MenuBarWindowItem] {
        MenuBarWindowSource.items(fiveHour: fiveHour, sevenDay: sevenDay, scoped: scopedSamples,
                                  live: loadedAccount.flatMap { LiveMeterBoard.shared.values[$0] } ?? [:])
    }

    /// Whose readings `rateSamples` are: the live values must be the same
    /// account's, or a scope switch could pair one login's reading with the
    /// other's estimate for the moment before the reload lands.
    @State private var loadedAccount: String?

    /// The window whose utilization drives the icon: the user's pick when it's
    /// present, else the 5-hour anchor. `nil` only with no windows at all.
    private var driverWindow: MenuBarWindowItem? {
        MenuBarWindows.resolveDriver(key: iconDriverRaw, windows: windows)
    }

    /// Ordered ring-window keys parsed from the @AppStorage CSV (reactive on
    /// body-eval, unlike `PacerSettings.menuBarRingWindowKeys()`). Deduped, cap
    /// at 3; resolution against `windows` (skipping vanished ones) happens in
    /// `MenuBarWindows.resolveRingWindows`.
    private var ringWindowKeys: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for token in ringWindowsRaw.split(separator: ",") {
            let key = token.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            out.append(key)
            if out.count == MenuBarWindows.maxRingWindows { break }
        }
        return out
    }

    /// Icon band from the driver window's utilization. Auto (the default)
    /// resolves to the 5-hour window, so the icon looks exactly as it did
    /// before the driver picker existed.
    private var band: UsageBand? {
        driverWindow?.usedPercentage.map { UsageBand(percentage: $0) }
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
        todayAggregates.reduce(0) { $0 + $1.tokens.all }
    }

    private var activeModel: String? {
        let latest = menuScope.isAll ? recentSamples.first : scopedRecentSamples.first
        return latest.map { pacerModelDisplayName($0.model) }
    }

    /// Whether the 5h-percent chip should prefix itself with "5h ". When
    /// it's the only window chip on screen, the prefix is redundant; when
    /// the 7-day chip or any scoped-window chip (each of which carries its
    /// own name, e.g. "Fable 49%") is also visible, the "5h " prefix keeps
    /// the bare percentage unambiguous.
    private var fiveHourNeedsPrefix: Bool {
        chipItems.contains { item in
            switch item {
            case .fixed(.sevenDayPct): return true
            case .scoped:              return true
            case .account:             return true
            default:                   return false
            }
        }
    }

    /// Tooltip shown on hover. Apple's Battery / Wi-Fi / Volume status
    /// items all surface a one-line summary on hover; ours had nothing.
    /// We dump whatever the chips don't already show so the user can
    /// hover for the "everything else."
    ///
    /// Every window's number as the chips write it (an estimate with its
    /// decimal, #318) and the reading under it: "5h: 42.6% (read 42% 3m
    /// ago)". The reading is said every time, not only when the estimate
    /// differs, so the hover always answers "what did Anthropic last say".
    ///
    /// `aged: false` leaves the ages out. That version is what `Render`
    /// carries, so the status item re-rasterizes on a number moving, never
    /// on a minute passing; the aged one goes straight to AppKit
    /// (`onTooltipChange`), on every change and on each instant of
    /// `PacerReadAge.Schedule`, with every other age on screen.
    private func tooltip(aged: Bool, now: Date = PacerClock.now) -> String {
        // Every window's used% (5h / 7d / each scoped), short-labelled. With no
        // scoped windows this reproduces the prior "5h: X% • 7d: Y%" line.
        var parts: [String] = []
        for w in windows {
            guard let pct = w.usedPercentage else { continue }
            let label: String
            switch w.key {
            case RateLimitWindowName.fiveHour: label = "5h"
            case RateLimitWindowName.sevenDay: label = "7d"
            default: label = w.displayName
            }
            var read = ""
            if let readout = w.readout {
                read = " (\(aged ? pacerMeterReadText(readout, now: now) : readout.readText(age: nil)))"
            }
            parts.append("\(label): \(PacerMeterFormat.percent(pct, isEstimate: w.isEstimate))\(read)")
        }
        // Tooltip's reset hint reads from the 5-hour sample. When that
        // sample's cycle has already ended (Pacer hasn't ingested a fresh
        // one — see #3/#4), don't show "resets X ago" — that confuses
        // "ago" as a past event when it's actually "Pacer is behind."
        if let resets = fiveHour?.resetsAt {
            let cycle = DisplayCycle.resolve(resetsAt: resets, duration: 5 * 3600)
            parts.append(cycle.isAwaiting
                ? "5h cycle reset, awaiting fresh sample"
                : (aged ? "resets \(pacerRelative(resets, now: now))" : "resets"))
        }
        if parts.isEmpty {
            return "Pacer — collecting…"
        }
        return parts.joined(separator: " • ")
    }

    /// When each window's reading behind the tooltip was taken.
    private var readingTimes: [Date] { windows.compactMap { $0.readout?.reading.at } }

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
        // `compactMap`: a scoped chip whose window isn't in the latest poll
        // resolves to nil and is dropped (dormant) — never drawn as a blank
        // or a phantom 0%.
        Render(items: chipItems.compactMap(resolve), tooltip: tooltip(aged: false))
    }

    /// Resolve one chip item to its render payload, or `nil` when it should be
    /// dropped from the label — a scoped-window chip whose window isn't in the
    /// active account's latest poll (dormant). Fixed chips always resolve.
    private func resolve(_ item: PacerSettings.MenuBarChipItem) -> Render.Item? {
        switch item {
        case .fixed(.icon):
            guard iconStyle == .activityRings else {
                return .symbol(name: symbolName, band: band)
            }
            // Resolve the configured ring windows against the live set (vanished
            // windows skipped, capped at 3, 5-hour fallback so it's never empty),
            // then hand the render the ordered utilization for each ring.
            let rings = MenuBarWindows.resolveRingWindows(keys: ringWindowKeys, windows: windows)
            // nil stays nil: a window with no reading draws as an empty grey
            // track, not as a 0% ring in the green band (#241).
            return .rings(rings.map(\.usedPercentage))
        case .fixed(.fiveHourPct):
            let w = windows.first { $0.key == RateLimitWindowName.fiveHour }
            return .percent(prefix: fiveHourNeedsPrefix ? "5h " : nil,
                            pct: w?.usedPercentage, isEstimate: w?.isEstimate ?? false)
        case .fixed(.sevenDayPct):
            let w = windows.first { $0.key == RateLimitWindowName.sevenDay }
            return .percent(prefix: "7d ", pct: w?.usedPercentage, isEstimate: w?.isEstimate ?? false)
        case .fixed(.todayCost):
            return .text(pacerCost(todayCost))
        case .fixed(.todayTokens):
            return .text(pacerTokens(todayTokens))
        case .fixed(.activeModel):
            return .text(activeModel ?? "—")
        case .account(let accountId, let key):
            // The account's own windows, and its own name in front of the
            // number — a chip that does not say whose percentage it is has no
            // business existing on a surface with several accounts on it.
            guard let window = pinnedWindows(accountId)?.first(where: { $0.key == key }),
                  let pct = window.usedPercentage else { return nil }
            let label = accountLabels[accountId] ?? window.displayName
            return .percent(prefix: "\(label) ", pct: pct, isEstimate: window.isEstimate)
        case .scoped(let identity):
            // Read the scoped window's live % from the same dynamic window set
            // the dropdown / icon-driver use (active account's latest batch).
            // Absent ⇒ dormant: return nil so the chip drops out.
            guard let window = windows.first(where: { $0.key == identity }),
                  let pct = window.usedPercentage else { return nil }
            // Same "<name> <pct>%" shape + band coloring as the fixed % chips,
            // e.g. "Fable 49%".
            return .percent(prefix: "\(window.displayName) ", pct: pct, isEstimate: window.isEstimate)
        }
    }

    var body: some View {
        // `.equatable()` gates AppKit's re-rasterization: the outer view
        // still re-evaluates on every save (cheap), but the hosted status
        // item only redraws when `rendered` actually differs.
        MenuBarLabelContent(rendered: rendered).equatable()
            .task(id: reloadKey) { reloadWindows() }
            // `initial: true` so the button gets a tooltip on first draw, not
            // only after the first value change.
            .onChange(of: rendered.tooltip, initial: true) { _, _ in
                onTooltipChange?(tooltip(aged: true))
            }
            // A new reading of the same value leaves the ageless text as it
            // was, and its "read … ago" would otherwise wait for the minute
            // push to say "now". Kept out of `Render`, so it re-rasterizes
            // nothing.
            .onChange(of: readingTimes) { _, _ in
                onTooltipChange?(tooltip(aged: true))
            }
            // The tooltip's ages, its "resets in 2 hr" and its
            // awaiting-a-new-cycle line are judged against the clock, and
            // this body re-runs only on data: idle, the hover hint kept the
            // last poll's countdown. Re-pushed on each whole minute, the
            // instants every age label in the app changes on
            // (`PacerReadAge.Schedule`), straight to AppKit, not through
            // SwiftUI state, so a hover hint never re-rasterizes the status
            // item.
            .task {
                while !Task.isCancelled {
                    let next = PacerReadAge.nextChange(after: Date())
                    try? await Task.sleep(for: .seconds(max(0.05, next.timeIntervalSinceNow)))
                    if Task.isCancelled { break }
                    onTooltipChange?(tooltip(aged: true, now: max(next, Date())))
                }
            }
    }

    /// Equatable render payload — captures exactly what the status item
    /// draws (resolved per-chip items + tooltip) so the chrome only
    /// re-renders on a real change.
    struct Render: Equatable {
        enum Item: Equatable {
            /// SF Symbol icon (gauge / ring-fill / dot styles); `band` tints it.
            case symbol(name: String, band: UsageBand?)
            /// Activity-ring icon: 1–3 concentric rings, outer → inner. Each
            /// element is that ring's window utilization (0–100), which drives
            /// both the ring fill and its per-ring band color; nil is a window
            /// with no reading yet.
            case rings([Double?])
            /// Window utilization chip; nil pct renders "—". `prefix` is the
            /// "5h " / "7d " disambiguator. `isEstimate`: the live meter's
            /// estimate, drawn with its decimal (#318).
            case percent(prefix: String?, pct: Double?, isEstimate: Bool)
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

    /// The items only: the tooltip is AppKit's (`onTooltipChange`) and this
    /// view does not draw it, so its text moving (an estimate's tenth, a new
    /// reading) must not re-rasterize the status item.
    nonisolated static func == (lhs: MenuBarLabelContent, rhs: MenuBarLabelContent) -> Bool {
        lhs.rendered.items == rhs.rendered.items
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
        case let .rings(percents):
            // Apple Watch-style concentric rings (outer → inner), one per
            // configured window. Each ring's fill + color come from its window's
            // utilization band. Three rings get a slightly larger frame so the
            // innermost stays legible; two rings keep the original 14pt so the
            // default icon is pixel-identical to before.
            ActivityRings(rings: percents.map { pct in
                guard let pct else { return ActivityRings.Ring(progress: 0, color: .secondary) }
                return ActivityRings.Ring(progress: pct / 100,
                                          color: UsageBand(percentage: pct).color)
            })
            .frame(width: percents.count >= 3 ? 17 : 14,
                   height: percents.count >= 3 ? 17 : 14)
        case let .percent(prefix, pct, isEstimate):
            // Percent text warms to red only at the red band — yellow /
            // orange stay primary (colored text reads poorly in the menu
            // bar); the icon carries the band coloring. A decimal marks an
            // estimate, "5h 51.3%"; a reading is whole (`PacerMeterValue`).
            // No animation either way.
            if let pct {
                PacerMeterValue(pct, isEstimate: isEstimate,
                                color: UsageBand(percentage: pct) == .red ? Color.red : Color.primary,
                                prefix: prefix ?? "")
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

    /// Icon tint by band. `.primary` at green so Pacer reads as a healthy,
    /// active item next to Battery / Wi-Fi rather than greyed out at the
    /// common low-usage state. nil — no reading for the driving window, as
    /// for a login Pacer has only just seen (#241) — is `.secondary`, the
    /// same grey as the chips' "—", so it never passes for 0%.
    private static func bandColor(_ band: UsageBand?) -> Color {
        switch band {
        case nil:         return .secondary
        case .green:      return .primary
        case .yellow:     return .yellow
        case .orange:     return .orange
        case .red:        return .red
        }
    }
}

/// Counts the status menu's openings, for the dropdown to read in its body.
///
/// Bumped by `PacerAppDelegate.menuWillOpen`, before it re-measures the
/// dropdown. See `MenuStatusContent.body`.
@MainActor
@Observable
final class StatusMenuOpening {
    static let shared = StatusMenuOpening()
    private(set) var count = 0
    func willOpen() { count &+= 1 }
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
    @State private var rateLimits: [LimitSamplePoint] = []
    @Query private var globalToday: [DailyAggregate]
    @Query private var scopedToday: [AccountDailyAggregate]
    @State private var menuScope = UsageScope.shared

    /// Follows the window's account scope. The menu bar is ambient, so an
    /// argument exists for it always showing every account — but two numbers
    /// on screen at once disagreeing about "today's cost" is worse than
    /// either answer, and the scope is a deliberate choice the user made.
    private var todayAggregates: [DailyRow] {
        menuScope.isAll ? globalToday.map(\.dailyRow) : scopedToday.map(\.dailyRow)
    }

    /// Recent scoped `limits[]` rows — the source of the dynamic per-model
    /// rows the dropdown lists beneath 5h / 7d. Bounded to the latest polls.
    @State private var scopedSamples: [ScopedWindowRow] = []

    /// "Something was written" — see `RateLimitWriteSignal`. The scoped fetch
    /// it gates is the expensive part, and runs once per write rather than once
    /// per body evaluation.
    @Environment(\.modelContext) private var menuModelContext

    /// One account's windows, for the concurrent case. Empty otherwise.
    struct AccountWindows: Identifiable {
        let id: String
        let label: String
        let isActive: Bool
        /// Other clients active on it (#245): "Desktop · Work". The CLI is
        /// `isActive`, said as "signed in".
        var clients: [String] = []
        let fixed: [LimitSamplePoint]
        let scoped: [ScopedWindowRow]

        /// Its windows at their live values. Built where `body` reads it,
        /// so a new value redraws the row.
        @MainActor var windows: [MenuBarWindowItem] {
            MenuBarWindowSource.items(
                fiveHour: fixed.first { $0.window == RateLimitWindowName.fiveHour },
                sevenDay: fixed.first { $0.window == RateLimitWindowName.sevenDay },
                scoped: scoped,
                live: LiveMeterBoard.shared.values[id] ?? [:])
        }
    }
    @State private var perAccount: [AccountWindows] = []
    /// Whose readings `rateLimits` are; see `MenuBarLabel.loadedAccount`.
    @State private var loadedAccount: String?

    /// The write signal and whose limits, both read here so either change
    /// re-runs the load. The account comes through the observable scope so a
    /// login switch under "All accounts" counts; the store lookup is only the
    /// cold-start fallback.
    var reloadKey: String {
        let account = menuScope.limitAccountId ?? UsageScope.limitAccountId(in: menuModelContext)
        // Which clients are active moves the grouping (#245), including when
        // a Desktop's 30 minutes run out with nothing written.
        return "\(RateLimitWriteSignal.shared.generation):\(account ?? "none")"
            + ":\(AccountClientsMonitor.shared.generation)"
    }

    @MainActor
    func reloadWindows() {
        let account = UsageScope.limitAccountId(in: menuModelContext)
        let loaded = MenuBarWindowSource.load(menuModelContext, account: account)
        rateLimits = loaded.fixed
        scopedSamples = loaded.scoped
        loadedAccount = account

        // Concurrent accounts get a group each; sequential ones do not.
        //
        // When two accounts run at the same time both caps bind at once, and
        // showing one is showing half. Used one at a time — the ordinary
        // switcher case — only one binds, and a second group is noise in a menu
        // that has to stay glanceable. The mode is decided from facts, not a
        // heuristic: a session-mode config root, or activation spans that
        // genuinely overlap.
        //
        // Several clients on several accounts at once is the same thing
        // (#245): Desktop running a routine on one account while the CLI is on
        // another binds both, so the menu groups whenever more than one
        // account is active, and shows the active ones.
        let clients = AccountClientsMonitor.shared
        let all = ((try? menuModelContext.fetch(FetchDescriptor<Account>())) ?? [])
            .sorted(by: Account.listOrder)
        guard let grouped = AccountClients.menuGroupAccounts(
            all: all.map(\.id),
            concurrent: AccountParallelism.mode(context: menuModelContext) == .concurrent,
            active: clients.activeAccountIds)
        else {
            perAccount = []
            return
        }
        perAccount = all.filter { grouped.contains($0.id) }.map { account in
            let its = MenuBarWindowSource.load(menuModelContext, account: account.id)
            return AccountWindows(
                id: account.id, label: account.shortLabel, isActive: account.isActive,
                clients: PacerClientChip.others(clients.active(on: account.id)).map(\.label),
                fixed: its.fixed, scoped: its.scoped)
        }
    }

    /// Engine answers for the outlook touches: per-window crossing (the
    /// trailing caption goes red "limit in 6 hr" when a pre-reset hit is
    /// projected) and the fixed Outlook row (projection once actionable,
    /// pace-vs-normal before). Row COUNT stays constant — NSMenuItem.view
    /// is measured at attach time, so conditional rows would clip.
    @Environment(\.usageEngines) private var engines
    @State private var outlooks: [String: UsageIntelligenceEngine.BurnOutlook] = [:]
    /// The same captions for each account group in the concurrent layout,
    /// keyed by account and then window. Each group asks its own account's
    /// engine. The groups used to read `outlooks`, which is keyed by window
    /// alone and comes from the scope's engine, so every account's 5h row
    /// showed the same "limit in N hr", including an account that was not
    /// burning at all (#163).
    @State private var groupOutlooks: [String: [String: UsageIntelligenceEngine.BurnOutlook]] = [:]
    @State private var todayEOD: Estimate?
    @State private var pacePercentile: Double?

    private func refreshEngine(
        scopedIdentities: [String],
        groups: [(account: String, scoped: [String])]
    ) async {
        // The menu bar follows the window's scope for spend, so its outlook
        // captions come from the same scope's engine — otherwise the dropdown
        // would show one account's cost above every account's projection.
        guard let host = engines else { return }
        let engine = host.engine(forAccount: UsageScope.storedAccountId)
        // Rate limits are per account: under "all accounts" the captions are
        // the active login's, from its own engine, the one the dashboard's
        // column for that account reads (#303).
        let limitsEngine = UsageScope.storedAccountId.map { host.engine(forAccount: $0) }
            ?? host.rateLimitEngine
        let groupEngines = groups.map {
            (account: $0.account, scoped: $0.scoped, engine: host.engine(forAccount: $0.account))
        }
        // Off the main actor — `burnOutlook` runs `DiurnalBurnModel.fit`, and a
        // launch-time profile found it doing exactly that on the main thread
        // from here. See `askEngine`.
        let ids = scopedIdentities
        let computed = await askEngine {
            () -> (outlooks: [String: UsageIntelligenceEngine.BurnOutlook],
                   groups: [String: [String: UsageIntelligenceEngine.BurnOutlook]],
                   eod: Estimate, pace: Estimate) in
            var perGroup: [String: [String: UsageIntelligenceEngine.BurnOutlook]] = [:]
            for group in groupEngines {
                perGroup[group.account] = await Self.outlooks(from: group.engine, scoped: group.scoped)
            }
            return (await Self.outlooks(from: limitsEngine, scoped: ids),
                    perGroup,
                    await engine.ask(.projectedCost(.today)),
                    await engine.ask(.pace))
        }
        outlooks = computed.outlooks
        groupOutlooks = computed.groups
        todayEOD = computed.eod
        pacePercentile = computed.pace.isInsufficient ? nil : computed.pace.value
    }

    /// One engine's caption for every fixed window, and for each scoped
    /// per-model window by identity, so each dynamic row gets the same
    /// "limit in N hr" caption as 5h and 7d.
    private nonisolated static func outlooks(
        from engine: UsageIntelligenceEngine, scoped ids: [String]
    ) async -> [String: UsageIntelligenceEngine.BurnOutlook] {
        var next: [String: UsageIntelligenceEngine.BurnOutlook] = [:]
        for w in RateLimitWindowKind.allCases {
            if let o = await engine.burnOutlook(window: w) { next[w.rawValue] = o }
        }
        for id in ids {
            if let o = await engine.burnOutlook(windowKey: id) { next[id] = o }
        }
        return next
    }

    init() {
        let today = TokenSample.formatDate(Date())
        // Read from the shared store rather than taken as a parameter: the
        // menu bar is constructed by AppKit, not by a parent view that could
        // pass it down. Its host is built once and kept, so a scope change
        // reaches this only because `MenuBarKeyedContent` rebuilds the view
        // when the scope moves.
        let acct = UsageScope.storedAccountId ?? UsageScope.noAccountSentinel
        _globalToday = Query(
            filter: #Predicate<DailyAggregate> { $0.date == today }
        )
        _scopedToday = Query(
            filter: #Predicate<AccountDailyAggregate> {
                $0.date == today && $0.accountId == acct
            }
        )
    }

    private var fiveHour: LimitSamplePoint? { rateLimits.first { $0.window == "five_hour" } }
    private var sevenDay: LimitSamplePoint? { rateLimits.first { $0.window == "seven_day" } }

    /// Every window the dropdown lists: 5h, 7d, then each scoped per-model
    /// window in the latest poll, in the dashboard's glued-heroes order, at
    /// their live values.
    private var windows: [MenuBarWindowItem] {
        MenuBarWindowSource.items(fiveHour: fiveHour, sevenDay: sevenDay, scoped: scopedSamples,
                                  live: loadedAccount.flatMap { LiveMeterBoard.shared.values[$0] } ?? [:])
    }

    /// The account whose limits are on screen, named only when more than one
    /// exists — a single-account user has no question to answer.
    private var limitAccountLabel: String? {
        let all = (try? menuModelContext.fetch(FetchDescriptor<Account>())) ?? []
        guard all.count > 1 else { return nil }
        return all.first { $0.id == UsageScope.limitAccountId(in: menuModelContext) }?.shortLabel
    }

    /// Whether that account is the one Claude Code is actually signed into.
    private var ownerIsSignedIn: Bool {
        let all = (try? menuModelContext.fetch(FetchDescriptor<Account>())) ?? []
        guard let shown = UsageScope.limitAccountId(in: menuModelContext) else { return true }
        return all.first { $0.isActive }?.id == shown
    }


    private var todayCost: Double {
        todayAggregates.reduce(0) { $0 + $1.totalCostUSD }
    }

    private var todayTokens: Int64 {
        todayAggregates.reduce(0) { $0 + $1.tokens.all }
    }

    /// The popover's fixed width. Named because the screenshot harness used to
    /// carry its own hard-coded copy (300pt) — close enough to pass unnoticed
    /// while the real value was 280, and a visible clip once it became 336.
    static let popoverWidth: CGFloat = 336

    var body: some View {
        // Width is fixed because the host (`NSMenuItem.view`) doesn't
        // re-measure when the SwiftUI body changes size — the menu tracks the
        // view's frame at attach time.
        //
        // 280pt was sized for a row of "pace 50% · resets in 2 hr." Then the
        // rows gained a 54pt label column, because scoped windows need naming
        // and "5-HOUR" has to sit somewhere. Nothing re-measured, so the two
        // captions absorbed the loss and both truncated: "pace 6…" cut a
        // percentage mid-number, and "resets in…" said nothing at all. A menu
        // whose numbers are ellipses is not a readout.
        //
        // 336pt is that 280 plus the label column and its gap, so the captions
        // get back exactly what they lost. Still inside the range Apple's own
        // status menus occupy (Wi-Fi ~280, Sound ~300).
        // Every open re-runs this body, so "pace 43%", "resets in 2 hr" and
        // the awaiting-a-new-cycle state are judged against the clock at the
        // moment the menu drops, not at the last poll or save. The host is
        // kept between opens and nothing else here moves with the clock.
        let _ = StatusMenuOpening.shared.count
        let windows = self.windows
        let scopedIds = windows.filter(\.isScoped).map(\.key)
        let groups = perAccount.map {
            (account: $0.id, scoped: $0.windows.filter(\.isScoped).map(\.key))
        }
        // Stable key so `.task(id:)` re-asks the engine when the window SET
        // changes (a scoped window appears / disappears, or an account group
        // comes or goes), not on every save.
        let windowKey = ([windows.map(\.key).joined(separator: ",")]
            + perAccount.map { "\($0.id):" + $0.windows.map(\.key).joined(separator: ",") })
            .joined(separator: "|")
        return VStack(alignment: .leading, spacing: 4) {
            // Whose limits these are, when that is a question at all.
            //
            // The menu bar reads the picked account, or the signed-in one when
            // the scope is "all accounts" — and said so nowhere. That is the
            // worst surface to leave ambiguous: it is the one you read
            // *without opening the app*, so there is no scope control on screen
            // to check against, and a percentage with no owner is a number you
            // cannot act on. Worse when the app is scoped to the account you
            // are not signed into: real limits, belonging to a login your
            // terminal is not billing.
            if perAccount.isEmpty, let owner = limitAccountLabel {
                HStack(spacing: 4) {
                    Text(owner)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if !ownerIsSignedIn {
                        Text("· not signed in")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 2)
                .help(ownerIsSignedIn
                      ? "These limits belong to the account Claude Code is using."
                      : "Pacer is scoped to this account, but Claude Code is signed "
                        + "into a different one — your next message is billed elsewhere.")
                .pacerToolTip(ownerIsSignedIn
                      ? "These limits belong to the account Claude Code is using."
                      : "Pacer is scoped to this account, but Claude Code is signed "
                        + "into a different one — your next message is billed elsewhere.")
            }
            if perAccount.isEmpty {
                // One pace row per window — 5h, 7d, then each scoped per-model
                // window. Fully dynamic: rows appear/vanish with the latest poll.
                ForEach(windows) { window in
                    paceRow(window: window, outlook: outlooks[window.key])
                }
            } else {
                ForEach(perAccount) { group in
                    HStack(spacing: 4) {
                        Text(group.label)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        if group.isActive {
                            Text("· signed in")
                                .font(.system(size: 10))
                                .foregroundStyle(.green)
                        }
                        ForEach(group.clients, id: \.self) { client in
                            Text("· \(client)")
                                .font(.system(size: 10))
                                .foregroundStyle(.green)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, group.id == perAccount.first?.id ? 0 : 6)
                    ForEach(group.windows) { window in
                        paceRow(window: window, outlook: groupOutlooks[group.id]?[window.key])
                    }
                }
            }
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
        .frame(width: Self.popoverWidth, alignment: .leading)
        // Re-ask when the window set changes (scoped windows discovered) so a
        // freshly-appeared row gets its outlook caption without waiting for the
        // next engine recompute.
        .task(id: reloadKey) { reloadWindows() }
        .task(id: windowKey) { await refreshEngine(scopedIdentities: scopedIds, groups: groups) }
        .onReceive(NotificationCenter.default.publisher(for: .pacerEngineDidRecompute)) { _ in
            Task { await refreshEngine(scopedIdentities: scopedIds, groups: groups) }
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
    private func paceRow(window: MenuBarWindowItem,
                         outlook: UsageIntelligenceEngine.BurnOutlook? = nil) -> some View {
        HStack(spacing: 8) {
            // Label column, fixed width so every row's gauge stays aligned. A
            // small accent dot marks the scoped window currently *in effect*.
            HStack(spacing: 3) {
                if window.isActive {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                        .help("Currently in effect")
                        .pacerToolTip("Currently in effect")
                }
                Text(window.displayName.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(width: 54, alignment: .leading)

            if let pct = window.usedPercentage, let resets = window.resetsAt {
                let cycle = DisplayCycle.resolve(resetsAt: resets, duration: window.duration)
                // One gauge for both states, dimmed while awaiting. As two
                // branches it was a new view at every cycle reset, the one
                // moment its fill animation is worth seeing (#140).
                //
                // No number inside: it is printed right beside the ring, and
                // an estimate's "50.7" did not fit a 22 pt ring. The reading
                // is drawn solid, the estimated stretch past it as a lighter
                // tail in the same colour (#318).
                CircularGauge(
                    reading: window.readout?.reading.percent ?? pct,
                    estimate: window.isEstimate ? pct : nil,
                    lineWidth: 3,
                    showsLabel: false
                )
                .frame(width: 22, height: 22)
                .opacity(cycle.isAwaiting ? 0.4 : 1)
                if cycle.isAwaiting {
                    // Stale cycle (Pacer hasn't polled a fresh one yet).
                    // Show a muted "awaiting" line — no pace math from
                    // prior-cycle numbers.
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
                    let band = PaceBand(usedPct: pct, paceEndPct: pacePct)

                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        PacerMeterValue(pct, isEstimate: window.isEstimate)
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            // 32pt fits "99%" and not "100%", so at the cap
                            // this wrapped to "100" over "%" (issue #125).
                            // minWidth keeps every two-digit row
                            // pixel-identical to before and lets only the
                            // three-digit case (and an estimate's decimal)
                            // take the room it needs.
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(minWidth: 32, alignment: .trailing)
                            // "read 42% 3m ago", and the estimate's number
                            // when it is one. The menu re-reads on every
                            // open, so the age is as of the open.
                            .pacerToolTip(window.readout.map { pacerMeterHelp($0) } ?? "")
                        // What Anthropic last read, beside the estimate it is
                        // built on: "51.3% read 50%" (#318). A reading needs
                        // no echo.
                        if let readout = window.readout, readout.isEstimate {
                            Text(readout.readPercentText)
                                .font(.system(size: 10))
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }

                    Text("pace \(Int(pacePct.rounded()))%")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(band.color)
                        // Never the column that gives way: "pace 6…" is a
                        // number cut in half, which reads as a smaller number
                        // rather than as missing text.
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    Spacer(minLength: 4)

                    // The trailing caption escalates to the projected cap hit
                    // when the engine sees one coming — same answer the
                    // dashboard tiles and the notification share.
                    // Whole points: an estimate of 99.6% has not reached
                    // the limit.
                    if (window.readout?.wholePercent ?? pct).rounded() >= 100 {
                        // Already at the cap (as displayed): say so, never a
                        // future crossing. The outlook's last-refit snapshot can
                        // lag a point behind the live reading and would
                        // otherwise read "limit in N min" beside a "100%".
                        Text("at the limit")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    } else {
                        // On the shared minute schedule: the menu re-reads on
                        // every open, and while it stays open the countdown
                        // still moves with every other age in the app.
                        TimelineView(PacerReadAge.Schedule()) { context in
                            if let o = outlook, o.willHitLimitBeforeReset,
                               let eta = ForecastChip.relativeCrossing(o.projectedFullAt, now: context.date) {
                                // Only the engine's confirmed claim goes red
                                // (#304): a single refit's point crossing was
                                // claimed here, and 87% of claimed 5-hour
                                // cycles never reached the cap.
                                Text("limit \(eta)")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.red)
                                    .lineLimit(1)
                            } else {
                                Text("resets \(pacerRelative(resets, style: .short, now: context.date))")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            } else {
                // No reading at all — an account seen before its first poll
                // (#241) — says so; a reading still missing its reset time
                // keeps the old wording.
                Text(window.usedPercentage == nil ? "no reading yet" : "collecting…")
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
                .pacerToolTip(tooltip ?? value)
        }
    }
}
