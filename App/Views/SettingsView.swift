import SwiftUI
import PacerCore

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
        case general, menuBar, notifications, cost, storage, about

        var id: String { rawValue }
        var label: String {
            switch self {
            case .general:       return "General"
            case .menuBar:       return "Menu Bar"
            case .notifications: return "Notifications"
            case .cost:          return "Cost"
            case .storage:       return "Storage"
            case .about:         return "About"
            }
        }
        var systemImage: String {
            switch self {
            case .general:       return "switch.2"
            case .menuBar:       return "menubar.rectangle"
            case .notifications: return "bell.badge.fill"
            case .cost:          return "dollarsign.circle.fill"
            case .storage:       return "externaldrive.fill"
            case .about:         return "info.circle.fill"
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
                .font(.system(size: 18, weight: .semibold, design: .rounded))
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
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
    }

    // MARK: - Content pane

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PacerDesign.sectionSpacing) {
                Text(category.label)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .padding(.bottom, 4)

                switch category {
                case .general:       GeneralPanel()
                case .menuBar:       MenuBarPanel()
                case .notifications: NotificationsPanel()
                case .cost:          CostPanel()
                case .storage:       StoragePanel()
                case .about:         AboutPanel()
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
                Image(systemName: category.systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : .secondary)
                    .frame(width: 18, alignment: .center)
                Text(category.label)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
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
                    threshold("5-hour window crosses", binding: $fiveHourPct)
                    threshold("7-day window crosses", binding: $sevenDayPct)
                }
            }, footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Notifications fire at most once per cycle, and only on a fresh upward crossing. The first banner triggers the system permission prompt.")
                    HStack(spacing: 8) {
                        Text("Not seeing banners?")
                        Button("Open System Settings → Notifications") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
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
                        TextField("USD", value: $dailyCostThreshold, format: .currency(code: "USD"))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 110)
                            .disabled(!dailyCostEnabled)
                    }
                }
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

    /// Threshold row with a slider + numeric stepper. Replaces the
    /// fixed 50/75/90 picker so users can pick any percentage from
    /// 1-99 — wanted custom alert points (e.g. 80%, 95%) for finer
    /// control.
    @ViewBuilder
    private func threshold(_ label: String, binding: Binding<Int>) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .frame(maxWidth: .infinity, alignment: .leading)
            Slider(
                value: Binding(
                    get: { Double(binding.wrappedValue) },
                    set: { binding.wrappedValue = Int($0.rounded()) }
                ),
                in: 1...99,
                step: 1
            )
            .frame(width: 160)
            .disabled(!enabled)
            Text("\(binding.wrappedValue)%")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(enabled ? .primary : .secondary)
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

// MARK: - About

private struct AboutPanel: View {
    private let buildVersion: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }()
    private let buildNumber: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: PacerDesign.sectionSpacing) {
            PacerCard {
                HStack(alignment: .top, spacing: 16) {
                    Image("PacerLogo")
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 64, height: 64)
                        .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pacer")
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                        Text("Version \(buildVersion) (build \(buildNumber))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text("Native macOS tracking for Claude Code usage.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                    Spacer()
                }
            }

            PacerCard("Keyboard shortcuts") {
                VStack(alignment: .leading, spacing: 8) {
                    shortcutRow("⌘ 1 – ⌘ 5", "Switch sidebar destinations")
                    shortcutRow("⌘ ,", "Jump to Settings")
                    shortcutRow("⌘ ⇧ E", "Export today's daily totals")
                }
            }

            PacerCard {
                Text("Storage is local to this Mac. Nothing leaves your machine except the 5-minute OAuth poll to api.anthropic.com.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func shortcutRow(_ shortcut: String, _ description: String) -> some View {
        HStack(spacing: 12) {
            Text(shortcut)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(0.06))
                )
                .frame(width: 130, alignment: .leading)
            Text(description)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}
