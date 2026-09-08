import AppKit
import SwiftUI
import Testing
@testable import PacerUI

/// The half of the menu-bar tooltip that can be checked without a screen.
///
/// `NSMenu` runs its own tracking loop, so whether macOS *draws* the tooltip
/// cannot be exercised off-screen at all — that is what
/// `MenuBarTooltipSelfTest` and one human hover are for. What is testable here
/// is our side of the contract: that the AppKit view carries the right
/// `toolTip`, that an empty string means "no tooltip" rather than an empty
/// yellow box, and that the view stays hit-testable, since a `hitTest`
/// returning nil is the quiet way to get no tooltip at all.
@Suite("Menu tooltips — the part that does not need a screen")
@MainActor
struct MenuTooltipTests {

    @Test("the AppKit view carries the tooltip text")
    func carriesText() {
        let view = AppKitToolTip.makeView(text: "$1,234.56")
        #expect(view.toolTip == "$1,234.56")
    }

    /// SwiftUI's `.help("")` means "no tooltip"; AppKit's `toolTip = ""` shows
    /// an empty window. The two disagreeing is the kind of difference nobody
    /// would think to look for, so empty and whitespace normalize to nil.
    @Test("empty and whitespace mean no tooltip")
    func emptyMeansNone() {
        #expect(AppKitToolTip.normalized(nil) == nil)
        #expect(AppKitToolTip.normalized("") == nil)
        #expect(AppKitToolTip.normalized("   \n ") == nil)
        #expect(AppKitToolTip.normalized(" kept ") == " kept ")

        let view = AppKitToolTip.makeView(text: "")
        #expect(view.toolTip == nil)
    }

    @Test("updating replaces the text, and clearing removes it")
    func updates() {
        let view = AppKitToolTip.makeView(text: "before")
        AppKitToolTip.apply(text: "after", to: view)
        #expect(view.toolTip == "after")
        AppKitToolTip.apply(text: nil, to: view)
        #expect(view.toolTip == nil)
    }

    /// A tooltip needs the view to answer `hitTest` inside its own bounds. The
    /// view draws nothing, so it would be easy to make it transparent to hits
    /// too — and then the tooltip silently never appears.
    @Test("the view is hit-testable inside its bounds and not outside")
    func hitTesting() {
        let view = AppKitToolTip.makeView(text: "x")
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        view.frame = NSRect(x: 20, y: 10, width: 60, height: 30)
        parent.addSubview(view)

        #expect(view.hitTest(NSPoint(x: 50, y: 25)) === view)   // inside
        #expect(view.hitTest(NSPoint(x: 5, y: 5)) == nil)       // outside
        #expect(view.hitTest(NSPoint(x: 150, y: 90)) == nil)    // outside
    }
}
