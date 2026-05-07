import SwiftUI
import SwiftData
import PacerCore

@main
struct PacerApp: App {
    let container: ModelContainer

    init() {
        do {
            container = try PacerStore.makeModelContainer()
        } catch {
            fatalError("Failed to open shared SwiftData container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
        }
        .modelContainer(container)

        // Menu bar status item — at-a-glance 5h rate-limit %, click for
        // a compact popover with both windows and today's totals.
        // Dashboard remains the detail view.
        MenuBarExtra {
            MenuBarContent()
                .modelContainer(container)
        } label: {
            MenuBarLabel()
                .modelContainer(container)
        }
        .menuBarExtraStyle(.window)
    }
}
