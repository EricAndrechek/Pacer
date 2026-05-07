import SwiftUI

/// Top-level shell. The Dashboard tab is what most users will see;
/// Debug is preserved as a developer/QA aid (sample counts, raw meta
/// keys, LaunchAgent buttons, recent JSONL rows). The split keeps
/// each view focused — `DashboardView` doesn't carry @State for
/// LaunchAgent buttons it doesn't render.
struct ContentView: View {
    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "chart.bar.xaxis") }

            DebugView()
                .tabItem { Label("Debug", systemImage: "terminal") }
        }
        .frame(minWidth: 720, minHeight: 600)
    }
}
