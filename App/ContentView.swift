import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// Top-level shell. Sidebar-driven NavigationSplitView with five
/// destinations: Dashboard / History / Projects / Models / Settings.
/// ⌘1..⌘4 jumps between the activity destinations; ⌘, jumps to
/// Settings (the standard macOS shortcut, which `PacerApp` translates
/// into a `.pacerOpenSettings` notification we observe here).
///
/// Why a sidebar instead of the macOS-native TabView the previous
/// version used: pro Mac apps the user reaches for daily — Linear,
/// Things, Reeder, MoneyMoney, Apple's own System Settings — all use a
/// sidebar layout. It scales better when we want to add destinations,
/// gives us room for a freshness/status indicator at the top of the
/// chrome, and avoids the "settings panel" feel that top tabs bring.
struct ContentView: View {
    /// One concrete destination. The `keyboardShortcut` modifier needs
    /// its own enum value per row, so we keep these as cases (not
    /// configurable strings).
    /// `String, RawRepresentable` so `@SceneStorage` can persist the
    /// selected destination across launches. Without this the sidebar
    /// always reset to Dashboard on relaunch — annoying for users who
    /// live in History or Projects.
    enum Destination: String, Hashable, Identifiable, CaseIterable {
        case dashboard, history, projects, models, settings
        var id: String { rawValue }

        var title: String {
            switch self {
            case .dashboard: return "Dashboard"
            case .history:   return "History"
            case .projects:  return "Projects"
            case .models:    return "Models"
            case .settings:  return "Settings"
            }
        }

        /// SF Symbol name. Outline when not selected, filled when
        /// selected — matches macOS Sequoia's System Settings
        /// convention. Symbols without a clean filled variant
        /// (`gauge.with.dots.needle.*`, `calendar`) return the same
        /// string for both states.
        func systemImage(selected: Bool) -> String {
            switch self {
            case .dashboard: return "gauge.with.dots.needle.bottom.50percent"
            case .history:   return "calendar"
            case .projects:  return selected ? "folder.fill"    : "folder"
            case .models:    return selected ? "cpu.fill"       : "cpu"
            case .settings:  return selected ? "gearshape.fill" : "gearshape"
            }
        }
    }

    @SceneStorage("pacer.sidebar.selection")
    private var selectionRaw: String = Destination.dashboard.rawValue

    private var selection: Binding<Destination> {
        Binding(
            get: { Destination(rawValue: selectionRaw) ?? .dashboard },
            set: { selectionRaw = $0.rawValue }
        )
    }

    /// Cap the @Query so the window-title computation doesn't fan
    /// out to thousands of rows — we just need the most recent
    /// sample per window.
    @Query(ContentView.recentRateLimitDescriptor)
    private var recentRateLimits: [RateLimitSample]

    private static let recentRateLimitDescriptor: FetchDescriptor<RateLimitSample> = {
        var d = FetchDescriptor<RateLimitSample>(
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
        )
        d.fetchLimit = 8
        return d
    }()

