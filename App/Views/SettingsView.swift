import SwiftUI
import PacerCore

/// macOS Settings scene. Opens via Cmd+, (the standard macOS shortcut)
/// or via the app menu. Bound to the App Group `UserDefaults` so any
/// other Pacer surface (menu bar, daemon, widgets, future statusline
/// tap) sees the same values.
struct SettingsView: View {
    var body: some View {
        TabView {
            MenuBarSettingsTab()
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            NotificationSettingsTab()
                .tabItem { Label("Notifications", systemImage: "bell.badge") }
            DataSettingsTab()
                .tabItem { Label("Data", systemImage: "cylinder.split.1x2") }
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 500, height: 380)
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
                Text("Hiding the menu bar item doesn't disable the daemon — usage is still tracked. The dashboard is always available from the dock.")
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

    var body: some View {
        Form {
            Section("Rate-limit warnings") {
                Toggle("Enable rate-limit notifications", isOn: $enabled)
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
            Section {
                Text("Notifications fire at most once per cycle. Approve the system prompt the first time a notification posts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Data tab

private struct DataSettingsTab: View {
    @AppStorage(PacerSettings.Key.costMode, store: PacerSettings.store)
    private var costMode: String = "auto"

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
        VStack(spacing: 16) {
            Image(systemName: "speedometer")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Pacer")
                .font(.largeTitle.weight(.semibold))
            Text("Version \(buildVersion) (build \(buildNumber))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Tracks Claude Code usage, costs, and rate-limit pacing.")
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
            Text("Storage is local to this Mac. Nothing leaves your machine except the OAuth poll to api.anthropic.com.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
