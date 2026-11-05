import SwiftUI
import SwiftData
import PacerCore

/// The dashboard window's content: the real dashboard once the store is open,
/// a plain placeholder while it is still being migrated (#376).
///
/// The state is read here, by value, in this body, so this view is what
/// redraws when the store opens (AGENTS.md, "SwiftUI state and data flow").
/// The container and engines go on `ContentView` here rather than on the
/// `Window` scene, which cannot wait for them; the scene declaration itself is
/// unchanged, so opening the store late adds no window churn: the same window
/// swaps its content.
struct DashboardRoot: View {
    let loader: StoreLoader

    var body: some View {
        switch loader.state {
        case .ready(let store):
            ContentView()
                // Hand the shared intelligence engine to the view tree so
                // cards can ask it typed questions.
                .environment(\.usageEngine, store.engine)
                .environment(\.usageEngines, store.engines)
                .modelContainer(store.container)
        case .opening:
            StoreOpeningView(failed: false)
        case .failed:
            StoreOpeningView(failed: true)
        }
    }
}

/// What the dashboard shows while the first launch after an update migrates
/// the store. Usually a second or two; longer for a store with years in it.
struct StoreOpeningView: View {
    let failed: Bool

    var body: some View {
        VStack(spacing: 12) {
            if !failed {
                ProgressView()
                    .controlSize(.small)
            }
            Text(failed ? "Pacer can't open its data store" : "Updating your data…")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        // The dashboard's own floor (`ContentView`), so the window keeps its
        // size when the real content replaces this.
        .frame(minWidth: 880, maxWidth: .infinity, minHeight: 620, maxHeight: .infinity)
    }
}