    /// Composed window subtitle — "5h 23% • 7d 41%". When dragged to
    /// the Dock or Cmd+Tab'd, macOS shows the title bar text; with
    /// this in place the user gets at-a-glance pacing without
    /// surfacing the dashboard.
    private var windowSubtitle: String {
        let fiveHour = recentRateLimits.first { $0.window == "five_hour" }
        let sevenDay = recentRateLimits.first { $0.window == "seven_day" }
        let parts: [String?] = [
            fiveHour.map { "5h \(Int($0.usedPercentage.rounded()))%" },
            sevenDay.map { "7d \(Int($0.usedPercentage.rounded()))%" }
        ]
        return parts.compactMap { $0 }.joined(separator: " • ")
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .navigationTitle(selection.wrappedValue.title)
                .navigationSubtitle(windowSubtitle)
                .toolbar {
                    // Trailing toolbar slot: live freshness pill. The
                    // sidebar used to host this; moving it to the
                    // toolbar matches Linear / Reeder / Things / etc.
                    // and frees the sidebar to be all-navigation.
                    ToolbarItem(placement: .primaryAction) {
                        ToolbarFreshness()
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        // 880×620 instead of the prior 940×660 — small enough to fit
        // a 13" laptop's window-arranged half-screen, large enough
        // that the hero strip's three tiles don't squeeze. User can
        // still resize larger; this is just the floor.
        .frame(minWidth: 880, minHeight: 620)
        // ⌘1..⌘4 are wired through PacerApp's CommandGroup so they live
        // in the menu-bar responder chain — more reliable than hidden
        // Buttons inside .background, which were missing keystrokes.
        // The notification carries the destination as its `object`.
        .onReceive(NotificationCenter.default.publisher(for: .pacerSelectDestination)) { note in
            if let dest = note.object as? Destination {
                selectionRaw = dest.rawValue
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pacerOpenSettings)) { _ in
            selectionRaw = Destination.settings.rawValue
        }
        // Consume any one-shot destination queued by `PacerAppDelegate`
        // (a status-menu "Settings…" click when no window was open).
        // The notification path above handles the window-was-already-
        // open case; this `onAppear` handles the window-just-mounted
        // case. The static is cleared on read so a normal close/reopen
        // doesn't trigger the same navigation a second time.
        .onAppear {
            if let pending = PacerAppDelegate.pendingDestination {
                PacerAppDelegate.pendingDestination = nil
                selectionRaw = pending.rawValue
            }
        }
    }

    // MARK: - Sidebar

    /// Left pane. Custom-rendered list (rather than the default
    /// `List`/`Section` pair) so we can place the app brand at top and
    /// pin Settings to the bottom — both common macOS sidebar idioms
    /// that `List` makes awkward.
    @ViewBuilder
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarBrand
                .padding(.horizontal, 12)
                .padding(.top, 16)
                .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SidebarSection(title: "Overview") {
                        SidebarItem(
                            destination: .dashboard,
                            selection: selection
                        )
                    }

                    SidebarSection(title: "Activity") {
                        SidebarItem(destination: .history, selection: selection)
                        SidebarItem(destination: .projects, selection: selection)
                        SidebarItem(destination: .models, selection: selection)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }

            Spacer(minLength: 0)

            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 0) {
                SidebarItem(
                    destination: .settings,
                    selection: selection
                )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        // `.navigationSplitViewColumnWidth(min:ideal:max:)` is the
        // single source of truth for sidebar width — the redundant
        // `.frame(...)` we used to set on the same VStack confused
        // the resize handle and let the user drag the divider past
        // the intended bounds. Drop the .frame so SwiftUI clamps
        // resize gestures to these limits cleanly.
        //
        // `min: 220` rather than the prior 200 — at 200pt the
        // "Dashboard" / "History" rows ran right up to the trailing
        // edge of the selection background, eating the comfortable
        // breathing room the rest of the layout has. 220 gives the
        // selected-row pill room without making the sidebar feel wide.
        .navigationSplitViewColumnWidth(min: 220, ideal: 230, max: 280)
        // Keep the standard sidebar toggle (View → Show / Hide
        // Sidebar, plus the toolbar button). Previously removed for
        // visual cleanliness — but combined with the resize divider,
        // the user could drag-collapse the sidebar with no clear way
        // to bring it back. The toggle is the recovery path.
        // Make the sidebar a focus target so up/down arrows cycle
        // through destinations, matching macOS-native sidebar nav.
        // .focusEffectDisabled keeps the system focus ring off the
        // big VStack — individual SidebarItem rows surface selection
        // with their own background tint.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
    }

    /// Cycle the sidebar selection by `delta` positions, wrapping at
    /// the ends. Only the navigation destinations participate — we
    /// skip Settings on cycle so up/down doesn't bounce out of the
    /// usage views into Settings every time you reach the bottom of
    /// "Activity."
    private func moveSelection(by delta: Int) {
        let order: [Destination] = [.dashboard, .history, .projects, .models, .settings]
        let current = selection.wrappedValue
        guard let idx = order.firstIndex(of: current) else {
            selection.wrappedValue = .dashboard
            return
        }
        let next = (idx + delta + order.count) % order.count
        selection.wrappedValue = order[next]
    }

    /// Top-of-sidebar brand block: app glyph + name. Freshness moved
    /// to the toolbar (matches macOS-native pattern). Sidebar header
    /// now reads as a clean brand mark with no inline status.
    private var sidebarBrand: some View {
        HStack(spacing: 10) {
            Image("PacerLogo")
                .resizable()
                .interpolation(.high)
                .frame(width: 26, height: 26)
            // `.title3` ≈ prior 15pt; Dynamic-Type-aware so the brand
            // mark scales with Display & Text Size.
            Text("Pacer")
                .font(.title3)
                .fontWeight(.semibold)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection.wrappedValue {
        case .dashboard: DashboardView()
        case .history:   HistoryView()
        case .projects:  ProjectsView()
        case .models:    ModelsView()
        case .settings:  SettingsView()
        }
    }
}

// MARK: - Sidebar building blocks

private struct SidebarSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .padding(.bottom, 2)
            content()
        }
    }
}

