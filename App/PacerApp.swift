import SwiftUI
import SwiftData
import PacerCore

@main
struct PacerApp: App {
    let container: ModelContainer

    @AppStorage(PacerSettings.Key.menuBarStyle, store: PacerSettings.store)
    private var menuBarStyleRaw: String = PacerSettings.MenuBarStyle.iconAndPercent.rawValue

    init() {
        // Make sure the App Group UserDefaults suite has the right
        // shape from launch one — `@AppStorage` only honors its
        // default-value parameter when the key is totally absent;
        // having `register(defaults:)` fire at app start means a
        // first-run user sees the same settings as someone who
        // already changed and reverted them.
        PacerSettings.registerDefaults()
        do {
            container = try PacerStore.makeModelContainer()
        } catch {
            fatalError("Failed to open shared SwiftData container: \(error)")
        }
    }

    private var showMenuBar: Bool {
        menuBarStyleRaw != PacerSettings.MenuBarStyle.hidden.rawValue
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                // NotificationsHost is invisible (zero size) but holds
                // @Query subscriptions that fire when new RateLimit
                // samples or DailyAggregate updates arrive. Living
                // alongside ContentView keeps it scoped to the app's
                // foreground lifetime.
                .background(NotificationsHost())
        }
        .modelContainer(container)
        .commands {
            CommandGroup(after: .importExport) {
                Divider()
                Button("Export Daily Totals…") {
                    let context = ModelContext(container)
                    CSVExporter.dailyTotals(context: context)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Export Daily by Model…") {
                    let context = ModelContext(container)
                    CSVExporter.dailyByModel(context: context)
                }
                Button("Export Project Totals…") {
                    let context = ModelContext(container)
                    CSVExporter.projectTotals(context: context)
                }
            }
        }

        // Standard macOS Settings scene — opened via Cmd+, or the
        // app menu's "Settings..." item. Lives in its own window.
        Settings {
            SettingsView()
        }

        // Menu bar status item. We use `isInserted` so the user can
        // toggle visibility from Settings without restarting.
        MenuBarExtra(isInserted: .constant(showMenuBar)) {
            MenuBarContent()
                .modelContainer(container)
        } label: {
            MenuBarLabel()
                .modelContainer(container)
        }
        .menuBarExtraStyle(.window)
    }
}
