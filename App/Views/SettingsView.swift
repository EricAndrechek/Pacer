import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// Pacer's preferences UI. Embedded as the 5th destination in the main
/// window's sidebar (`Cmd+5`) and reachable via `Cmd+,` and the menu-
/// bar popover. All values bind to the App Group `UserDefaults` (via
/// `PacerSettings`) so the menu bar, in-process scan, and widgets pick
/// up changes without a restart.
///
/// Layout: scrolling stack grouped into three sections — General,
/// Notifications, Data — each introduced by a tracked uppercase label
/// (matching the sidebar's section style) above a column of
/// `PacerCard` surfaces. Earlier attempts used (a) an inner-sidebar
/// "tabs in tabs" pattern that mimicked macOS Sequoia System Settings
/// — overkill for a settings surface this small — and (b) `Form {
/// Section }.formStyle(.grouped)`, which on macOS Sequoia in dark mode
/// produced almost no visible row grouping and read as a flat list of
/// stuff with no chrome. PacerCard gives the same surface language as
/// the dashboard, so Settings reads as a continuation of the app
/// rather than its own visual idiom.
struct SettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                SettingsSection("General") {
                    StartupCard()
                    MenuBarCard()
                }
                SettingsSection("Notifications") {
                    RateLimitAlertsCard()
                    BurnRateAlertCard()
                    DailyCostAlertCard()
                    ResetAlertCard()
                    CustomRulesCard()
                    DailySummaryCard()
                    NotificationTestCard()
                }
                SettingsSection("Authentication") {
                    TokensCard()
                    DesktopCredentialsCard()
                }
                SettingsSection("Data") {
                    CostCalculationCard()
                    ProjectAliasesPointerCard()
                    StorageCard()
                    DatabaseCard()
                    LogsCard()
                }
                SettingsSection("Integrations") {
                    APIServerCard()
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 28)
            // Cap inner width so wide windows don't stretch the
            // cards across the entire detail pane; left-aligned so
            // the cards sit consistently flush with the sidebar.
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        // Click anywhere off a text field to dismiss its focus ring.
        #if canImport(AppKit)
        .modifier(DismissFocusOnOutsideClick())
        #endif
    }
}

// MARK: - Section header

/// Tracked uppercase label above a group of related cards. Mirrors the
/// sidebar's `SidebarSection` style at a slightly larger 12pt so it
/// reads cleanly across the wider detail pane while still sitting
/// quieter than the card titles below it.
private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PacerDesign.sectionSpacing) {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
                .padding(.bottom, -4)
            content()
        }
    }
}

// MARK: - Startup

private struct StartupCard: View {
    @State private var loginItemStatus: LoginItemController.Status = .unknown
    @State private var actionError: String?

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { loginItemStatus == .enabled },
            set: { newValue in
                actionError = nil
                if newValue {
                    do {
                        try LoginItemController.register()
                    } catch {
                        actionError = "Could not register: \(error.localizedDescription)"
                    }
                } else {
                    Task { @MainActor in
                        do {
                            try await LoginItemController.unregister()
                        } catch {
                            actionError = "Could not unregister: \(error.localizedDescription)"
                        }
                        refresh()
                    }
                }
                refresh()
            }
        )
    }

    var body: some View {
        PacerCard("Startup", content: {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Open Pacer at login", isOn: isEnabled)
                if loginItemStatus == .requiresApproval {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Approval required.")
                            .font(.caption)
                        Button("Open System Settings") {
                            LoginItemController.openSystemSettingsApproval()
                        }
                        .controlSize(.small)
                    }
                }
                if let err = actionError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }, footer: {
            Text("When enabled, Pacer launches at login and runs in the background — no window opens unless you open it explicitly. Data collection (JSONL scan + OAuth poll) starts automatically and continues even when no window is visible.")
        })
        .onAppear { refresh() }
    }

    private func refresh() {
        loginItemStatus = LoginItemController.currentStatus()
    }
}

// MARK: - Menu Bar

/// Lets the user pick any combination of menu-bar chips (icon, 5h%,
/// 7d%, today cost, today tokens, active model) and reorder them via
/// drag. Persists through `PacerSettings.setMenuBarChips`, which the
/// live `MenuBarLabel` reads via @AppStorage so changes apply in real
/// time without a relaunch.
///
/// Why a chip list rather than a fixed-style picker: the previous
/// 4-way enum (icon / percent / icon+percent / hidden) couldn't surface
/// today's cost, the 7-day window, or the active model. The chip list
/// scales to future additions and lets users build the exact at-a-
/// glance summary they want.
private struct MenuBarCard: View {
    @AppStorage(PacerSettings.Key.menuBarChips, store: PacerSettings.store)
    private var chipsRaw: String = "icon,five_hour_pct"

    @AppStorage(PacerSettings.Key.menuBarIconStyle, store: PacerSettings.store)
    private var iconRaw: String = PacerSettings.MenuBarIconStyle.gaugeNeedle.rawValue

    /// Local mutable mirror of the persisted chip order. We re-derive
    /// from the @AppStorage on every read and write back via
    /// `PacerSettings.setMenuBarChips`. The local array is what the
    /// `List`'s `onMove` mutates — binding directly to `chipsRaw`
    /// would force CSV re-parsing on every drag delta.
    @State private var enabledOrder: [PacerSettings.MenuBarChip] = []

    /// All chips not currently enabled, rendered as "Add" rows below.
    private var disabledChips: [PacerSettings.MenuBarChip] {
        let enabledSet = Set(enabledOrder)
        return PacerSettings.MenuBarChip.defaultOrder
            .filter { !enabledSet.contains($0) }
    }

    private var iconIsEnabled: Bool {
        enabledOrder.contains(.icon)
    }