private struct SidebarItem: View {
    let destination: ContentView.Destination
    @Binding var selection: ContentView.Destination
    @State private var hovering: Bool = false

    private var isSelected: Bool { selection == destination }

    var body: some View {
        Button {
            selection = destination
        } label: {
            HStack(spacing: 10) {
                Image(systemName: destination.systemImage(selected: isSelected))
                    .font(.body.weight(.medium))
                    .frame(width: 18, alignment: .center)
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                Text(destination.title)
                    .font(.body)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(background)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var background: Color {
        if isSelected {
            return Color.accentColor
        }
        if hovering {
            return Color.primary.opacity(0.06)
        }
        return Color.clear
    }
}

// MARK: - Toolbar freshness chip

/// Live "● live" / "● 3m ago" pill living in the window toolbar.
/// Reads the same most-recent activity sources the dashboard header
/// uses, capped to 1-row fetches so it never materializes the full
/// SwiftData store on save.
///
/// Previously lived in the sidebar header; moved to the toolbar to
/// match macOS-native chrome conventions (Linear / Reeder / Things
/// all surface live state in their toolbars, not their sidebars).
private struct ToolbarFreshness: View {
    @Query(ToolbarFreshness.tokenProbe) private var tokens: [TokenSample]
    @Query(ToolbarFreshness.rateLimitProbe) private var rateLimits: [RateLimitSample]
    @Query(ToolbarFreshness.sessionProbe) private var sessions: [SessionInfo]
    @Query private var scanMeta: [ClaudeCodeMeta]

    init() {
        let key = ClaudeCodeMetaKey.lastIncrementalScanAt
        _scanMeta = Query(filter: #Predicate<ClaudeCodeMeta> { $0.key == key })
    }

    private static let tokenProbe: FetchDescriptor<TokenSample> = {
        var d = FetchDescriptor<TokenSample>(sortBy: [SortDescriptor(\.sampledAt, order: .reverse)])
        d.fetchLimit = 1
        return d
    }()

    private static let rateLimitProbe: FetchDescriptor<RateLimitSample> = {
        var d = FetchDescriptor<RateLimitSample>(sortBy: [SortDescriptor(\.sampledAt, order: .reverse)])
        d.fetchLimit = 1
        return d
    }()

    /// Most-recent session row for the live-activity overlay. Cap to
    /// 1 — same probe pattern as the other two; we only ever read
    /// `firstSeenAt` / `lastSeenAt` from `.first`.
    private static let sessionProbe: FetchDescriptor<SessionInfo> = {
        var d = FetchDescriptor<SessionInfo>(sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)])
        d.fetchLimit = 1
        return d
    }()

    /// `.active` when the latest SessionInfo's lastSeenAt is within
    /// `LiveSessionActivity.activeThreshold`. We only ever surface
    /// the active state in the toolbar — recent/idle is covered by
    /// the regular freshness label.
    private var sessionActivity: LiveSessionActivity? {
        sessions.first.map { LiveSessionActivity.from(lastSeen: $0.lastSeenAt) }
    }

    private var lastActivity: Date? {
        let candidates: [Date?] = [
            tokens.first?.sampledAt,
            rateLimits.first?.sampledAt,
            parseScanMeta(),
        ]
        return candidates.compactMap { $0 }.max()
    }

    private func parseScanMeta() -> Date? {
        guard let raw = scanMeta.first?.value else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: raw) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: raw)
    }

