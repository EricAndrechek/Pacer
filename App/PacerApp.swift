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
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
}
