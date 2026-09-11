import AppKit
import Foundation
import PacerCore

/// Owns where the dashboard window is, and whether it should come back.
///
/// AppKit's `frameAutosaveName` is the obvious mechanism and it does not work
/// here, for two reasons that only show up together:
///
/// 1. **SwiftUI mints per-instance autosave names.** `main`,
///    `main-AppWindow-1`, `Pacer.ContentView-1-AppWindow-1` — this machine
///    accumulated five saved frames under four names across two displays, and
///    which one a relaunched window is handed is not stable.
/// 2. **Autosave writes on every move.** So even after adopting one stable
///    name, SwiftUI restoring *its* frame after our code ran counted as a
///    move, and AppKit dutifully saved that wrong frame over the good one.
///    The window drifted a little further from home on every launch, and each
///    fix that only re-read the key inherited the corruption.
///
/// So this does not share a mechanism with SwiftUI. The frame lives under a
/// Pacer-owned key that nothing else writes, and is applied *after* SwiftUI
/// has finished placing the window rather than racing it.
///
/// It also remembers whether the dashboard was open. Pacer is `LSUIElement`,
/// so nothing reopens the window on relaunch — which is fine for a login
/// launch, and wrong for the case this exists to serve: a maintainer who
/// keeps the dashboard on a second monitor and reinstalls a dozen times an
/// hour should not lose it every time.
///
/// ## Three things that made the restore unreliable
///
/// **The hold was anchored to process launch.** Re-asserting our frame for
/// three seconds after launch only covers a window that SwiftUI restores
/// immediately. The window that comes back through `reopenIfPreviouslyOpen`
/// cannot appear before launch + 1.5s and often lands after the three
/// seconds are up — so on exactly the relaunch this feature exists for
/// (install an update, app restarts), nothing re-asserted the frame and
/// SwiftUI's own placement got the last word: wrong display, default size.
/// The hold is now anchored to the window appearing.
///
/// **"Can become main and isn't a panel" is not a test for the dashboard.**
/// Settings, the About box and Sparkle's update alert all pass it. Adopting
/// one of those moved *that* window to the dashboard's parked frame, marked
/// the dashboard as "already placed" for the rest of the launch, and let its
/// frame be recorded as the dashboard's home. The scene tells us which
/// window is really hers — see `register(_:)`.
///
/// **Windows were remembered by `ObjectIdentifier`.** That is an address.
/// Close the dashboard and reopen it and the new `NSWindow` can land on the
/// freed one's address, at which point we skip placing it because we think
/// we already did. Identity is now held weakly, so a dead window cannot
/// vouch for a live one.
@MainActor
enum MainWindowPlacement {
    private static let frameKey = "PacerMainWindowFrame"
    private static let wasOpenKey = "PacerMainWindowWasOpen"

    /// Arbitrates which moves are the user parking the window. See
    /// `WindowPlacementGate` for why this is a clock and not a flag.
    private static var gate = WindowPlacementGate()

    /// The dashboard, once anything has positively identified it.
    ///
    /// Weak on purpose: when the dashboard is closed the window is
    /// deallocated, and holding it strongly (or by address) is how a dead
    /// window ends up answering for a live one.
    private static weak var dashboardWindow: NSWindow?

    /// Whether `dashboardWindow` has been put where the user left it.
    /// Reset whenever a different window becomes the dashboard.
    private static var hasPlacedDashboard = false

    /// False until the app reaches its normal launch path.
    ///
    /// The screenshot renderer, cold-start probe, archive round-trip and
    /// account-assign modes all render real scenes in a second process of
    /// the same bundle and exit before `noteLaunch()`. None of them should
    /// move a window onto the user's display or record what their throwaway
    /// window did. Gating on "did we get to the real launch" rather than
    /// enumerating the modes keeps this from rotting the next time one is
    /// added — the mode list already has to be kept in sync in two places.
    private static var isEnabled = false

    static func noteLaunch() {
        isEnabled = true
    }

    // MARK: - Which window is the dashboard

    /// The dashboard scene telling us which `NSWindow` is actually hers.
    ///
    /// Called from `DashboardWindowRegistrar`, mounted in the scene's view
    /// tree, so this is exact by construction and lands the moment the
    /// content view is put into a window — earlier than any of AppKit's
    /// visibility notifications, which is the point.
    static func register(_ window: NSWindow) {
        if dashboardWindow !== window {
            dashboardWindow = window
            hasPlacedDashboard = false
            Log.write("Placement", "dashboard is \(describe(window))")
        }
        adopt(window)
    }