    private var freshness: FreshnessPulse.Freshness {
        guard let last = lastActivity else { return .none }
        let age = Date().timeIntervalSince(last)
        if age < 120 { return .live }
        if age < 600 { return .recent }
        return .stale
    }

    private var label: String {
        // "active" specifically means Claude Code is generating right
        // now (most-recent SessionInfo.lastSeenAt within 5 min). The
        // prior version of this label included an elapsed-since-
        // session-start duration ("active · 9h 0m") — but the
        // most-recent session by `lastSeenAt` flips between rows when
        // the user has multiple long-running sessions in flight, so
        // the duration jumped between unrelated session start times.
        // "active" alone is unambiguous; the tooltip carries the
        // detail for a hover.
        if sessionActivity == .active {
            return "active"
        }
        switch freshness {
        case .live:        return "live"
        case .recent, .stale:
            if let last = lastActivity { return pacerRelative(last) }
            return "—"
        case .none:        return "no data yet"
        }
    }

    /// Long-form tooltip on hover so the user can see the exact
    /// timestamp without parsing the relative label.
    private var tooltip: String {
        if sessionActivity == .active, let s = sessions.first {
            let f = DateFormatter()
            f.dateStyle = .none
            f.timeStyle = .medium
            return "Claude Code active — last write \(f.string(from: s.lastSeenAt))"
        }
        if let last = lastActivity {
            let f = DateFormatter()
            f.dateStyle = .short
            f.timeStyle = .medium
            return "Last activity: \(f.string(from: last))"
        }
        return "No activity yet."
    }

    var body: some View {
        HStack(spacing: 5) {
            FreshnessPulse(state: freshness)
            Text(label)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(Color.primary.opacity(0.06))
        )
        // Without this the NSToolbar host compresses the pill below its
        // ideal height when the window mounts from the menu-bar "Open
        // Pacer" path, clipping the Capsule's top edge (issue #1). Pin
        // both axes to the intrinsic size so the toolbar centers the
        // pill at full height instead of squashing it.
        .fixedSize()
        .help(tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Activity status: \(label)")
        .accessibilityHint(tooltip)
    }
}

extension Notification.Name {
    /// Fired by the Cmd+, command and the menu-bar Settings button. The
    /// main `ContentView` observes it and flips its sidebar selection
    /// to Settings — single source of truth for "show settings" without
    /// a separate Settings scene.
    static let pacerOpenSettings = Notification.Name("PacerOpenSettings")

    /// Fired by the ⌘1..⌘4 menu commands in `PacerApp`. The notification's
    /// `object` is a `ContentView.Destination`. Posting from the menu-bar
    /// command group keeps the shortcuts in the responder chain (a hidden
    /// Button inside .background turned out to miss keystrokes) while
    /// keeping `selection` private to ContentView.
    static let pacerSelectDestination = Notification.Name("PacerSelectDestination")

    /// Fired by UI surfaces that just made a change requiring the
    /// scan coordinator to re-apply canonicalization or re-derive
    /// aggregates immediately — e.g. the bulk-merge sheet committing
    /// N new aliases. AppBackgroundService observes this and kicks
    /// `ScanCoordinator.runOnce()` so the user doesn't sit through
    /// the watcher's backstop interval waiting for their merge to
    /// take effect. Cheap to over-fire: the coordinator already
    /// skips overlapping cycles.
    static let pacerRequestImmediateScan = Notification.Name("PacerRequestImmediateScan")

    /// Fired by `AppBackgroundService` after the 24h LiteLLM pricing
    /// refresh writes a new snapshot. Views bound to per-model cost
    /// columns can subscribe to re-render with the new prices; existing
    /// rollup rows keep their already-recorded cost (pricing changes
    /// only affect samples added after this point).
    static let pacerPricingDidRefresh = Notification.Name("PacerPricingDidRefresh")
}
