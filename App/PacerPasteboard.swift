import AppKit

/// Convenience for context-menu "Copy …" actions across the dashboard.
/// Writes `value` to the general pasteboard as a plain string, replacing
/// any existing contents. Lives at the App target level so PacerUI stays
/// free of AppKit (widgets import PacerUI but never need AppKit).
@MainActor
func pacerCopyToPasteboard(_ value: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(value, forType: .string)
}
