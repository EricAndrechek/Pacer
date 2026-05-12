import SwiftUI
import PacerCore
import PacerUI

/// Pacer's preferences UI. Embedded as the 5th destination in the main
/// window's sidebar (`Cmd+5`) and reachable via `Cmd+,` and the menu-
/// bar popover. All values bind to the App Group `UserDefaults` (via
/// `PacerSettings`) so the menu bar, in-process scan, and widgets pick
/// up changes without a restart.
///
/// Layout: a small inner sidebar of categories on the left; the right-
/// hand pane shows the selected category's content. Mirrors the
/// macOS Sequoia System Settings shape — every Pacer category becomes
/// its own focused panel rather than a long scroll of stacked sections.
struct SettingsView: View {
    enum Category: String, CaseIterable, Identifiable {
        case general, menuBar, notifications, cost, storage

        var id: String { rawValue }
        var label: String {
            switch self {
            case .general:       return "General"
            case .menuBar:       return "Menu Bar"
            case .notifications: return "Notifications"
            case .cost:          return "Cost"
            case .storage:       return "Storage"
            }
        }
        /// Outline when not selected, filled when selected — macOS
        /// Sequoia System Settings idiom. `switch.2` and
        /// `menubar.rectangle` don't have clean filled variants, so
        /// they stay the same in both states.
        func systemImage(selected: Bool) -> String {
            switch self {
            case .general:       return "switch.2"
            case .menuBar:       return "menubar.rectangle"
            case .notifications: return selected ? "bell.badge.fill"     : "bell.badge"
            case .cost:          return selected ? "dollarsign.circle.fill" : "dollarsign.circle"
            case .storage:       return selected ? "externaldrive.fill" : "externaldrive"
            }
        }
    }

    @State private var category: Category = .general

    var body: some View {
        HStack(spacing: 0) {
            categorySidebar
            Divider()
            content
        }
        .frame(minWidth: 720, minHeight: 540)
    }

    // MARK: - Inner sidebar

