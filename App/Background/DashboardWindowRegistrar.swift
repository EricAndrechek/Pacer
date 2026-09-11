import AppKit
import SwiftUI

/// Tells `MainWindowPlacement` which `NSWindow` belongs to the dashboard
/// scene, the moment the scene's content is put into one.
///
/// Everything else in the app identifies the dashboard by guessing —
/// "can become main and isn't a panel" — and that guess is wrong for
/// Settings, the About box, and Sparkle's update alert, each of which
/// then got treated as the window whose position we restore and record.
/// The scene knows the answer for free, so ask it.
///
/// `viewDidMoveToWindow` fires while the window is being built, before it
/// is ordered on screen, which is earlier than any AppKit visibility
/// notification — so the restore can happen before the user sees the
/// window in the wrong place rather than after.
struct DashboardWindowRegistrar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { RegistrarView() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class RegistrarView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            MainActor.assumeIsolated {
                MainWindowPlacement.register(window)
            }
        }
    }
}