    var body: some View {
        PacerCard("Menu bar", content: {
            VStack(alignment: .leading, spacing: 14) {
                enabledList
                if !disabledChips.isEmpty {
                    addList
                }
                Divider().opacity(0.4)
                LabeledControlRow(label: "Icon style") {
                    Picker("Icon style", selection: $iconRaw) {
                        ForEach(PacerSettings.MenuBarIconStyle.allCases) { style in
                            Text(style.label).tag(style.rawValue)
                        }
                    }
                    .labelsHidden()
                    .disabled(!iconIsEnabled)
                }
            }
        }, footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Drag rows to reorder. Toggle every row off to hide the menu-bar item entirely — Pacer keeps collecting in the background as long as the app process is running.")
                if enabledOrder.isEmpty {
                    Text("Menu-bar item is hidden. Open Pacer from Spotlight or the Dock when you want the dashboard.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
        })
        .onAppear { reload() }
        // Keep `enabledOrder` in sync if another surface (CLI, another
        // Settings window) writes to the store while we're open.
        .onReceive(NotificationCenter.default.publisher(
            for: UserDefaults.didChangeNotification,
            object: PacerSettings.store
        )) { _ in
            let fresh = PacerSettings.menuBarChips()
            if fresh != enabledOrder {
                enabledOrder = fresh
            }
        }
    }

    private var enabledList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if enabledOrder.isEmpty {
                Text("No chips selected — menu-bar item hidden.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 6)
            } else {
                ForEach(enabledOrder) { chip in
                    EnabledChipRow(
                        chip: chip,
                        onRemove: { remove(chip) },
                        onMoveUp: index(of: chip).flatMap { idx in
                            idx == 0 ? nil : { move(from: idx, to: idx - 1) }
                        },
                        onMoveDown: index(of: chip).flatMap { idx in
                            idx == enabledOrder.count - 1 ? nil : { move(from: idx, to: idx + 1) }
                        }
                    )
                }
                // `.onMove` would need a `List` parent for drag — we
                // ship arrow buttons + a hint in the footer so the
                // affordance works inside this `VStack`-based card
                // without changing the surrounding chrome.
            }
        }
    }

    private var addList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            ForEach(disabledChips) { chip in
                AddChipRow(chip: chip) { add(chip) }
            }
        }
    }

    // MARK: - Mutation

    private func reload() {
        enabledOrder = PacerSettings.menuBarChips()
    }

    private func persist() {
        PacerSettings.setMenuBarChips(enabledOrder)
    }

    private func index(of chip: PacerSettings.MenuBarChip) -> Int? {
        enabledOrder.firstIndex(of: chip)
    }

    private func add(_ chip: PacerSettings.MenuBarChip) {
        guard !enabledOrder.contains(chip) else { return }
        enabledOrder.append(chip)
        persist()
    }

    private func remove(_ chip: PacerSettings.MenuBarChip) {
        enabledOrder.removeAll { $0 == chip }
        persist()
    }

    private func move(from: Int, to: Int) {
        guard enabledOrder.indices.contains(from),
              (0...enabledOrder.count).contains(to),
              from != to else { return }
        let chip = enabledOrder.remove(at: from)
        let clamped = max(0, min(enabledOrder.count, to))
        enabledOrder.insert(chip, at: clamped)
        persist()
    }
}

/// One row in the enabled-chip list. Shows the chip's icon glyph,
/// label, blurb, and up/down/remove controls. Hover reveals the
/// reorder buttons; they stay visible-but-dim otherwise so first-time
/// users discover them without hovering.
private struct EnabledChipRow: View {
    let chip: PacerSettings.MenuBarChip
    let onRemove: () -> Void
    /// `nil` when this is the first row — disables the "up" arrow.
    let onMoveUp: (() -> Void)?
    /// `nil` when this is the last row — disables the "down" arrow.
    let onMoveDown: (() -> Void)?

    @State private var hovering: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: chip.symbolName)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(chip.label)
                    .font(.callout)
                Text(chip.blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                arrowButton(systemImage: "chevron.up", action: onMoveUp)
                arrowButton(systemImage: "chevron.down", action: onMoveDown)
            }
            .opacity(hovering ? 1.0 : 0.55)
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove from menu bar")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.05) : Color.clear)
        )
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private func arrowButton(
        systemImage: String,
        action: (() -> Void)?
    ) -> some View {
        Button {
            action?()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .disabled(action == nil)
    }
}

/// "Add this chip" row shown below the enabled list. Single-tap to
/// append to the end of the order; the user can then drag it into
/// place with the arrow buttons.
private struct AddChipRow: View {
    let chip: PacerSettings.MenuBarChip
    let onAdd: () -> Void
    @State private var hovering: Bool = false

    var body: some View {
        Button(action: onAdd) {
            HStack(spacing: 10) {
                Image(systemName: chip.symbolName)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(chip.label)
                        .font(.callout)
                    Text(chip.blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "plus.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.tint)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.05) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private extension PacerSettings.MenuBarChip {
    /// SF Symbol shown in Settings to give each chip-row a visual
    /// anchor. The same icons appear in the menu bar chip-list dropdown
    /// later if we add one — keep them representative.
    var symbolName: String {
        switch self {
        case .icon:          return "gauge.with.dots.needle.50percent"
        case .fiveHourPct:   return "clock"
        case .sevenDayPct:   return "calendar"
        case .todayCost:     return "dollarsign.circle"
        case .todayTokens:   return "number.square"
        case .activeModel:   return "cpu"
        }
    }
}

// MARK: - Rate-limit alerts

/// Combined rate-limit alerts card: the master enable toggle plus the
/// per-window threshold lists (5-hour, 7-day) live together inside one
/// card with subsection labels, so the parent-child relationship reads
/// as a single concept instead of three loose cards. Persists through
/// `PacerSettings` so the live `NotificationCoordinator` (also reading
/// via `PacerSettings.thresholds(forWindow:)`) sees changes
/// immediately.
private struct RateLimitAlertsCard: View {
    @AppStorage(PacerSettings.Key.notificationsEnabled, store: PacerSettings.store)
    private var enabled: Bool = false

    var body: some View {
        PacerCard("Rate-limit alerts", content: {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Enable rate-limit notifications", isOn: $enabled)
                    .onChange(of: enabled) { _, newValue in
                        if newValue {
                            Task {
                                await NotificationCoordinator.shared
                                    .requestAuthorizationIfNeeded()
                            }
                        }
                    }
                Divider().opacity(0.4)
                ThresholdSubsection(title: "5-hour window", window: "five_hour", enabled: enabled)
                Divider().opacity(0.4)
                ThresholdSubsection(title: "7-day window", window: "seven_day", enabled: enabled)
            }
        }, footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Pacer fires a banner each time usage crosses a threshold upward (e.g. 50%, 75%, 90% in one 5-hour cycle). Each banner fires at most once per cycle. The first banner triggers the system permission prompt.")
                HStack(spacing: 8) {
                    Text("Not seeing banners?")
                    Button("Open System Settings → Notifications") {
                        openNotificationsSettings()
                    }
                    .controlSize(.small)
                }
                Text("Pacer's banner style is set there — choose **Banners** or **Alerts** rather than **None**.")
            }
        })
    }

    private func openNotificationsSettings() {
        // Apple-documented preferences URL scheme; both literals are
        // guaranteed to parse, so the force-unwraps cannot fail.
        let direct = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        if NSWorkspace.shared.open(direct) {
            return
        }
        let root = URL(string: "x-apple.systempreferences:")!
        NSWorkspace.shared.open(root)
    }
}

/// One window's threshold list rendered inline inside the combined
/// rate-limit card — small uppercase label on top with an "Add" button
/// trailing, followed by per-threshold slider rows.
private struct ThresholdSubsection: View {
    let title: String
    let window: String
    let enabled: Bool