    private var categorySidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Settings")
                .font(.title2)
                .fontWeight(.semibold)
                .fontDesign(.rounded)
                .padding(.horizontal, 12)
                .padding(.top, 18)
                .padding(.bottom, 12)
            ForEach(Category.allCases) { c in
                CategoryItem(category: c, selection: $category)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .frame(width: 200, alignment: .leading)
        // Slightly-tinted opaque background, matching macOS Sequoia
        // System Settings' inner sidebar. The previous half-opacity
        // window-color let the main pane bleed through and made the
        // categories list feel washed-out.
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Content pane

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PacerDesign.sectionSpacing) {
                Text(category.label)
                    .font(.title)
                    .fontWeight(.semibold)
                    .fontDesign(.rounded)
                    .padding(.bottom, 4)

                switch category {
                case .general:       GeneralPanel()
                case .menuBar:       MenuBarPanel()
                case .notifications: NotificationsPanel()
                case .cost:          CostPanel()
                case .storage:       StoragePanel()
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Sidebar item

private struct CategoryItem: View {
    let category: SettingsView.Category
    @Binding var selection: SettingsView.Category
    @State private var hovering: Bool = false

    private var isSelected: Bool { selection == category }

    var body: some View {
        Button {
            selection = category
        } label: {
            HStack(spacing: 10) {
                Image(systemName: category.systemImage(selected: isSelected))
                    .font(.body.weight(.medium))
                    .foregroundStyle(isSelected ? Color.white : .secondary)
                    .frame(width: 18, alignment: .center)
                Text(category.label)
                    .font(.body)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(background)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var background: Color {
        if isSelected { return Color.accentColor }
        if hovering { return Color.primary.opacity(0.06) }
        return .clear
    }
}

// MARK: - General

private struct GeneralPanel: View {
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
        VStack(alignment: .leading, spacing: PacerDesign.sectionSpacing) {
            PacerCard(
                "Startup",
                content: {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Open Pacer at login", isOn: isEnabled)
                            .toggleStyle(.switch)
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
                },
                footer: {
                    Text("When enabled, Pacer launches at login and runs in the background — no window opens unless you open it explicitly. Data collection (JSONL scan + OAuth poll) starts automatically and continues even when no window is visible.")
                }
            )
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        loginItemStatus = LoginItemController.currentStatus()
    }
}

// MARK: - Menu Bar

private struct MenuBarPanel: View {
    @AppStorage(PacerSettings.Key.menuBarStyle, store: PacerSettings.store)
    private var styleRaw: String = PacerSettings.MenuBarStyle.iconAndPercent.rawValue

    @AppStorage(PacerSettings.Key.menuBarIconStyle, store: PacerSettings.store)
    private var iconRaw: String = PacerSettings.MenuBarIconStyle.gaugeNeedle.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: PacerDesign.sectionSpacing) {
            PacerCard("Display", content: {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("What to show", selection: $styleRaw) {
                        ForEach(PacerSettings.MenuBarStyle.allCases) { style in
                            Text(style.label).tag(style.rawValue)
                        }
                    }
                    Picker("Icon style", selection: $iconRaw) {
                        ForEach(PacerSettings.MenuBarIconStyle.allCases) { style in
                            Text(style.label).tag(style.rawValue)
                        }
                    }
                    .disabled(styleRaw == PacerSettings.MenuBarStyle.percentOnly.rawValue
                              || styleRaw == PacerSettings.MenuBarStyle.hidden.rawValue)
                }
            }, footer: {
                Text("Hiding the menu bar item doesn't stop tracking — Pacer keeps collecting in the background as long as the app process is running. Open the dashboard from Spotlight or the Dock when needed.")
            })
        }
    }
}

// MARK: - Notifications

private struct NotificationsPanel: View {
    @AppStorage(PacerSettings.Key.notificationsEnabled, store: PacerSettings.store)
    private var enabled: Bool = false

    @AppStorage(PacerSettings.Key.notifyOnDailyCost, store: PacerSettings.store)
    private var dailyCostEnabled: Bool = false

    @AppStorage(PacerSettings.Key.dailyCostThresholdUSD, store: PacerSettings.store)
    private var dailyCostThreshold: Double = 50

    @AppStorage(PacerSettings.Key.notifyDailySummary, store: PacerSettings.store)
    private var dailySummaryEnabled: Bool = false

    @AppStorage(PacerSettings.Key.dailySummaryHour, store: PacerSettings.store)
    private var dailySummaryHour: Int = 21

    /// Always USD. Anthropic's pricing — and therefore everything
    /// `DailyAggregate.totalCostUSD` stores — is denominated in USD,
    /// so the threshold field must be USD too: a EUR-locale user
    /// typing "50" expects €50, but the underlying compare against
    /// today's-USD-cost would still treat it as $50 USD. The
    /// `.currency(code: "USD")` formatter keeps the code fixed while
    /// still picking up locale conventions for separator characters
    /// and currency-symbol placement.
    private let currencyCode: String = "USD"

    @State private var testStatus: TestStatus = .idle

    enum TestStatus {
        case idle, sending, sent, denied, failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PacerDesign.sectionSpacing) {
            PacerCard("Rate-limit alerts", content: {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Enable rate-limit notifications", isOn: $enabled)
                        .toggleStyle(.switch)
                        .onChange(of: enabled) { _, newValue in
                            if newValue {
                                Task {
                                    await NotificationCoordinator.shared
                                        .requestAuthorizationIfNeeded()
                                }
                            }
                        }
                    ThresholdListEditor(
                        title: "5-hour window",
                        window: "five_hour",
                        enabled: enabled
                    )
                    ThresholdListEditor(
                        title: "7-day window",
                        window: "seven_day",
                        enabled: enabled
                    )
                }
            }, footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add as many thresholds per window as you want — Pacer fires a separate banner each time usage crosses one upward (e.g. 50%, 75%, 90% in one 5-hour cycle). Each banner fires at most once per cycle. The first banner triggers the system permission prompt.")
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

            PacerCard("Daily cost alert", content: {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Notify when today's cost exceeds threshold", isOn: $dailyCostEnabled)
                        .toggleStyle(.switch)
                    HStack {
                        Text("Cost threshold")
                        Spacer()
                        TextField("Amount", value: $dailyCostThreshold,
                                  format: .currency(code: currencyCode))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 130)
                            .disabled(!dailyCostEnabled)
                    }
                }
            })

            PacerCard("Daily summary", content: {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Send a daily summary banner", isOn: $dailySummaryEnabled)
                        .toggleStyle(.switch)
                    HStack {
                        Text("Send at")
                        Spacer()
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

            PacerCard("Test", content: {
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
            })
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

    /// Locale-aware hour label for the daily-summary picker. 12-hour
    /// locales get "9 PM"; 24-hour locales get "21:00".
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

    /// Open System Settings → Notifications, falling back to the
    /// Settings root if Apple renames the extension URL again
    /// (`com.apple.Notifications-Settings.extension` is correct
    /// through macOS 15; this guards against a Sequoia point release
    /// or Tahoe move). NSWorkspace returns false synchronously when
    /// the URL doesn't resolve, so we can chain a fallback.
    private func openNotificationsSettings() {
        let direct = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        if NSWorkspace.shared.open(direct) {
            return
        }
        let root = URL(string: "x-apple.systempreferences:")!
        NSWorkspace.shared.open(root)
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

extension NotificationsPanel.TestStatus: Equatable {
    fileprivate static func == (lhs: NotificationsPanel.TestStatus, rhs: NotificationsPanel.TestStatus) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.sending, .sending), (.sent, .sent), (.denied, .denied):
            return true
        case (.failed, .failed): return true
        default: return false
        }
    }
}

// MARK: - Threshold list editor

/// One window's worth of notification thresholds as an editable list.
/// Each row is an independent threshold; rows can be added, removed,
/// and individually adjusted. Persists through `PacerSettings`'s CSV
/// helpers so the live `NotificationCoordinator` (also reading via
/// `PacerSettings.thresholds(forWindow:)`) sees changes immediately.
private struct ThresholdListEditor: View {
    let title: String
    let window: String
    let enabled: Bool

    @State private var thresholds: [Int] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(enabled ? .primary : .secondary)
                Spacer()
                Button {
                    addThreshold()
                } label: {
                    Label("Add threshold", systemImage: "plus.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(!enabled)
            }
            if thresholds.isEmpty {
                Text("No thresholds — Pacer won't notify for this window.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
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
        .padding(.vertical, 4)
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
        // Re-read so the displayed list reflects sort/dedup applied
        // by the writer.
        thresholds = PacerSettings.thresholds(forWindow: window)
    }

    private func addThreshold() {
        // Pick a sensible default: midpoint of "above the highest
        // existing threshold" and 99, or 75 if the list is empty.
        // Avoids dropping a duplicate of an existing value.
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
///
/// Slider drops the `step:` parameter — that's what was causing the
/// per-percent tick marks the user flagged as visual noise. We snap
/// to whole percentages on read instead.
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
                .font(.system(size: 12, weight: .semibold, design: .rounded))
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

// MARK: - Cost calculation

private struct CostPanel: View {
    @AppStorage(PacerSettings.Key.costMode, store: PacerSettings.store)
    private var costMode: String = "auto"

    var body: some View {
        VStack(alignment: .leading, spacing: PacerDesign.sectionSpacing) {
            PacerCard("Cost calculation", content: {
                Picker("Mode", selection: $costMode) {
                    Text("Auto (prefer stored, calculate when missing)").tag("auto")
                    Text("Calculate (always from tokens × pricing)").tag("calculate")
                    Text("Display (only stored Claude Code costs)").tag("display")
                }
                .pickerStyle(.radioGroup)
            }, footer: {
                Text("**Auto** matches `bun x ccusage`. **Calculate** is what you want when older Claude Code lines lack `costUSD`. **Display** only shows server-supplied numbers and ignores tokens that didn't come with one.")
            })
        }
    }
}

// MARK: - Storage

private struct StoragePanel: View {
    private var storeURL: URL? { try? PacerStore.storeURL() }

    private var logsDirURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Pacer")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PacerDesign.sectionSpacing) {
            PacerCard("Database", content: {
                if let url = storeURL {
                    HStack {
                        Text(url.path)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                } else {
                    Text("App Group container unavailable.")
                        .foregroundStyle(.secondary)
                }
            })

            PacerCard("Logs", content: {
                HStack {
                    Text(logsDirURL.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Open in Finder") {
                        NSWorkspace.shared.open(logsDirURL)
                    }
                }
            })
        }
    }
}

// (No "About" tab here — App menu → "About Pacer" opens the native
// NSPanel with logo, version, and credits. Keyboard shortcuts are
// discoverable through the menu bar where they're listed alongside
// each command.)
