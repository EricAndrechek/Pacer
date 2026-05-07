import SwiftUI

/// Top-level shell. Five tabs: Dashboard / History / Projects / Models /
/// Settings. ⌘1..5 switches between them; ⌘, jumps to Settings.
///
/// Settings lives in the main window (this tab) rather than as the
/// macOS-standard separate Settings scene — the user wanted everything
/// in one window. The standard `Cmd+,` shortcut still works because
/// `PacerApp` posts a notification we observe here to flip the tab.
struct ContentView: View {
    /// Tab identifier kept as enum so `Cmd+1..5` keyboard shortcuts
    /// can target it directly via `selection`.
    enum Tab: Hashable {
        case dashboard, history, projects, models, settings
    }
    @State private var selection: Tab = .dashboard

    var body: some View {
        TabView(selection: $selection) {
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "chart.bar.xaxis") }
                .tag(Tab.dashboard)
                .keyboardShortcut("1", modifiers: .command)

            HistoryView()
                .tabItem { Label("History", systemImage: "calendar") }
                .tag(Tab.history)
                .keyboardShortcut("2", modifiers: .command)

            ProjectsView()
                .tabItem { Label("Projects", systemImage: "folder") }
                .tag(Tab.projects)
                .keyboardShortcut("3", modifiers: .command)

            ModelsView()
                .tabItem { Label("Models", systemImage: "cpu") }
                .tag(Tab.models)
                .keyboardShortcut("4", modifiers: .command)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
                .keyboardShortcut("5", modifiers: .command)
        }
        .frame(minWidth: 720, minHeight: 600)
        .onReceive(NotificationCenter.default.publisher(for: .pacerOpenSettings)) { _ in
            selection = .settings
        }
    }
}

extension Notification.Name {
    /// Fired by the Cmd+, command and the menu-bar Settings button. The
    /// main `ContentView` observes it and flips its tab selection to
    /// Settings — single source of truth for "show settings" without a
    /// separate Settings scene.
    static let pacerOpenSettings = Notification.Name("PacerOpenSettings")
}