    @State private var thresholds: [Int] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow(text: title)
                Spacer()
                Button {
                    addThreshold()
                } label: {
                    Label("Add threshold", systemImage: "plus.circle.fill")
                        .labelStyle(.titleAndIcon)
                }
                .controlSize(.small)
                .disabled(!enabled)
            }
            if thresholds.isEmpty {
                Text("No thresholds — Pacer won't notify for this window.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 2)
            } else {
                ForEach(Array(thresholds.enumerated()), id: \.offset) { idx, _ in
                    ThresholdRow(
                        value: thresholdBinding(for: idx),
                        enabled: enabled,
                        onRemove: { remove(at: idx) }
                    )
                }
            }
        }
        .onAppear { reload() }
        // Re-pull when the App Group store changes so two Settings
        // panels (or a CLI write) stay in sync.
        .onReceive(NotificationCenter.default.publisher(
            for: UserDefaults.didChangeNotification,
            object: PacerSettings.store
        )) { _ in
            let fresh = PacerSettings.thresholds(forWindow: window)
            if fresh != thresholds {
                thresholds = fresh
            }
        }
    }

    private func reload() {
        thresholds = PacerSettings.thresholds(forWindow: window)
    }

    private func persist() {
        PacerSettings.setThresholds(thresholds, forWindow: window)
        thresholds = PacerSettings.thresholds(forWindow: window)
    }

    private func addThreshold() {
        let defaultValue: Int
        if let highest = thresholds.last {
            defaultValue = min(99, (highest + 99) / 2)
        } else {
            defaultValue = 75
        }
        thresholds.append(defaultValue)
        persist()
    }

    private func remove(at idx: Int) {
        guard thresholds.indices.contains(idx) else { return }
        thresholds.remove(at: idx)
        persist()
    }

    private func thresholdBinding(for idx: Int) -> Binding<Int> {
        Binding(
            get: {
                guard thresholds.indices.contains(idx) else { return 0 }
                return thresholds[idx]
            },
            set: { newValue in
                guard thresholds.indices.contains(idx) else { return }
                thresholds[idx] = max(1, min(99, newValue))
                persist()
            }
        )
    }
}

/// One row in the threshold list. Slider fills the available width;
/// the value is shown to the right alongside a delete button.
private struct ThresholdRow: View {
    @Binding var value: Int
    let enabled: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { value = Int($0.rounded()) }
                ),
                in: 1...99
            )
            .controlSize(.small)
            .disabled(!enabled)
            Text("\(value)%")
                .font(.callout)
                .fontWeight(.semibold)
                .fontDesign(.rounded)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(enabled ? .primary : .secondary)
            Button(role: .destructive) {
                onRemove()
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove threshold")
        }
    }
}

// MARK: - Daily cost alert

private struct DailyCostAlertCard: View {
    @AppStorage(PacerSettings.Key.notifyOnDailyCost, store: PacerSettings.store)
    private var dailyCostEnabled: Bool = false

    @AppStorage(PacerSettings.Key.dailyCostThresholdUSD, store: PacerSettings.store)
    private var dailyCostThreshold: Double = 50

    /// Always USD — see `DailyAggregate.totalCostUSD`'s denomination
    /// comment. A EUR-locale user typing "50" expects €50 but the
    /// underlying compare against today's-USD-cost still treats it
    /// as $50, so we lock the format code here.
    private let currencyCode: String = "USD"

    var body: some View {
        PacerCard("Daily cost alert") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Notify when today's cost exceeds threshold", isOn: $dailyCostEnabled)
                LabeledControlRow(label: "Cost threshold") {
                    HStack(spacing: 4) {
                        TextField("Amount", value: $dailyCostThreshold,
                                  format: .currency(code: currencyCode))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 110)
                        Stepper("", value: $dailyCostThreshold, in: 1...10_000, step: 5)
                            .labelsHidden()
                    }
                    .disabled(!dailyCostEnabled)
                }
            }
        }
    }
}

// MARK: - Custom alert rules

private struct CustomRulesCard: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \AlertRule.createdAt) private var rules: [AlertRule]
    @State private var draftMetric: String = AlertRuleMetric.weeklyCost
    @State private var draftName: String = ""
    @State private var draftThreshold: Double = 100

    var body: some View {
        PacerCard("Custom alerts", content: {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(rules, id: \.id) { rule in
                    RuleRow(rule: rule) {
                        context.delete(rule)
                        try? context.save()
                    }
                    Divider().opacity(0.3)
                }
                addRow
            }
        }, footer: {
            Text("Add rules for metrics not covered by the built-in toggles — weekly cost, daily tokens, etc. Each fires at most once per day per rule.")
        })
    }

    @ViewBuilder
    private var addRow: some View {
        HStack(spacing: 12) {
            TextField("Name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 120)
            Picker("", selection: $draftMetric) {
                ForEach(AlertRuleMetric.all, id: \.self) { metric in
                    Text(AlertRuleMetric.label(for: metric)).tag(metric)
                }
            }
            .labelsHidden()
            .frame(width: 180)
            thresholdField
            Spacer()
            Button("Add") {
                let trimmed = draftName.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, draftThreshold > 0 else { return }
                context.insert(AlertRule(
                    name: trimmed,
                    metric: draftMetric,
                    thresholdValue: draftThreshold
                ))
                try? context.save()
                draftName = ""
                draftThreshold = 100
            }
            .buttonStyle(.borderedProminent)
            .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty || draftThreshold <= 0)
        }
    }

    @ViewBuilder
    private var thresholdField: some View {
        if AlertRuleMetric.isCurrency(draftMetric) {
            HStack(spacing: 2) {
                Text("$").foregroundStyle(.secondary)
                TextField("Threshold", value: $draftThreshold, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
            }
        } else {
            TextField("Threshold", value: $draftThreshold, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 100)
        }
    }

    private struct RuleRow: View {
        @Bindable var rule: AlertRule
        let onRemove: () -> Void

        var body: some View {
            HStack(spacing: 12) {
                Toggle("", isOn: $rule.enabled)
                    .labelsHidden()
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.name)
                        .font(.system(size: 13, weight: .medium))
                    Text("\(AlertRuleMetric.label(for: rule.metric)) ≥ \(formatThreshold)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove rule")
            }
        }

        private var formatThreshold: String {
            if AlertRuleMetric.isCurrency(rule.metric) {
                return pacerCost(rule.thresholdValue)
            } else {
                return pacerTokens(Int64(rule.thresholdValue))
            }
        }
    }
}

