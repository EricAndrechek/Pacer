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

    @Environment(\.openWindow) private var openWindow

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
            // Replace the macOS-standard "Settings…" item that SwiftUI
            // would otherwise create (because there's no `Settings`
            // scene). Instead of opening a separate window, jump to
            // the Settings tab in the main window — the user wanted
            // everything in one place.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                    NotificationCenter.default.post(name: .pacerOpenSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            // ⌘1..⌘5 jump between sidebar destinations. Live in
            // `.commands` so they're part of the menu-bar responder
            // chain and reliably fire even when sidebar items don't
            // have keyboard focus. Each posts a notification that
            // ContentView observes to flip its `selection`.
            CommandGroup(after: .windowArrangement) {
                Divider()
                Button("Dashboard") {
                    NotificationCenter.default.post(
                        name: .pacerSelectDestination,
                        object: ContentView.Destination.dashboard
                    )
                }
                .keyboardShortcut("1", modifiers: .command)
                Button("History") {
                    NotificationCenter.default.post(
                        name: .pacerSelectDestination,
                        object: ContentView.Destination.history
                    )
                }
                .keyboardShortcut("2", modifiers: .command)
                Button("Projects") {
                    NotificationCenter.default.post(
                        name: .pacerSelectDestination,
                        object: ContentView.Destination.projects
                    )
                }
                .keyboardShortcut("3", modifiers: .command)
                Button("Models") {
                    NotificationCenter.default.post(
                        name: .pacerSelectDestination,
                        object: ContentView.Destination.models
                    )
                }
                .keyboardShortcut("4", modifiers: .command)
                Button("Settings") {
                    NotificationCenter.default.post(
                        name: .pacerSelectDestination,
                        object: ContentView.Destination.settings
                    )
                }
                .keyboardShortcut("5", modifiers: .command)
            }
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
