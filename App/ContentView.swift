import SwiftUI

/// Top-level shell. The Dashboard tab is what most users will see;
/// Debug is preserved as a developer/QA aid (sample counts, raw meta
/// keys, LaunchAgent buttons, recent JSONL rows). The split keeps
/// each view focused — `DashboardView` doesn't carry @State for
/// LaunchAgent buttons it doesn't render.
struct ContentView: View {
    /// Tab identifier kept as enum so `Cmd+1..4` keyboard shortcuts
    /// can target it directly via `selection`.
    enum Tab: Hashable {
        case dashboard, history, projects, debug
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

            DebugView()
                .tabItem { Label("Debug", systemImage: "terminal") }
                .tag(Tab.debug)
                .keyboardShortcut("4", modifiers: .command)
        }
        .frame(minWidth: 720, minHeight: 600)
    }
}