// MARK: - Burn-rate warning

private struct BurnRateAlertCard: View {
    @AppStorage(PacerSettings.Key.notifyBurnRate, store: PacerSettings.store)
    private var enabled: Bool = false

    var body: some View {
        PacerCard("Burn-rate warning", content: {
            Toggle("Warn when my usage pace will hit a limit before it resets", isOn: $enabled)
        }, footer: {
            Text("Pacer projects each window forward along your own daily rhythm and warns you ahead of time if you're on track to hit a limit before it resets — with a follow-up only if the situation gets meaningfully worse. Fires only once you're past 50% used.")
        })
    }
}

// MARK: - Reset notifications

private struct ResetAlertCard: View {
    @AppStorage(PacerSettings.Key.notifyOnReset, store: PacerSettings.store)
    private var resetEnabled: Bool = false

    @AppStorage(PacerSettings.Key.notifyGlobalReset, store: PacerSettings.store)
    private var globalResetEnabled: Bool = true

    var body: some View {
        PacerCard("Reset notifications", content: {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Notify when a rate-limit window resets", isOn: $resetEnabled)
                Toggle("Notify when Anthropic resets limits early", isOn: $globalResetEnabled)
            }
        }, footer: {
            Text("The first fires on a normal rollover — the 5-hour or 7-day window rolling over on schedule (usage drops near zero and the next reset moves forward). The second fires when Anthropic resets everyone's limits ahead of schedule: usage collapses to zero but your reset day doesn't move. Pacer waits for the drop to hold across a few minutes of polling, so a transient blip won't trigger it.")
        })
    }
}

// MARK: - Daily summary

private struct DailySummaryCard: View {
    @AppStorage(PacerSettings.Key.notifyDailySummary, store: PacerSettings.store)
    private var dailySummaryEnabled: Bool = false

    @AppStorage(PacerSettings.Key.dailySummaryHour, store: PacerSettings.store)
    private var dailySummaryHour: Int = 21

    var body: some View {
        PacerCard("Daily summary", content: {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Send a daily summary banner", isOn: $dailySummaryEnabled)
                LabeledControlRow(label: "Send at") {
                    Picker("Send at", selection: $dailySummaryHour) {
                        ForEach(0..<24, id: \.self) { h in
                            Text(formatHour(h)).tag(h)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .disabled(!dailySummaryEnabled)
                }
            }
        }, footer: {
            Text("Quiet, informational banner showing today's spend and top model. Fires once per day after the chosen time, only if you've used Claude Code that day.")
        })
    }

    /// Locale-aware hour label: 12-hour locales get "9 PM"; 24-hour
    /// locales get "21:00".
    private func formatHour(_ h: Int) -> String {
        var components = DateComponents()
        components.hour = h
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = pacerUses24HourClock ? "HH:mm" : "h a"
        guard let date = Calendar.current.date(from: components) else {
            return "\(h):00"
        }
        return f.string(from: date)
    }
}

// MARK: - Notification test

private struct NotificationTestCard: View {
    @State private var testStatus: TestStatus = .idle

    enum TestStatus: Equatable {
        case idle, sending, sent, denied, failed(String)

        static func == (lhs: TestStatus, rhs: TestStatus) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.sending, .sending),
                 (.sent, .sent), (.denied, .denied):
                return true
            case (.failed, .failed): return true
            default: return false
            }
        }
    }

    var body: some View {
        PacerCard("Notification test") {
            HStack {
                Button("Send test notification") {
                    Task { await sendTestNotification() }
                }
                .disabled(testStatus == .sending)
                if let label = testLabel {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(testColor)
                }
                Spacer()
            }
        }
    }

    private var testLabel: String? {
        switch testStatus {
        case .idle:        return nil
        case .sending:     return "sending…"
        case .sent:        return "sent"
        case .denied:      return "system denied; check System Settings → Notifications → Pacer"
        case .failed(let m): return "failed: \(m)"
        }
    }

    private var testColor: Color {
        switch testStatus {
        case .sent:    return .green
        case .denied, .failed: return .orange
        default:       return .secondary
        }
    }

    private func sendTestNotification() async {
        testStatus = .sending
        let outcome = await NotificationCoordinator.shared.sendTestNotification()
        await MainActor.run {
            switch outcome {
            case .delivered:        testStatus = .sent
            case .denied:           testStatus = .denied
            case .failed(let msg):  testStatus = .failed(msg)
            }
        }
    }
}

// MARK: - Cost calculation

private struct CostCalculationCard: View {
    @AppStorage(PacerSettings.Key.costMode, store: PacerSettings.store)
    private var costMode: String = "auto"

