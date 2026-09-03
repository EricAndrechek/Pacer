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
@MainActor
enum MainWindowPlacement {
    private static let frameKey = "PacerMainWindowFrame"
    private static let wasOpenKey = "PacerMainWindowWasOpen"

    /// How long after launch to ignore window moves.
    ///
    /// SwiftUI places the restored window during this period, and those moves
    /// are not the user's intent — recording them is exactly how the stored
    /// frame got corrupted before. Anything later is a real move.
    private static let settleWindow: TimeInterval = 3.0

    private static var launchedAt = Date()
    private static var isApplying = false

    static func noteLaunch() { launchedAt = Date() }

    private static var isSettling: Bool {
        Date().timeIntervalSince(launchedAt) < settleWindow
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

    /// Take a window off AppKit's autosave and put it where the user left it.
    ///
    /// Clearing `frameAutosaveName` is the load-bearing half: it stops
    /// AppKit writing a frame we did not choose, which is what corrupted
    /// every previous attempt.
    static func adopt(_ window: NSWindow) {
        guard window.canBecomeMain, !(window is NSPanel) else { return }
        if !window.frameAutosaveName.isEmpty {
            window.setFrameAutosaveName("")
        }
        apply(to: window)
    }

    /// Apply the stored frame, if we have a usable one and the window isn't
    /// already there.
    static func apply(to window: NSWindow) {
        guard let frame = storedFrame, isUsable(frame) else { return }
        guard window.frame != frame else { return }
        isApplying = true
        window.setFrame(frame, display: true)
        isApplying = false
    }

    /// Record a move the user actually made.
    static func record(_ window: NSWindow) {
        guard window.canBecomeMain, !(window is NSPanel) else { return }
        guard !isApplying, !isSettling else { return }
        guard isUsable(window.frame) else { return }
        storedFrame = window.frame
        wasOpen = true
    }

    /// Re-assert placement across the settle window, so SwiftUI's own restore
    /// cannot get the last word. Cheap: a handful of no-op comparisons.
    static func holdPlacement(for window: NSWindow) {
        for delay in [0.0, 0.15, 0.4, 1.0, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated { apply(to: window) }
            }
        }
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
                guard !NSApp.windows.contains(where: {
                    $0.canBecomeMain && !($0 is NSPanel) && $0.isVisible
                }) else { return }
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
}
