import SwiftUI
import AppKit

/// A tooltip that also works inside an `NSMenu`.
///
/// `.help(_:)` alone does not fire on the menu-bar popover. `MenuStatusContent`
/// is hosted in an `NSMenuItem.view` via `NSHostingController`, and NSMenu's own
/// tracking dominates: it highlights the menu row, but the hover-help timer
/// SwiftUI's `.help` relies on never runs, because the cursor never settles
/// inside the hosted SwiftUI content the way it does in a regular window.
///
/// AppKit's own tooltips do not depend on that timer — `NSView.toolTip` installs
/// a tracking rect that `NSToolTipManager` owns. So this applies both: `.help`
/// for every context where SwiftUI's works, and a real `NSView.toolTip` behind
/// it for the menu.
///
/// **Both, from one call, on purpose.** The two were separate before — rows
/// carried `.help(...)` and the menu silently had no tooltips at all. A helper
/// that can only be used correctly is the fix for that; there is no way to
/// attach one and forget the other.
public extension View {
    /// `nil` or empty removes the tooltip, matching `.help`'s behaviour with an
    /// empty string.
    func menuTooltip(_ text: String?) -> some View {
        modifier(MenuTooltipModifier(text: text))
    }
}

private struct MenuTooltipModifier: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        content
            .help(text ?? "")
            // An overlay rather than a background: it must cover the row's
            // bounds for the tracking rect to match what the eye is pointing
            // at. It draws nothing.
            .overlay(AppKitToolTip(text: text))
    }
}

/// Zero-drawing `NSView` whose only job is to carry `toolTip` over the bounds
/// SwiftUI gives it.
///
/// SwiftUI sizes the representable, so there is no frame tracking to get wrong
/// as the popover resizes — which is the part that made
/// `NSToolTipManager.addToolTip(_:owner:userData:)` unattractive when this was
/// first looked at.
public struct AppKitToolTip: NSViewRepresentable {
    public let text: String?

    public init(text: String?) { self.text = text }

    public func makeNSView(context: Context) -> ToolTipView { Self.makeView(text: text) }

    public func updateNSView(_ view: ToolTipView, context: Context) {
        Self.apply(text: text, to: view)
    }

    /// The representable's two methods, minus the `Context` neither of them
    /// reads.
    ///
    /// Split out so the behaviour is reachable from a test.
    /// `NSViewRepresentable.Context` has no public initializer, so a test
    /// calling `makeNSView` directly would have to fabricate one — and the only
    /// ways to do that are unsound. This keeps the tests on the real code path
    /// and leaves the protocol conformance as two forwarding lines.
    public static func makeView(text: String?) -> ToolTipView {
        let view = ToolTipView()
        apply(text: text, to: view)
        return view
    }

    public static func apply(text: String?, to view: ToolTipView) {
        view.toolTip = normalized(text)
    }

    /// Empty strings become `nil`. AppKit shows an empty tooltip window for
    /// `""` where SwiftUI treats it as "no tooltip", and the two disagreeing is
    /// the kind of difference nobody would think to look for.
    public static func normalized(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    public final class ToolTipView: NSView {
        /// Transparent to drawing, opaque to hit-testing.
        ///
        /// A tooltip needs the view to be hit-testable inside its bounds — a
        /// `hitTest` returning nil means the tooltip manager never considers
        /// it. Swallowing clicks is safe here specifically: the menu's custom
        /// content item is informational, with a nil `target`/`action`, so
        /// there is nothing underneath to click. Do not reach for this helper
        /// on a row that *is* actionable without revisiting that.
        public override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(convert(point, from: superview)) ? self : nil
        }

        public override var isOpaque: Bool { false }
        public override func draw(_ dirtyRect: NSRect) {}
    }
}