    var body: some View {
        PacerCard("Cost calculation", content: {
            Picker("Mode", selection: $costMode) {
                Text("Auto (prefer stored, calculate when missing)").tag("auto")
                Text("Calculate (always from tokens × pricing)").tag("calculate")
                Text("Display (only stored Claude Code costs)").tag("display")
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }, footer: {
            Text("**Auto** matches `bun x ccusage`. **Calculate** is what you want when older Claude Code lines lack `costUSD`. **Display** only shows server-supplied numbers and ignores tokens that didn't come with one.")
        })
    }
}

// MARK: - Project aliases pointer

/// Alias management moved to the Projects tab (page header → "Aliases…").
/// This signpost lives where the alias card used to be (Settings → Data)
/// so anyone who looks here is pointed to the new home, with a one-click
/// jump that switches the sidebar to Projects.
private struct ProjectAliasesPointerCard: View {
    var body: some View {
        PacerCard("Project aliases", content: {
            HStack(spacing: 12) {
                Text("Merge renamed folders, sibling worktrees, and cross-machine paths into one project.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button("Open in Projects") {
                    NotificationCenter.default.post(
                        name: .pacerSelectDestination,
                        object: ContentView.Destination.projects
                    )
                }
                .controlSize(.small)
            }
        }, footer: {
            Text("Managed from the Projects tab now — pick a time range and open **Aliases…** in the page header.")
        })
    }
}

// MARK: - Authentication

/// Opt-in: also read Claude Desktop's credential. When on, Pacer decrypts
/// Claude Desktop's `safeStorage` token cache (read-only) and the poller
/// uses whichever of it or the Claude Code token is freshest — so Pacer
/// keeps working for Desktop/chat-only users and across Claude Code's idle
/// token gaps. Off by default; turning it on triggers the one-time
/// "Claude Safe Storage" keychain approval, which the Test run surfaces.
private struct DesktopCredentialsCard: View {
    @AppStorage(PacerSettings.Key.desktopCredentialsEnabled, store: PacerSettings.store)
    private var enabled: Bool = false

    @State private var testResult: TestResult?
    @State private var testInProgress = false

    private enum TestResult: Equatable {
        case success(fiveHourPct: Double?, sevenDayPct: Double?)
        case failure(message: String)
    }

    var body: some View {
        PacerCard("Claude Desktop credentials", content: {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Use Claude Desktop credentials", isOn: $enabled)
                    .onChange(of: enabled) { _, on in
                        testResult = nil
                        // Surface the one-time keychain approval right away,
                        // and confirm the token actually works.
                        if on { runTest() }
                    }
                HStack(spacing: 8) {
                    statusLabel
                    Spacer(minLength: 8)
                    Button("Test") { runTest() }
                        .controlSize(.small)
                        .disabled(testInProgress || !enabled)
                }
            }
        }, footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Lets Pacer keep working when you use Claude Desktop / general chat rather than the Claude Code CLI. Pacer decrypts Desktop's stored token (read-only — it never refreshes or writes it) and uses whichever of Desktop or Claude Code is freshest.")
                Text("Turning this on triggers a one-time macOS keychain approval for “Claude Safe Storage” — click Always Allow so Pacer can read it silently afterward.")
                    .padding(.top, 2)
            }
        })
    }

    @ViewBuilder
    private var statusLabel: some View {
        if testInProgress {
            ProgressView().controlSize(.small)
            Text("Reading Claude Desktop…")
                .font(.caption).foregroundStyle(.secondary)
        } else if let result = testResult {
            switch result {
            case .success(let fh, let sd):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.system(size: 12))
                Text("Working · \(formatSuccess(fiveHour: fh, sevenDay: sd))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            case .failure(let msg):
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red).font(.system(size: 12))
                Text(msg).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
        } else if enabled {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.system(size: 12))
            Text("On · Pacer uses Desktop when it's freshest")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        } else {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(.tertiary).font(.system(size: 12))
            Text("Off · Pacer reads only Claude Code's token")
                .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
        }
    }

    private func formatSuccess(fiveHour: Double?, sevenDay: Double?) -> String {
        let f = fiveHour.map { "5h=\(Int($0.rounded()))%" } ?? "5h=—"
        let s = sevenDay.map { "7d=\(Int($0.rounded()))%" } ?? "7d=—"
        return "\(f), \(s)"
    }

    /// Read Desktop's credential and run one usage call with it — proves it
    /// works and triggers the keychain approval. Forces a broken keychain +
    /// no override so the result reflects the Desktop token alone.
    private func runTest() {
        testInProgress = true
        testResult = nil
        Task { @MainActor in
            let brokenKeychain = KeychainOAuth(rawReader: { .failure(.notFound) })
            let client = OAuthClient(
                keychain: brokenKeychain,
                tokenOverride: { nil },
                desktopEnabled: { true }
            )
            let result = await client.fetchUsage()
            testInProgress = false
            testResult = Self.classify(result)
        }
    }

    private static func classify(
        _ result: Result<RateLimitSnapshot, OAuthClientError>
    ) -> TestResult {
        switch result {
        case .success(let snapshot):
            return .success(
                fiveHourPct: snapshot.fiveHour?.usedPercentage,
                sevenDayPct: snapshot.sevenDay?.usedPercentage
            )
        case .failure(.credentialsNotFound):
            return .failure(message: "No Claude Desktop credential found. Is Claude Desktop installed and signed in?")
        case .failure(.keychainAccessDenied):
            return .failure(message: "Keychain access denied. Approve the “Claude Safe Storage” prompt and retry.")
        case .failure(.tokenExpired):
            return .failure(message: "Desktop's token is expired right now — open Claude Desktop briefly to refresh it.")
        case .failure(.unauthorized):
            return .failure(message: "Anthropic rejected Desktop's token (401).")
        case .failure(.rateLimited):
            return .failure(message: "Rate-limited (429). Try again in a moment.")
        case .failure(.transport):
            return .failure(message: "Network error. Check your connection and retry.")
        default:
            return .failure(message: "Couldn't read Claude Desktop's credential. Check ~/Library/Logs/Pacer/Pacer.err.log.")
        }
    }
}

// MARK: - Token pool

/// Live view of the OAuth token pool the poller cycles through — where
/// each token comes from, which account it's tied to, when it expires,
/// its health, and a Test that routes through the poller (so it persists
/// and counts against that token's budget instead of racing it).
/// Column widths shared by the Tokens header and rows so they line up
/// exactly. SOURCE and ACCOUNT are both flexible (they split the leftover
/// evenly and are the first to truncate as the window narrows — hover to
/// see them in full); STATUS/EXPIRES/UPDATED/trash are fixed and small.
fileprivate enum TokenCol {
    static let status: CGFloat = 76
    static let expires: CGFloat = 58
    static let updated: CGFloat = 72
    static let trash: CGFloat = 24
    static let spacing: CGFloat = 12
}

