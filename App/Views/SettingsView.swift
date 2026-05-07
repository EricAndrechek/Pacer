import SwiftUI
import PacerCore

/// macOS Settings scene. Opens via Cmd+, (the standard macOS shortcut)
/// or via the app menu. Bound to the App Group `UserDefaults` so any
/// other Pacer surface (menu bar, daemon, widgets, future statusline
/// tap) sees the same values.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            MenuBarSettingsTab()
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            NotificationSettingsTab()
                .tabItem { Label("Notifications", systemImage: "bell.badge") }
            DataSettingsTab()
                .tabItem { Label("Data", systemImage: "cylinder.split.1x2") }
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 500, height: 420)
    }
}

// MARK: - General tab

private struct GeneralSettingsTab: View {
    @State private var loginItemStatus: LoginItemController.Status = .unknown
    @State private var actionError: String?

    /// Toggle is bound to a derived "is the SMAppService.mainApp
    /// currently registered" view of state, not to a UserDefaults
    /// flag. macOS owns the source of truth (the user can toggle this
    /// from System Settings → Login Items too), and reading it back
    /// from SMAppService keeps Pacer's UI in sync.
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
        Form {
            Section("Startup") {
                Toggle("Open Pacer at Login", isOn: isEnabled)
                if loginItemStatus == .requiresApproval {
                    HStack(spacing: 6) {
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
            Section {
                Text("When enabled, Pacer launches at login and runs in the background — no window opens unless you open it explicitly. Data collection (JSONL scan + OAuth poll) starts automatically and continues even when no window is visible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { refresh() }
    }

    private func refresh() {
        loginItemStatus = LoginItemController.currentStatus()
    }
}

// MARK: - Menu Bar tab

private struct MenuBarSettingsTab: View {
    @AppStorage(PacerSettings.Key.menuBarStyle, store: PacerSettings.store)
    private var styleRaw: String = PacerSettings.MenuBarStyle.iconAndPercent.rawValue

    @AppStorage(PacerSettings.Key.menuBarIconStyle, store: PacerSettings.store)
    private var iconRaw: String = PacerSettings.MenuBarIconStyle.gaugeNeedle.rawValue

    var body: some View {
        Form {
            Section("Display") {
                Picker("What to show", selection: $styleRaw) {
                    ForEach(PacerSettings.MenuBarStyle.allCases) { style in
                        Text(style.label).tag(style.rawValue)
                    }
                }
                Picker("Icon", selection: $iconRaw) {
                    ForEach(PacerSettings.MenuBarIconStyle.allCases) { style in
                        Text(style.label).tag(style.rawValue)
                    }
                }
                .disabled(styleRaw == PacerSettings.MenuBarStyle.percentOnly.rawValue
                          || styleRaw == PacerSettings.MenuBarStyle.hidden.rawValue)
            }
            Section {
                Text("Hiding the menu bar item doesn't stop tracking — Pacer keeps collecting in the background as long as the app process is running. Open the dashboard from Spotlight or the Dock when needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Notifications tab

private struct NotificationSettingsTab: View {
    @AppStorage(PacerSettings.Key.notificationsEnabled, store: PacerSettings.store)
    private var enabled: Bool = false

    @AppStorage(PacerSettings.Key.fiveHourThresholdPct, store: PacerSettings.store)
    private var fiveHourPct: Int = 75

    @AppStorage(PacerSettings.Key.sevenDayThresholdPct, store: PacerSettings.store)
    private var sevenDayPct: Int = 75

    @AppStorage(PacerSettings.Key.notifyOnDailyCost, store: PacerSettings.store)
    private var dailyCostEnabled: Bool = false

    @AppStorage(PacerSettings.Key.dailyCostThresholdUSD, store: PacerSettings.store)
    private var dailyCostThreshold: Double = 50

    @State private var testStatus: TestStatus = .idle
    enum TestStatus {
        case idle, sending, sent, denied, failed(String)
    }

    var body: some View {
        Form {
            Section("Rate-limit warnings") {
                Toggle("Enable rate-limit notifications", isOn: $enabled)
                    .onChange(of: enabled) { _, newValue in
                        if newValue {
                            // Pre-warm system permission as soon as
                            // the user opts in; the system shows the
                            // grant prompt at most once across these
                            // calls, and otherwise we'd silently swallow
                            // every threshold crossing until they
                            // happened to send a test notification.
                            Task {
                                await NotificationCoordinator.shared
                                    .requestAuthorizationIfNeeded()
                            }
                        }
                    }
                Picker("5-hour window crosses…", selection: $fiveHourPct) {
                    Text("50%").tag(50)
                    Text("75%").tag(75)
                    Text("90%").tag(90)
                }
                .disabled(!enabled)
                Picker("7-day window crosses…", selection: $sevenDayPct) {
                    Text("50%").tag(50)
                    Text("75%").tag(75)
                    Text("90%").tag(90)
                }
                .disabled(!enabled)
            }
            Section("Spend warnings") {
                Toggle("Notify when today's cost exceeds threshold", isOn: $dailyCostEnabled)
                HStack {
                    Text("Threshold")
                    Spacer()
                    TextField("USD", value: $dailyCostThreshold, format: .currency(code: "USD"))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                }
                .disabled(!dailyCostEnabled)
            }
            Section("Verify") {
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
                }
            }
            Section {
                Text("Notifications fire at most once per cycle. The first banner triggers the system permission prompt; if you click Don't Allow you can re-enable in System Settings → Notifications → Pacer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var testLabel: String? {
        switch testStatus {
        case .idle:        return nil
        case .sending:     return "sending…"
        case .sent:        return "sent ✓"
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

extension NotificationSettingsTab.TestStatus: Equatable {
    fileprivate static func == (lhs: NotificationSettingsTab.TestStatus, rhs: NotificationSettingsTab.TestStatus) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.sending, .sending), (.sent, .sent), (.denied, .denied):
            return true
        case (.failed, .failed): return true
        default: return false
        }
    }
}

// MARK: - Data tab

private struct DataSettingsTab: View {
    @AppStorage(PacerSettings.Key.costMode, store: PacerSettings.store)
    private var costMode: String = "auto"

    private var storeURL: URL? {
        try? PacerStore.storeURL()
    }

    private var logsDirURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Pacer")
    }

    var body: some View {
        Form {
            Section("Cost calculation") {
                Picker("Mode", selection: $costMode) {
                    Text("Auto (prefer stored, calculate when missing)").tag("auto")
                    Text("Calculate (always from tokens × pricing)").tag("calculate")
                    Text("Display (only stored Claude Code costs)").tag("display")
                }
                .pickerStyle(.radioGroup)
            }
            Section {
                Text("`Auto` matches `bun x ccusage`. `Calculate` is what you want when older Claude Code lines lack `costUSD`. `Display` only shows server-supplied numbers and ignores tokens that didn't come with one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Storage") {
                if let url = storeURL {
                    HStack {
                        Text(url.path)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer()
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                } else {
                    Text("App Group container unavailable.")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Daemon logs")
                        .font(.caption)
                    Spacer()
                    Button("Open Logs Folder") {
                        NSWorkspace.shared.open(logsDirURL)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - About tab

private struct AboutTab: View {
    private let buildVersion: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }()
    private let buildNumber: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }()

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "speedometer")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Pacer")
                .font(.largeTitle.weight(.semibold))
            Text("Version \(buildVersion) (build \(buildNumber))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text("Tracks Claude Code usage, costs, and rate-limit pacing.")
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            shortcutHints
            Spacer()
            Text("Storage is local to this Mac. Nothing leaves your machine except the 5-minute OAuth poll to api.anthropic.com.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var shortcutHints: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Shortcuts")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            shortcutLine("⌘1 / ⌘2 / ⌘3 / ⌘4 / ⌘5", "Switch tabs")
            shortcutLine("⌘,", "Open Settings")
            shortcutLine("⌘⇧E", "Export today's daily totals")
        }
        .font(.caption)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func shortcutLine(_ shortcut: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Text(shortcut)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 130, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(text)
                .foregroundStyle(.secondary)
        }
    }
}
