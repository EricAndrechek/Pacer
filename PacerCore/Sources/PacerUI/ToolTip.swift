import SwiftUI
import AppKit

/// An AppKit-backed tooltip, for surfaces where SwiftUI's `.help()` does not
/// produce one.
///
/// `.help()` is the right way to say this and it works throughout the app's
/// own windows. It stops working in SwiftUI content **hosted inside a
/// menu-bar surface** — an `NSHostingView` in `NSStatusItem.button`, or an
/// `NSHostingController` in an `NSMenuItem.view` — from macOS 26 on. Confirmed
/// by `make verify-tooltip`, which glides onto a menu row and photographs what
/// appears: it lands on the row and no tooltip window is ever created.
///
/// `NSView.toolTip` is the pre-SwiftUI mechanism and still works, on every OS
/// Pacer supports, so these surfaces use it directly.
///
/// The backing view is deliberately **invisible to hit-testing**: it sits over
/// the content, and a menu row that stopped responding to clicks would be a
/// far worse bug than a missing tooltip. `NSWindow` resolves tooltip rects
/// separately from the responder chain, which is what lets a view opt out of
/// one and keep the other.
public extension View {
    /// Show `text` on hover. Empty strings install no tooltip.
    func pacerToolTip(_ text: String) -> some View {
        overlay(ToolTipHost(text: text))
    }
}

private struct ToolTipHost: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> PassthroughToolTipView {
        let view = PassthroughToolTipView()
        view.toolTip = text.isEmpty ? nil : text
        return view
    }

    func updateNSView(_ view: PassthroughToolTipView, context: Context) {
        let next = text.isEmpty ? nil : text
        // AppKit re-registers the tooltip rect on assignment, so only write on
        // a real change — the menu-bar label re-renders on every store save.
        if view.toolTip != next { view.toolTip = next }
    }
}

/// Carries a `toolTip` and nothing else. `hitTest` returns nil so clicks,
/// scrolls and cursor changes pass straight through to whatever is underneath.
final class PassthroughToolTipView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
}