#if canImport(AppKit)
/// Dismisses text-field focus when the user clicks anything that isn't a
/// text field. SwiftUI on macOS keeps a `TextField` focused until another
/// responder takes over, and a background click-catcher can't fix it —
/// opaque SwiftUI views above it swallow the click. A window-level mouse
/// monitor is the reliable route: on any left click, if the hit view
/// isn't the field editor, resign first responder (which clears the
/// SwiftUI `@FocusState` too). Clicking into an unfocused field still
/// focuses it, since the click proceeds normally afterward.
private struct DismissFocusOnOutsideClick: ViewModifier {
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
                    guard let window = event.window else { return event }
                    let hit = window.contentView?.hitTest(event.locationInWindow)
                    // The field editor of a focused NSTextField is an NSTextView.
                    if !(hit is NSTextView) {
                        window.makeFirstResponder(nil)
                    }
                    return event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}
#endif

/// A one-line shell command shown as a code block. The entire box is a
/// single click-to-copy button (flips to a checkmark + trackpad haptic).
/// The command is clipped with a right-edge fade so it's clear it runs
/// past the copy icon rather than being all there is; hover shows it in
/// full. It's deliberately not text-selectable — a stray click-drag used
/// to leave text stuck-highlighted, and copying is one click anyway.
private struct CopyableCommand: View {
    let command: String
    @State private var copied = false
    init(_ command: String) { self.command = command }

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 14) {
                Image(systemName: "terminal")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)   // draw at full width…
                    .frame(maxWidth: .infinity, alignment: .leading) // …clipped to the box
                    .clipped()
                    .mask(
                        LinearGradient(
                            stops: [.init(color: .black, location: 0),
                                    .init(color: .black, location: 0.9),
                                    .init(color: .clear, location: 1.0)],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                ZStack {
                    Image(systemName: "doc.on.doc").opacity(copied ? 0 : 1)
                    Image(systemName: "checkmark").foregroundStyle(.green).opacity(copied ? 1 : 0)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 16)   // fixed → the flip can't shift layout
                .animation(.easeInOut(duration: 0.15), value: copied)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied!" : command)
    }

    private func copy() {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        #endif
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            copied = false
        }
    }
}

/// Live view of the OAuth token pool the poller cycles through — source,
/// account, expiry, health, and when each last polled; plus an inline
/// "add a token" field.
private struct TokensCard: View {
    @State private var pool = TokenPoolStatus.shared
    @State private var draft: String = ""
    @State private var adding = false
    @State private var addResult: TokenTestResult?
    @State private var highlightId: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        PacerCard("Tokens", trailing: {
            cadenceHeader
        }, content: {
            VStack(alignment: .leading, spacing: 0) {
                if !pool.hasLoaded {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading tokens…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                } else if pool.lanes.isEmpty {
                    Text("No tokens yet — sign into Claude Code, enable Claude Desktop below, or add one manually.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                } else {
                    columnHeader
                    ForEach(pool.lanes) { lane in
                        Divider().opacity(0.35)
                        TokenLaneRow(lane: lane, highlighted: lane.id == highlightId)
                    }
                }
                addTokenRow
            }
        }, footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pacer spreads usage polls across every token it can read for your account, so it refreshes more often while you're active without exceeding any single token's rate limit.")
                Text("Claude Code and (if enabled below) Claude Desktop are read automatically. Only *add* a token Pacer can't read here — e.g. from another Mac, where you'd run this in Terminal:")
                    .padding(.top, 2)
                CopyableCommand("security find-generic-password -s 'Claude Code-credentials' -w | jq -r .claudeAiOauth.accessToken")
                    .padding(.vertical, 6)
                Text("…then paste the result above. It must be a `user:profile` token, and only tokens for this same account are kept.")
            }
        })
    }

    private var cadenceHeader: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(pool.isActive ? Color.green : Color.secondary.opacity(0.6))
                .frame(width: 7, height: 7)
            Text(cadenceText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var cadenceText: String {
        let n = pool.lanes.filter { $0.account != .foreign }.count
        let tokens = "\(n) token\(n == 1 ? "" : "s")"
        guard let seconds = pool.effectiveIntervalSeconds else { return tokens }
        return "Updating ~\(Self.formatInterval(seconds)) · \(tokens) · \(pool.isActive ? "active" : "idle")"
    }

    static func formatInterval(_ s: TimeInterval) -> String {
        if s < 90 { return "\(Int(s.rounded()))s" }
        let m = s / 60
        return m.rounded() == m ? "\(Int(m)) min" : String(format: "%.1f min", m)
    }

    private var columnHeader: some View {
        HStack(spacing: TokenCol.spacing) {
            Text("SOURCE").frame(maxWidth: .infinity, alignment: .leading)
            Text("ACCOUNT").frame(maxWidth: .infinity, alignment: .leading)
            Text("STATUS").frame(width: TokenCol.status, alignment: .leading)
            Text("EXPIRES").frame(width: TokenCol.expires, alignment: .leading)
            Text("UPDATED").frame(width: TokenCol.updated, alignment: .leading)
                .help("When Pacer last fetched usage with this token")
            Color.clear.frame(width: TokenCol.trash, height: 1)   // trash column (manual rows only)
        }
        .font(.system(size: 9, weight: .semibold))
        .tracking(0.5)
        .foregroundStyle(.tertiary)
        .padding(.bottom, 6)
    }

    private var addTokenRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().opacity(0.35).padding(.top, 4)
            HStack(spacing: 8) {
                TextField("Paste a token to add (e.g. from another Mac)", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .focused($fieldFocused)
                    .onSubmit(add)
                    .onChange(of: draft) { _, _ in addResult = nil }
                if adding {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Add", action: add)
                        .controlSize(.small)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if let addResult { addResultLabel(addResult) }
        }
        .padding(.top, 8)
    }

    @ViewBuilder private func addResultLabel(_ r: TokenTestResult) -> some View {
        switch r {
        case .success(let fh, let sd):
            addLabel("checkmark.circle.fill", .green, "Added · \(Self.usage(fh, sd))")
        case .alreadyTracked(let source, let fp):
            addLabel("info.circle.fill", .gray, "Already tracking this — it's your \(Self.sourceName(source)) token (…\(String(fp.suffix(4)))).")
        case .foreignAccount:
            addLabel("person.crop.circle.badge.xmark", .purple, "That token is a different account — not added.")
        case .failure(let reason):
            addLabel("xmark.circle.fill", .red, reason)
        case .unavailable:
            addLabel("xmark.circle.fill", .red, "Pacer's poller isn't running — try again in a moment.")
        }
    }

    private func addLabel(_ icon: String, _ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).foregroundStyle(color).font(.system(size: 11))
            Text(text).font(.caption).foregroundStyle(color).lineLimit(2)
        }
    }

    private static func usage(_ fh: Double?, _ sd: Double?) -> String {
        let f = fh.map { "5h \(Int($0.rounded()))%" } ?? "5h —"
        let s = sd.map { "7d \(Int($0.rounded()))%" } ?? "7d —"
        return "\(f), \(s)"
    }

    private static func sourceName(_ s: CredentialCandidate.Source) -> String {
        switch s {
        case .keychain: return "Claude Code"
        case .desktop:  return "Claude Desktop"
        case .override: return "manually-added"
        case .held:     return "saved"
        }
    }

    private func add() {
        let token = draft
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        adding = true
        addResult = nil
        Task { @MainActor in
            let r = await TokenPoolStatus.shared.addManualToken(token)
            adding = false
            fieldFocused = false
            addResult = r   // NB: don't clear `draft` — onChange would wipe this.
            if case .alreadyTracked(_, let fp) = r {
                highlightId = fp
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    if highlightId == fp { highlightId = nil }
                }
            }
        }
    }
}

