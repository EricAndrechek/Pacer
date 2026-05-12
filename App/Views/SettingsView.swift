import SwiftUI
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
                    DailyCostAlertCard()
                    DailySummaryCard()
                    NotificationTestCard()
                }
                SettingsSection("Data") {
                    CostCalculationCard()
                    DatabaseCard()
                    LogsCard()
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

// MARK: - Storage

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

// (No "About" card here — App menu → "About Pacer" opens the native
// NSPanel with logo, version, and credits.)
