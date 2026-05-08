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

    init() {
        // Force overlay-style scrollers process-wide. NSScroller reads
        // `AppleShowScrollBars` via CFPreferences, which gives the
        // app-domain value priority over NSGlobalDomain — so writing
        // it here, before any window/scene materializes, makes every
        // NSScrollView created in this process initialize with
        // `scrollerStyle = .overlay` from the start.
        //
        // Without this, the system pref ("Always" — auto-set when a
        // mouse is connected) made every fresh ScrollView reserve a
        // ~15px legacy gutter on its first layout pass and reflow
        // narrower one frame later, producing the horizontal jiggle
        // on tab switches. Doing it via .background(NSViewRepresentable)
        // was already too late: the NSScrollView had laid out once
        // before our updateNSView could land. Setting the pref pre-
        // scene runs *before* the first NSScrollView exists, so the
        // shift is impossible by construction. Process-local — does
        // not touch the user's global pref or other apps.
        UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
    }

    @AppStorage(PacerSettings.Key.menuBarStyle, store: PacerSettings.store)
    private var menuBarStyleRaw: String = PacerSettings.MenuBarStyle.iconAndPercent.rawValue

    @Environment(\.openWindow) private var openWindow

    private var showMenuBar: Bool {
        menuBarStyleRaw != PacerSettings.MenuBarStyle.hidden.rawValue
    }

    var body: some Scene {
        // `Window` (vs `WindowGroup`) is the singleton-window scene
        // type. With a WindowGroup, every `openWindow(id: "main")`
        // call from the menu bar / Cmd+, / "Settings…" was creating a
        // *new* window that AppKit then merged into the existing
        // window's tab bar — visually ugly, breaks "is the dashboard
        // visible" tracking, and confuses Dock-icon visibility logic.
        // A singleton Window means `openWindow(id:)` reuses the one
        // we already have.
        Window("Pacer", id: "main") {
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