/// One row in the token pool. Manually-added rows carry a Remove button;
/// auto-sourced rows don't (they'd just be rediscovered).
private struct TokenLaneRow: View {
    let lane: TokenLaneStatus
    let highlighted: Bool
    @State private var removing = false

    var body: some View {
        HStack(spacing: TokenCol.spacing) {
            HStack(spacing: 7) {
                Image(systemName: Self.icon(lane.source))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 15)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.name(lane.source))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text("#\(lane.priority + 1) · \(lane.id)")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help("Token fingerprint \(lane.id)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(lane.organizationId ?? "—")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(lane.organizationId ?? "")

            statusPill
                .frame(width: TokenCol.status, alignment: .leading)

            Text(expiresText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: TokenCol.expires, alignment: .leading)

            Text(updatedText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: TokenCol.updated, alignment: .leading)

            removeControl
                .frame(width: TokenCol.trash, alignment: .trailing)
        }
        .padding(.vertical, 7)
        .background(
            // Bleed the highlight outward so it wraps the source icon and
            // reaches the card edges, without shifting the row content.
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(highlighted ? Color.accentColor.opacity(0.16) : Color.clear)
                .padding(.horizontal, -10)
        )
        .animation(.easeInOut(duration: 0.25), value: highlighted)
    }

    // Always occupies the trash column's width (even for auto rows with no
    // button) so every row's columns line up with the header.
    private var removeControl: some View {
        Group {
            if lane.source == .override {
                Button { remove() } label: {
                    Image(systemName: "trash").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(removing)
                .help("Remove this manually-added token")
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
    }

    private func remove() {
        removing = true
        Task { @MainActor in
            await TokenPoolStatus.shared.removeManualToken(id: lane.id)
        }
    }

    private var statusPill: some View {
        let info = statusInfo
        return Text(info.0)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(info.1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(info.1.opacity(0.14)))
    }

    private var statusInfo: (String, Color) {
        let now = Date()
        if let exp = lane.expiresAt, exp < now { return ("expired", .red) }
        if lane.account == .foreign { return ("other acct", .purple) }
        if let cd = lane.cooldownUntil, cd > now { return ("cooling", .orange) }
        if lane.account == .primary { return ("active", .green) }
        return ("pending", .gray)
    }

    private var expiresText: String {
        guard let exp = lane.expiresAt else { return "—" }
        if exp < Date() { return "expired" }
        return Self.relative.localizedString(for: exp, relativeTo: Date())
    }

    private var updatedText: String {
        guard let last = lane.lastPolledAt else { return "never" }
        if abs(Date().timeIntervalSince(last)) < 10 { return "just now" }
        return Self.relative.localizedString(for: last, relativeTo: Date())
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private static func name(_ s: CredentialCandidate.Source) -> String {
        switch s {
        case .keychain: return "Claude Code"
        case .desktop:  return "Claude Desktop"
        case .override: return "Manual"
        case .held:     return "Saved by Pacer"
        }
    }

    private static func icon(_ s: CredentialCandidate.Source) -> String {
        switch s {
        case .keychain: return "terminal"
        case .desktop:  return "desktopcomputer"
        case .override: return "key.fill"
        case .held:     return "lock.fill"
        }
    }
}

// MARK: - Storage

/// Disk footprint of the data Pacer touches. Measured off the main
/// actor on appear (Claude's logs run to gigabytes) and rendered as a
/// small breakdown. Read-only — it never writes or deletes anything,
/// least of all Claude's transcripts.
private struct StorageCard: View {
    @State private var snapshot: StorageSnapshot?
    @State private var didMeasure = false

    var body: some View {
        PacerCard("Storage", content: {
            if let snapshot {
                VStack(alignment: .leading, spacing: 10) {
                    StorageRow(label: "Pacer database", bytes: snapshot.pacerDatabaseBytes)
                    StorageRow(label: "Pacer logs", bytes: snapshot.pacerLogsBytes)
                    Divider()
                    StorageRow(
                        label: "Claude Code logs",
                        bytes: snapshot.claudeLogsBytes,
                        detail: "\(snapshot.claudeLogFileCount.formatted()) file\(snapshot.claudeLogFileCount == 1 ? "" : "s")"
                    )
                }
            } else if didMeasure {
                Text("Couldn't measure storage.")
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Measuring…").foregroundStyle(.secondary)
                }
            }
        }, footer: {
            Text("Pacer's database is the usage history it derives from Claude Code's logs — both stay on your Mac. The Claude Code logs are the raw transcripts Pacer reads; it never modifies or deletes them.")
        })
        .task {
            // Re-measure each time the Settings tab appears — sizes drift
            // as you keep using Claude Code, and this is cheap (it stats
            // files, never reads them).
            let storeURL = try? PacerStore.storeURL()
            let logsDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/Pacer")
            let claudeDirs = (try? ClaudePathResolver().resolve())?
                .map(\.projectsDirectory) ?? []
            let snap = await Task.detached(priority: .utility) {
                StorageInspector.snapshot(
                    storeURL: storeURL,
                    logsDirectory: logsDir,
                    claudeProjectsDirectories: claudeDirs
                )
            }.value
            snapshot = snap
            didMeasure = true
        }
    }
}

/// One "label … size" line in the Storage card. Optional `detail` sits
/// quietly after the label (e.g. a file count).
private struct StorageRow: View {
    let label: String
    let bytes: Int64
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.primary)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            Text(pacerBytes(bytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

private struct DatabaseCard: View {
    private var storeURL: URL? { try? PacerStore.storeURL() }

    var body: some View {
        PacerCard("Database") {
            if let url = storeURL {
                PathRow(path: url.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } buttonLabel: {
                    Text("Show in Finder")
                }
            } else {
                Text("App Group container unavailable.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct LogsCard: View {
    private var logsDirURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Pacer")
    }

    var body: some View {
        PacerCard("Logs") {
            PathRow(path: logsDirURL.path) {
                NSWorkspace.shared.open(logsDirURL)
            } buttonLabel: {
                Text("Open in Finder")
            }
        }
    }
}

/// Path label + trailing action button, used twice in the Storage
/// card. Path text truncates at the middle so the user can always
/// see both the home-directory prefix and the leaf filename.
private struct PathRow<ButtonLabel: View>: View {
    let path: String
    let action: () -> Void
    @ViewBuilder let buttonLabel: () -> ButtonLabel

    var body: some View {
        HStack {
            Text(path)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: action) {
                buttonLabel()
            }
        }
    }
}

// MARK: - Labeled-control row

/// Two-column row for "Label: Control" pairs inside a PacerCard.
/// Mirrors macOS Form's leading-aligned label / trailing-aligned
/// control layout, but inside our card surface so the visual stays
/// consistent with the rest of the app.
private struct LabeledControlRow<Control: View>: View {
    let label: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.primary)
            Spacer(minLength: 16)
            control()
        }
    }
}

// MARK: - Local API & metrics server

/// Opt-in HTTP server for third-party integrations + observability scraping.
/// Off by default, loopback-bound; the user can widen the address, set a port,
/// and require a bearer token. Editing port/host/token is staged in `@State`
/// drafts and committed via "Save & restart" (so a half-typed port doesn't
/// thrash the listener); the enable toggle applies immediately.
private struct APIServerCard: View {
    @AppStorage(PacerSettings.Key.apiEnabled, store: PacerSettings.store)
    private var enabled: Bool = false
    @AppStorage(PacerSettings.Key.apiPort, store: PacerSettings.store)
    private var savedPort: Int = 7223
    @AppStorage(PacerSettings.Key.apiBindHost, store: PacerSettings.store)
    private var savedHost: String = "127.0.0.1"
    @AppStorage(PacerSettings.Key.apiToken, store: PacerSettings.store)
    private var savedToken: String = ""

    @ObservedObject private var status = PacerAPIServerStatus.shared

    @State private var draftPort: String = "7223"
    @State private var draftHost: String = "127.0.0.1"
    @State private var draftToken: String = ""

    private var isDirty: Bool {
        draftPort != String(savedPort) || draftHost != savedHost || draftToken != savedToken
    }
    private var portIsValid: Bool {
        if let port = Int(draftPort) { return (1...65535).contains(port) }
        return false
    }
    private func isLoopback(_ host: String) -> Bool {
        ["127.0.0.1", "::1", "localhost"].contains(host.trimmingCharacters(in: .whitespaces))
    }
    private var exposedWithoutToken: Bool {
        !isLoopback(draftHost) && draftToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        PacerCard("Local API & metrics server", content: {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Enable local API & metrics server", isOn: $enabled)
                    .onChange(of: enabled) { _, _ in notifyServer() }

                HStack(spacing: 8) {
                    Circle()
                        .fill(status.isError ? Color.red : (enabled ? Color.green : Color.secondary))
                        .frame(width: 8, height: 8)
                    Text(status.text)
                        .font(.caption)
                        .foregroundStyle(status.isError ? Color.red : Color.secondary)
                }

                Divider().opacity(0.4)

                LabeledControlRow(label: "Port") {
                    TextField("7223", text: $draftPort)
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { saveAndApply() }
                }
                LabeledControlRow(label: "Bind address") {
                    TextField("127.0.0.1", text: $draftHost)
                        .frame(width: 160)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { saveAndApply() }
                }
                LabeledControlRow(label: "Token (optional)") {
                    HStack(spacing: 6) {
                        TextField("none", text: $draftToken)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 200)
                        Button("Generate") { draftToken = Self.randomToken() }
                            .controlSize(.small)
                    }
                }

                if exposedWithoutToken {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text("This address is reachable from other devices and no token is set — anyone on your network could read your usage data. Set a token, or use 127.0.0.1.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 8) {
                    Spacer(minLength: 8)
                    if isDirty {
                        Text("Unsaved changes").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Save & restart") { saveAndApply() }
                        .controlSize(.small)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!isDirty || !portIsValid)
                }

                if enabled {
                    Divider().opacity(0.4)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(["/v1/snapshot", "/metrics", "/v1/stream"], id: \.self) { path in
                            Text("http://\(savedHost):\(savedPort)\(path)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }, footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Exposes the same data the dashboard shows over local HTTP, so third-party apps (Stream Deck, scripts) and observability scrapers can read it without parsing Claude's logs themselves. Off by default; bound to loopback unless you widen the address.")
                Text("`GET /v1/snapshot` full JSON · `GET /metrics` Prometheus (point Grafana Alloy here) · `GET /v1/stream` Server-Sent Events · `GET /healthz` liveness")
                    .padding(.top, 2)
                Text("curl -s http://127.0.0.1:\(savedPort)/v1/snapshot\(savedToken.isEmpty ? "" : " -H 'Authorization: Bearer \(savedToken)'")")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
        })
        .onAppear { syncDrafts() }
    }

    private func syncDrafts() {
        draftPort = String(savedPort)
        draftHost = savedHost
        draftToken = savedToken
    }

    private func saveAndApply() {
        guard let port = Int(draftPort), (1...65535).contains(port) else { return }
        let host = draftHost.trimmingCharacters(in: .whitespaces)
        savedPort = port
        savedHost = host.isEmpty ? "127.0.0.1" : host
        savedToken = draftToken.trimmingCharacters(in: .whitespacesAndNewlines)
        syncDrafts()
        notifyServer()
    }

    private func notifyServer() {
        NotificationCenter.default.post(name: .pacerAPIServerSettingsChanged, object: nil)
    }

    private static func randomToken() -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<32).map { _ in chars.randomElement()! })
    }
}

// (No "About" card here — App menu → "About Pacer" opens the native
// NSPanel with logo, version, and credits.)
