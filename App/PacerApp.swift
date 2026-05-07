import SwiftUI
import SwiftData
import PacerCore

@main
struct PacerApp: App {
    /// SwiftUI lifecycle adaptor. The delegate owns the SwiftData
    /// container, the in-process background service (FSEvents scan
    /// + OAuth poller), and the Dock-visibility logic. Scenes here
    /// just project the container into their own environments.
    @NSApplicationDelegateAdaptor(PacerAppDelegate.self) private var appDelegate

    @AppStorage(PacerSettings.Key.menuBarStyle, store: PacerSettings.store)
    private var menuBarStyleRaw: String = PacerSettings.MenuBarStyle.iconAndPercent.rawValue

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
        .modelContainer(appDelegate.container)
        .commands {
            CommandGroup(after: .importExport) {
                Divider()
                Button("Export Daily Totals…") {
                    let context = ModelContext(appDelegate.container)
                    CSVExporter.dailyTotals(context: context)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Export Daily by Model…") {
                    let context = ModelContext(appDelegate.container)
                    CSVExporter.dailyByModel(context: context)
                }
                Button("Export Project Totals…") {
                    let context = ModelContext(appDelegate.container)
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
                .modelContainer(appDelegate.container)
        } label: {
            MenuBarLabel()
                .modelContainer(appDelegate.container)
        }
        .menuBarExtraStyle(.window)
    }
}
