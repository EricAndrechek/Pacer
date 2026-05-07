import AppKit
import SwiftUI
import SwiftData
import PacerCore

/// `NSApplicationDelegate` that owns the SwiftData container, the
/// in-process background service (`AppBackgroundService`), and drives
/// Dock-icon visibility based on whether any window is open.
///
/// Why the delegate owns the container instead of `PacerApp.init`:
/// SwiftUI's `@NSApplicationDelegateAdaptor` constructs the delegate
/// during the App's body evaluation, but the exact ordering relative
/// to `App.init` is non-deterministic. Putting both container creation
/// and background-service start under one owner removes the timing
/// concern.
///
/// Lifecycle:
/// - `init()` — open the SwiftData container, register defaults,
///   construct the background service. No I/O or scan starts here;
///   that waits for `applicationDidFinishLaunching`.
/// - `applicationDidFinishLaunching` — start the background service.
///   The service starts whether the user opened the app interactively
///   or it was auto-launched at login (so the LSUIElement-hidden
///   "agent" mode still does data collection).
/// - `applicationShouldTerminate` — block briefly while the service
///   shuts down cleanly, then post a UNUserNotification telling the
///   user collection has stopped.
/// - Window-visibility observers — when a main window becomes visible,
///   switch activation policy to `.regular` so a Dock icon appears.
///   When the last main window closes, switch back to `.accessory` so
///   the app continues to run headless without cluttering the Dock.
///
/// `LSUIElement=true` in `Info.plist` makes the *initial* launch
/// `.accessory`, so a login-at-startup launch shows nothing in the
/// Dock until the user explicitly opens a window.
@MainActor
final class PacerAppDelegate: NSObject, NSApplicationDelegate {

    let container: ModelContainer
    let backgroundService: AppBackgroundService

    private var windowObservers: [NSObjectProtocol] = []

    override init() {
        // Redirect stderr to a log file before anything else so the
        // ScanCoordinator/OAuthPoller log lines (via PacerCore.Log)
        // land somewhere readable. The retired daemon got its
        // stderr→file redirect from launchd's StandardErrorPath plist
        // key; the in-process app has to do the equivalent itself
        // because SMAppService.mainApp launches don't have a way to
        // configure stderr redirection. `make logs` and `make
        // logs-tail` read this same file.
        Self.redirectStderrToLogFile()

        // Register defaults before any @AppStorage reads can happen,
        // same reason PacerApp.init used to: `@AppStorage`'s default-
        // value parameter only kicks in when the key is totally
        // absent from the suite, so a first-run user would otherwise
        // see different defaults from a returning user.
        PacerSettings.registerDefaults()
        do {
            container = try PacerStore.makeModelContainer()
        } catch {
            fatalError("Failed to open shared SwiftData container: \(error)")
        }
        backgroundService = AppBackgroundService(container: container)
        super.init()
    }

    /// Append future stderr writes (including PacerCore.Log output) to
    /// `~/Library/Logs/Pacer/Pacer.err.log`. Best-effort: if directory
    /// creation or freopen fails, stderr stays where it was (typically
    /// /dev/null when launched by Finder/launchd, or the controlling
    /// terminal when launched from `open -a` in a shell). We don't
    /// surface failures because logging is supportive infrastructure
    /// — the app shouldn't fail to launch because of a log redirect
    /// problem.
    private static func redirectStderrToLogFile() {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Pacer", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: logsDir,
            withIntermediateDirectories: true
        )
        let logURL = logsDir.appendingPathComponent("Pacer.err.log")
        // freopen("...", "a", stderr) replaces the underlying fd of
        // stderr without changing FILE* identity, so existing code
        // writing via `FileHandle.standardError` (PacerCore.Log) and
        // anything that writes to `stderr` directly (system frameworks)
        // both end up in the file.
        _ = logURL.path.withCString { freopen($0, "a", stderr) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        backgroundService.start()
        installWindowObservers()
        // Reflect whatever state SwiftUI has put us in by the time
        // we get here — typically zero windows on a login launch,
        // one window on an interactive launch.
        applyActivationPolicyForCurrentWindows()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Run shutdown asynchronously and tell AppKit to wait. Without
        // this the watcher and OAuth poller would be SIGKILLed in
        // place; the cooperative shutdown lets pending SwiftData
        // saves flush. Also fires the "you stopped tracking" banner
        // before exit so a user who quits unintentionally has a
        // visible reminder.
        Task { @MainActor in
            await backgroundService.stop()
            await NotificationCoordinator.shared.notifyCollectionPaused()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// macOS sends this when the user clicks the Dock icon (only
    /// possible if we're in `.regular`) on a running app with no
    /// visible window. Returning true asks AppKit to handle it via
    /// the standard "reopen the app's main window" path; combined
    /// with a SwiftUI `WindowGroup`, the main window reappears.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows: Bool
    ) -> Bool {
        true
    }

    /// Don't terminate when the last window closes — the whole point
    /// of the agent shape is that we keep collecting data after the
    /// user dismisses the dashboard. Quit happens via Cmd+Q or the
    /// menu-bar Quit button.
    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    // MARK: - Activation policy management

    private func installWindowObservers() {
        let center = NotificationCenter.default
        let didBecomeKey = center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applyActivationPolicyForCurrentWindows()
            }
        }
        let willClose = center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // willClose fires before the window leaves NSApp.windows,
            // so dispatching on the main queue lets the count reflect
            // post-close state.
            Task { @MainActor in
                self?.applyActivationPolicyForCurrentWindows()
            }
        }
        windowObservers = [didBecomeKey, willClose]
    }

    /// `.regular` when at least one user-visible window is open
    /// (Dock icon shows so user can Cmd+Q, Cmd+Tab back, etc.);
    /// `.accessory` otherwise (Dock icon hides, app keeps running
    /// in the background). Filters out NSPanel and the menu-bar
    /// extra's hosting window so they don't keep the Dock icon
    /// alive.
    func applyActivationPolicyForCurrentWindows() {
        let visibleMainWindows = NSApp.windows.filter { window in
            guard window.isVisible else { return false }
            // Exclude utility/system windows. NSPanel covers most
            // (Settings is hosted in one). The menu-bar extra's
            // window is also non-main and shouldn't keep the Dock
            // icon alive.
            if window is NSPanel { return false }
            if !window.canBecomeMain { return false }
            return true
        }
        let target: NSApplication.ActivationPolicy =
            visibleMainWindows.isEmpty ? .accessory : .regular
        if NSApp.activationPolicy() != target {
            NSApp.setActivationPolicy(target)
        }
    }
}
