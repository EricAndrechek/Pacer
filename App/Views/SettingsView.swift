import SwiftUI
import PacerCore
import PacerUI

/// Pacer's preferences UI. Embedded as the 5th destination in the main
/// window's sidebar (`Cmd+5`) and reachable via `Cmd+,` and the menu-
/// bar popover. All values bind to the App Group `UserDefaults` (via
/// `PacerSettings`) so the menu bar, in-process scan, and widgets pick
/// up changes without a restart.
///
/// Layout: one scrolling `Form` with every settings section inline.
/// Earlier iterations split the sections behind an inner-sidebar
/// "tabs in tabs" pattern that mimicked macOS Sequoia System Settings
/// — but at the size of Pacer's settings surface, the inner sidebar
/// was overkill and introduced background-color contrast issues
/// against the outer NavigationSplitView sidebar. A single grouped
/// Form is the idiom Mail, Notes, Reminders, and similar single-app
/// settings panes use; sections give the same visual grouping the
/// inner sidebar provided.
struct SettingsView: View {
    var body: some View {
        Form {
            StartupSection()
            MenuBarSection()
            RateLimitAlertsSection()
            ThresholdSection(title: "5-hour window", window: "five_hour")
            ThresholdSection(title: "7-day window", window: "seven_day")
            DailyCostAlertSection()
            DailySummarySection()
            NotificationTestSection()
            CostCalculationSection()
            StorageSection()
        }
        .formStyle(.grouped)
        // Constrain the detail pane so a wide window doesn't stretch
        // the form rows to the full window width — settings forms
        // read best at moderate width even when the user has a 27"
        // display.
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Startup

private struct StartupSection: View {
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
        Section {
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
        } header: {
            Text("Startup")
        } footer: {
            Text("When enabled, Pacer launches at login and runs in the background — no window opens unless you open it explicitly. Data collection (JSONL scan + OAuth poll) starts automatically and continues even when no window is visible.")
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        loginItemStatus = LoginItemController.currentStatus()
    }
}

// MARK: - Menu Bar

private struct MenuBarSection: View {
    @AppStorage(PacerSettings.Key.menuBarStyle, store: PacerSettings.store)
    private var styleRaw: String = PacerSettings.MenuBarStyle.iconAndPercent.rawValue

    @AppStorage(PacerSettings.Key.menuBarIconStyle, store: PacerSettings.store)
    private var iconRaw: String = PacerSettings.MenuBarIconStyle.gaugeNeedle.rawValue

    var body: some View {
        Section {
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
        } header: {
            Text("Menu bar")
        } footer: {
            Text("Hiding the menu bar item doesn't stop tracking — Pacer keeps collecting in the background as long as the app process is running. Open the dashboard from Spotlight or the Dock when needed.")
        }
    }
}

// MARK: - Rate-limit alerts

private struct RateLimitAlertsSection: View {
    @AppStorage(PacerSettings.Key.notificationsEnabled, store: PacerSettings.store)
    private var enabled: Bool = false

    var body: some View {
        Section {
            Toggle("Enable rate-limit notifications", isOn: $enabled)
                .onChange(of: enabled) { _, newValue in
                    if newValue {
                        Task {
                            await NotificationCoordinator.shared
                                .requestAuthorizationIfNeeded()
                        }
                    }
                }
        } header: {
            Text("Rate-limit alerts")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Add thresholds per window — Pacer fires a banner each time usage crosses one upward (e.g. 50%, 75%, 90% in one 5-hour cycle). Each banner fires at most once per cycle. The first banner triggers the system permission prompt.")
                HStack(spacing: 8) {
                    Text("Not seeing banners?")
                    Button("Open System Settings → Notifications") {
                        openNotificationsSettings()
                    }
                    .controlSize(.small)
                }
                Text("Pacer's banner style is set there — choose **Banners** or **Alerts** rather than **None**.")
            }
        }
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
}

// MARK: - Threshold list section

/// One window's worth of notification thresholds, rendered as a Form
/// `Section`. Each row is an independent threshold; rows can be added,
/// removed, and individually adjusted. Persists through
/// `PacerSettings`'s helpers so the live `NotificationCoordinator`
/// (also reading via `PacerSettings.thresholds(forWindow:)`) sees
/// changes immediately.
private struct ThresholdSection: View {
    let title: String
    let window: String

    @AppStorage(PacerSettings.Key.notificationsEnabled, store: PacerSettings.store)
    private var enabled: Bool = false
    @State private var thresholds: [Int] = []

    var body: some View {
        Section {
            if thresholds.isEmpty {
                Text("No thresholds — Pacer won't notify for this window.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(thresholds.enumerated()), id: \.offset) { idx, _ in
                    ThresholdRow(
                        value: thresholdBinding(for: idx),
                        enabled: enabled,
                        onRemove: { remove(at: idx) }
                    )
                }
            }
            Button {
                addThreshold()
            } label: {
                Label("Add threshold", systemImage: "plus.circle.fill")
            }
            .disabled(!enabled)
        } header: {
            Text(title)
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

private struct DailyCostAlertSection: View {
    @AppStorage(PacerSettings.Key.notifyOnDailyCost, store: PacerSettings.store)
    private var dailyCostEnabled: Bool = false

    @AppStorage(PacerSettings.Key.dailyCostThresholdUSD, store: PacerSettings.store)
    private var dailyCostThreshold: Double = 50

    /// Always USD. Anthropic's pricing — and therefore everything
    /// `DailyAggregate.totalCostUSD` stores — is denominated in USD,
    /// so the threshold field must be USD too: a EUR-locale user
    /// typing "50" expects €50, but the underlying compare against
    /// today's-USD-cost would still treat it as $50 USD. The
    /// `.currency(code: "USD")` formatter keeps the code fixed while
    /// still picking up locale conventions for separator characters
    /// and currency-symbol placement.
    private let currencyCode: String = "USD"

    var body: some View {
        Section("Daily cost alert") {
            Toggle("Notify when today's cost exceeds threshold", isOn: $dailyCostEnabled)
            // LabeledContent + paired Stepper is the macOS-native
            // pattern for "typed numeric value with up/down arrows."
            LabeledContent("Cost threshold") {
                HStack(spacing: 4) {
                    TextField("Amount", value: $dailyCostThreshold,
                              format: .currency(code: currencyCode))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 110)
                    Stepper("", value: $dailyCostThreshold, in: 1...10_000, step: 5)
                        .labelsHidden()
                }
            }
            .disabled(!dailyCostEnabled)
        }
    }
}

// MARK: - Daily summary

private struct DailySummarySection: View {
    @AppStorage(PacerSettings.Key.notifyDailySummary, store: PacerSettings.store)
    private var dailySummaryEnabled: Bool = false

    @AppStorage(PacerSettings.Key.dailySummaryHour, store: PacerSettings.store)
    private var dailySummaryHour: Int = 21

    var body: some View {
        Section {
            Toggle("Send a daily summary banner", isOn: $dailySummaryEnabled)
            Picker("Send at", selection: $dailySummaryHour) {
                ForEach(0..<24, id: \.self) { h in
                    Text(formatHour(h)).tag(h)
                }
            }
            .disabled(!dailySummaryEnabled)
        } header: {
            Text("Daily summary")
        } footer: {
            Text("Quiet, informational banner showing today's spend and top model. Fires once per day after the chosen time, only if you've used Claude Code that day.")
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
}

// MARK: - Notification test

private struct NotificationTestSection: View {
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
        Section("Notification test") {
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

private struct CostCalculationSection: View {
    @AppStorage(PacerSettings.Key.costMode, store: PacerSettings.store)
    private var costMode: String = "auto"

    var body: some View {
        Section {
            Picker("Mode", selection: $costMode) {
                Text("Auto (prefer stored, calculate when missing)").tag("auto")
                Text("Calculate (always from tokens × pricing)").tag("calculate")
                Text("Display (only stored Claude Code costs)").tag("display")
            }
            .pickerStyle(.radioGroup)
        } header: {
            Text("Cost calculation")
        } footer: {
            Text("**Auto** matches `bun x ccusage`. **Calculate** is what you want when older Claude Code lines lack `costUSD`. **Display** only shows server-supplied numbers and ignores tokens that didn't come with one.")
        }
    }
}

// MARK: - Storage

private struct StorageSection: View {
    private var storeURL: URL? { try? PacerStore.storeURL() }

    private var logsDirURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Pacer")
    }

    var body: some View {
        Section("Database") {
            if let url = storeURL {
                LabeledContent("Location") {
                    Text(url.path)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            } else {
                Text("App Group container unavailable.")
                    .foregroundStyle(.secondary)
            }
        }

        Section("Logs") {
            LabeledContent("Location") {
                Text(logsDirURL.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack {
                Spacer()
                Button("Open in Finder") {
                    NSWorkspace.shared.open(logsDirURL)
                }
            }
        }
    }
}

// (No "About" section here — App menu → "About Pacer" opens the native
// NSPanel with logo, version, and credits.)
