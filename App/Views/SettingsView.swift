import SwiftUI
import PacerCore

/// Pacer's preferences UI. Embedded as a tab in the main window
/// (`Cmd+5`) and reachable via `Cmd+,` and the menu-bar popover. All
/// values bind to the App Group `UserDefaults` (via `PacerSettings`)
/// so the menu bar, in-process scan, and widgets pick up changes
/// without restart.
///
/// This is one scrollable Form rather than a nested TabView because
/// the parent ContentView already owns the top-level Tab structure —
/// nesting tabs gets visually noisy. Sections + a left-side category
/// chooser would also work; flat sections are simpler and match the
/// vibe of macOS's small-app settings.
struct SettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Settings")
                    .font(.largeTitle.weight(.semibold))
                    .padding(.bottom, 4)

                StartupSection()
                MenuBarSection()
                NotificationsSection()
                CostModeSection()
                StorageSection()
                AboutSection()
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 640, minHeight: 600)
    }
}

// MARK: - Section card primitive

private struct SectionCard<Content: View>: View {
    let title: String
    let footer: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String, footer: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))
            content()
            if let footer {
                Text(.init(footer))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Startup

private struct StartupSection: View {
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
        SectionCard(
            "Startup",
            footer: "When enabled, Pacer launches at login and runs in the background — no window opens unless you open it explicitly. Data collection (JSONL scan + OAuth poll) starts automatically and continues even when no window is visible."
        ) {
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
        SectionCard(
            "Menu Bar",
            footer: "Hiding the menu bar item doesn't stop tracking — Pacer keeps collecting in the background as long as the app process is running. Open the dashboard from Spotlight or the Dock when needed."
        ) {
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
    }
}

// MARK: - Notifications

private struct NotificationsSection: View {
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
        SectionCard(
            "Notifications",
            footer: "Notifications fire at most once per cycle. The first banner triggers the system permission prompt; if you click Don't Allow you can re-enable in System Settings → Notifications → Pacer."
        ) {
            Toggle("Enable rate-limit notifications", isOn: $enabled)
                .onChange(of: enabled) { _, newValue in
                    if newValue {
                        Task {
                            await NotificationCoordinator.shared
                                .requestAuthorizationIfNeeded()
                        }
                    }
                }
            HStack {
                Text("5-hour window crosses…")
                Spacer()
                Picker("", selection: $fiveHourPct) {
                    Text("50%").tag(50)
                    Text("75%").tag(75)
                    Text("90%").tag(90)
                }
                .labelsHidden()
                .frame(width: 80)
                .disabled(!enabled)
            }
            HStack {
                Text("7-day window crosses…")
                Spacer()
                Picker("", selection: $sevenDayPct) {
                    Text("50%").tag(50)
                    Text("75%").tag(75)
                    Text("90%").tag(90)
                }
                .labelsHidden()
                .frame(width: 80)
                .disabled(!enabled)
            }
            Divider()
            Toggle("Notify when today's cost exceeds threshold", isOn: $dailyCostEnabled)
            HStack {
                Text("Cost threshold")
                Spacer()
                TextField("USD", value: $dailyCostThreshold, format: .currency(code: "USD"))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
                    .disabled(!dailyCostEnabled)
            }
            Divider()
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

extension NotificationsSection.TestStatus: Equatable {
    fileprivate static func == (lhs: NotificationsSection.TestStatus, rhs: NotificationsSection.TestStatus) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.sending, .sending), (.sent, .sent), (.denied, .denied):
            return true
        case (.failed, .failed): return true
        default: return false
        }
    }
}

// MARK: - Cost calculation

private struct CostModeSection: View {
    @AppStorage(PacerSettings.Key.costMode, store: PacerSettings.store)
    private var costMode: String = "auto"

    var body: some View {
        SectionCard(
            "Cost calculation",
            footer: "**Auto** matches `bun x ccusage`. **Calculate** is what you want when older Claude Code lines lack `costUSD`. **Display** only shows server-supplied numbers and ignores tokens that didn't come with one."
        ) {
            Picker("Mode", selection: $costMode) {
                Text("Auto (prefer stored, calculate when missing)").tag("auto")
                Text("Calculate (always from tokens × pricing)").tag("calculate")
                Text("Display (only stored Claude Code costs)").tag("display")
            }
            .pickerStyle(.radioGroup)
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
        SectionCard("Storage") {
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
                Text("Logs")
                Spacer()
                Button("Open Logs Folder") {
                    NSWorkspace.shared.open(logsDirURL)
                }
            }
        }
    }
}

// MARK: - About

private struct AboutSection: View {
    private let buildVersion: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }()
    private let buildNumber: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }()

    var body: some View {
        SectionCard(
            "About",
            footer: "Storage is local to this Mac. Nothing leaves your machine except the 5-minute OAuth poll to api.anthropic.com."
        ) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "speedometer")
                    .font(.system(size: 36))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pacer")
                        .font(.title2.weight(.semibold))
                    Text("Version \(buildVersion) (build \(buildNumber))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
            }
            Divider()
            Text("Shortcuts")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                shortcutLine("⌘1 / ⌘2 / ⌘3 / ⌘4 / ⌘5", "Switch tabs")
                shortcutLine("⌘,", "Jump to Settings tab")
                shortcutLine("⌘⇧E", "Export today's daily totals")
            }
        }
    }

    @ViewBuilder
    private func shortcutLine(_ shortcut: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Text(shortcut)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 160, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