    /// Is this the dashboard?
    ///
    /// Identity when we have it. Before the scene has mounted — the launch
    /// sweep runs then — fall back to the marks SwiftUI puts on its own
    /// window. Both `main…` (the scene id) and `Pacer.ContentView…` have
    /// been observed across macOS releases; Settings (`com_apple_SwiftUI_
    /// Settings_window`), About (`about`) and Sparkle (`SUUpdateAlert2`)
    /// are excluded by the same test, which is the whole reason it is a
    /// name match and not a class test.
    static func isDashboard(_ window: NSWindow) -> Bool {
        if let known = dashboardWindow { return window === known }
        guard window.canBecomeMain, !(window is NSPanel) else { return false }
        let marks = [window.identifier?.rawValue, window.frameAutosaveName]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return marks.contains {
            $0 == "main" || $0.hasPrefix("main-") || $0.hasPrefix("Pacer.ContentView")
        }
    }

    // MARK: - Stored state

    static var storedFrame: NSRect? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: frameKey) else { return nil }
            let parts = raw.split(separator: " ").compactMap { Double($0) }
            guard parts.count == 4 else { return nil }
            return NSRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        }
        set {
            guard let f = newValue else {
                UserDefaults.standard.removeObject(forKey: frameKey)
                return
            }
            UserDefaults.standard.set(
                "\(f.origin.x) \(f.origin.y) \(f.size.width) \(f.size.height)",
                forKey: frameKey
            )
        }
    }

    static var wasOpen: Bool {
        get { UserDefaults.standard.bool(forKey: wasOpenKey) }
        set { UserDefaults.standard.set(newValue, forKey: wasOpenKey) }
    }

    // MARK: - Applying

    /// A frame worth restoring: on a connected screen, and not collapsed to
    /// a sliver. Both failures end with the user staring at nothing, so
    /// neither is worth obeying.
    static func isUsable(_ frame: NSRect) -> Bool {
        guard frame.width >= 480, frame.height >= 320 else { return false }
        return NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
    }

    /// Take the dashboard off AppKit's autosave and put it where the user
    /// left it.
    ///
    /// Clearing `frameAutosaveName` is the load-bearing half: it stops
    /// AppKit writing a frame we did not choose, which is what corrupted
    /// every previous attempt.
    static func adopt(_ window: NSWindow) {
        guard isEnabled, isDashboard(window) else { return }
        if dashboardWindow !== window {
            dashboardWindow = window
            hasPlacedDashboard = false
        }
        if !window.frameAutosaveName.isEmpty {
            window.setFrameAutosaveName("")
        }
        // Position it once. Re-applying on every becomes-key would fight the
        // user the moment they moved the window, and moves a window while a
        // menu may be open — see `holdPlacement`.
        guard !hasPlacedDashboard else { return }
        hasPlacedDashboard = true
        gate.noteWindowAppeared()
        apply(to: window, reason: "adopt")
    }

    /// Apply the stored frame, if we have a usable one and the window isn't
    /// already there.
    static func apply(to window: NSWindow, reason: String) {
        guard isEnabled, isDashboard(window) else { return }
        guard let frame = storedFrame else { return }
        guard isUsable(frame) else {
            // A display that has not come back yet. Leaving the window alone
            // beats dragging it somewhere arbitrary — and critically, the
            // stored frame is left untouched so it still points home when
            // the display returns.
            Log.write("Placement", "\(reason): \(fmt(frame)) is on no connected display — leaving it")
            return
        }
        guard window.frame != frame else { return }
        let from = window.frame
        gate.noteProgrammaticMove()
        window.setFrame(frame, display: true)
        Log.write("Placement", "\(reason): \(fmt(from)) → \(fmt(frame))")
    }

    /// Record a move the user actually made.
    static func record(_ window: NSWindow) {
        guard isEnabled, isDashboard(window), window.isVisible else { return }
        let userDriven = isUserDrivenMove()
        guard gate.shouldRecordMove(userDriven: userDriven) else { return }
        guard isUsable(window.frame) else { return }
        if userDriven { gate.noteUserParked() }
        guard window.frame != storedFrame else {
            wasOpen = true
            return
        }
        storedFrame = window.frame
        wasOpen = true
        Log.write("Placement", "parked at \(fmt(window.frame))")
    }

    /// Is the user's hand on this move?
    ///
    /// A window being dragged sits in a continuous run of mouse-drag events,
    /// so the event AppKit is currently dispatching still says so one
    /// main-actor hop later, when the move is judged. This is a positive
    /// signal only — "no mouse event" means keyboard, zoom, Stage Manager or
    /// a restore, all of which the clock already handles correctly.
    private static func isUserDrivenMove() -> Bool {
        switch NSApp.currentEvent?.type {
        case .leftMouseDragged, .leftMouseUp, .leftMouseDown: return true
        default: return false
        }
    }

    /// Re-assert placement while a newly appeared window is still being
    /// placed, so SwiftUI's own restore cannot get the last word.
    ///
    /// **Only while it is being placed** — the grace is anchored to the
    /// window appearing and lasts a couple of seconds. This is called from
    /// `didBecomeKey`, which fires every time the user clicks into the
    /// window, so without the bound every click scheduled five `setFrame`
    /// calls over the next two seconds. Open a dropdown and one of them
    /// lands *while the menu is up*, moving the window out from under an
    /// anchor the menu had already resolved; the menu then draws against
    /// stale geometry, which is how every popup in the app ended up in a
    /// screen corner. It was intermittent because whether a `setFrame` fell
    /// inside the menu's lifetime depended on how fast you clicked, and it
    /// sometimes self-corrected because a later one triggered a reposition.
    ///
    /// Re-asserting a frame is only needed to win a race against SwiftUI's
    /// restore. After that the window belongs to the user.
    static func holdPlacement(for window: NSWindow) {
        guard isEnabled, isDashboard(window), gate.isPlacingNewWindow() else { return }
        for delay in [0.0, 0.15, 0.4, 1.0, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    guard gate.isPlacingNewWindow() else { return }
                    apply(to: window, reason: "hold")
                }
            }
        }
    }

    /// The set of displays changed — one woke, slept, was plugged in, or the
    /// arrangement moved.
    ///
    /// Two jobs. Stop recording for a few seconds, because AppKit is about
    /// to shove every window onto whatever screens currently exist and none
    /// of that is the user's intent. Then put the dashboard back, because
    /// the display it lives on may be the one that just returned.
    static func noteDisplayConfigurationChanged() {
        guard isEnabled else { return }
        gate.noteDisplayConfigurationChanged()
        Log.write("Placement", "displays changed: \(NSScreen.screens.count) connected")
        for delay in [0.5, 2.0, 4.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    guard let window = dashboardWindow, window.isVisible else { return }
                    apply(to: window, reason: "displays changed")
                }
            }
        }
    }

    /// Put the window back on a connected display, if it is on none.
    ///
    /// Prefers home over centering: the stored frame is usable again the
    /// moment its display comes back, and centering on the built-in screen
    /// is a consolation prize. Either way the move is ours, not the user's,
    /// so the stored frame survives it.
    static func rescueIfOffscreen(_ window: NSWindow) {
        guard isEnabled, isDashboard(window) else { return }
        guard !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) })
        else { return }
        if let frame = storedFrame, isUsable(frame) {
            apply(to: window, reason: "offscreen rescue")
            return
        }
        gate.noteProgrammaticMove()
        window.center()
        Log.write("Placement", "offscreen rescue: centered at \(fmt(window.frame))")
    }

    /// Bring the dashboard back if it was open when we were last quit,
    /// without stealing focus.
    ///
    /// `LSUIElement` + a SwiftUI `Window` scene gives no AppDelegate-reachable
    /// API to materialize the window (`openWindow(id:)` is view-only), so this
    /// uses the same trick the menu-bar path does — reopening our own bundle
    /// triggers `applicationShouldHandleReopen` — but with `activates = false`
    /// so it does not pull the user out of whatever they are in.
    static func reopenIfPreviouslyOpen() {
        guard wasOpen else { return }
        // Deferred: asking AppKit to reopen us *during* our own launch is a
        // no-op — the reopen path only fires for an app it considers already
        // running. Waiting for launch to finish is what makes it take.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                guard !NSApp.windows.contains(where: { isDashboard($0) && $0.isVisible })
                else { return }
                Log.write("Placement", "reopening the dashboard it was quit with")
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                configuration.createsNewApplicationInstance = false
                NSWorkspace.shared.openApplication(
                    at: Bundle.main.bundleURL, configuration: configuration
                ) { _, error in
                    if let error {
                        Log.write("MainWindowPlacement", "reopen failed: \(error)")
                    }
                }
            }
        }
    }

    // MARK: - Logging

    private static func fmt(_ r: NSRect) -> String {
        "\(Int(r.origin.x)),\(Int(r.origin.y)) \(Int(r.size.width))×\(Int(r.size.height))"
    }

    private static func describe(_ window: NSWindow) -> String {
        let id = window.identifier?.rawValue ?? "-"
        let autosave = window.frameAutosaveName.isEmpty ? "-" : window.frameAutosaveName
        return "id=\(id) autosave=\(autosave) frame=\(fmt(window.frame))"
    }
}
