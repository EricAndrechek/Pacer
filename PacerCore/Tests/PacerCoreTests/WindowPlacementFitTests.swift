import CoreGraphics
import Foundation
import Testing
@testable import PacerCore

@Suite("Window placement fit")
struct WindowPlacementFitTests {

    // A real three-display arrangement, as `NSScreen.visibleFrame` reports it.
    private let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 944)
    private let portrait = CGRect(x: 2500, y: 551, width: 1080, height: 1920)
    private let ultrawide = CGRect(x: -1596, y: 982, width: 4096, height: 1152)

    private var allScreens: [CGRect] { [builtIn, portrait, ultrawide] }

    @Test("a frame sitting squarely on a screen is restorable")
    func squarelyOnScreen() {
        let parked = CGRect(x: 2500, y: 551, width: 1080, height: 947)
        #expect(WindowPlacementFit.isRestorable(parked, onAnyOf: allScreens))
    }

    @Test("a frame on no screen at all is not restorable")
    func onNoScreen() {
        let parked = CGRect(x: 9000, y: 9000, width: 1080, height: 947)
        #expect(!WindowPlacementFit.isRestorable(parked, onAnyOf: allScreens))
    }

    /// The failure this type was written for. A window parked near the right
    /// edge of the ultrawide overlaps the portrait display next to it. Unplug
    /// the ultrawide and the old "does it touch anything?" test still said
    /// yes — restoring the window into the gap where the monitor used to be,
    /// with a strip showing on the neighbour.
    @Test("a frame is not restorable just because it clips the neighbouring display")
    func doesNotSurviveOnASliverOfTheNeighbour() {
        let parked = CGRect(x: 1800, y: 1100, width: 1080, height: 947)
        // With the ultrawide present it is a normal, mostly-on-screen window.
        #expect(WindowPlacementFit.isRestorable(parked, onAnyOf: allScreens))
        // Unplug it and only ~380pt of width lands on the portrait display.
        #expect(!WindowPlacementFit.isRestorable(parked, onAnyOf: [builtIn, portrait]))
    }

    @Test("a sliver on screen is not enough")
    func sliverIsNotEnough() {
        // 20pt of a 1080-wide window overlapping the portrait display.
        let parked = CGRect(x: 1440, y: 600, width: 1080, height: 947)
        #expect(!WindowPlacementFit.isRestorable(parked, onAnyOf: [portrait]))
    }

    @Test("half on screen is restorable")
    func halfIsEnough() {
        // Exactly half the width on the portrait display.
        let parked = CGRect(x: 1960, y: 600, width: 1080, height: 947)
        #expect(WindowPlacementFit.isRestorable(parked, onAnyOf: [portrait]))
    }

    /// A window sized for the ultrawide cannot cover half of itself on a
    /// smaller display, but it covers that display completely — which is a
    /// perfectly usable place to be, not a restore into nowhere.
    @Test("a window larger than the screen is judged by how much of the screen it covers")
    func oversizedWindowIsJudgedByScreenCoverage() {
        // 3600×1100 covers the whole of the 1512×944 built-in, but that is
        // only ~36% of the window itself.
        let wide = CGRect(x: 0, y: 0, width: 3600, height: 1100)
        #expect(WindowPlacementFit.isRestorable(wide, onAnyOf: [builtIn]))
    }

    @Test("a collapsed frame is never restorable")
    func collapsedFrame() {
        #expect(!WindowPlacementFit.isRestorable(
            CGRect(x: 2500, y: 551, width: 300, height: 947), onAnyOf: allScreens))
        #expect(!WindowPlacementFit.isRestorable(
            CGRect(x: 2500, y: 551, width: 1080, height: 100), onAnyOf: allScreens))
        #expect(!WindowPlacementFit.isRestorable(.zero, onAnyOf: allScreens))
    }

    @Test("no connected screens means nothing is restorable")
    func noScreens() {
        #expect(!WindowPlacementFit.isRestorable(
            CGRect(x: 2500, y: 551, width: 1080, height: 947), onAnyOf: []))
    }

    /// Touching along an edge is not being on a screen. This is the case that
    /// already worked by luck: a frame starting exactly at the portrait
    /// display's left edge shares a boundary with the ultrawide and must not
    /// count as overlapping it.
    @Test("sharing an edge is not overlapping")
    func edgeContactIsNotOverlap() {
        let parked = CGRect(x: 2500, y: 551, width: 1080, height: 947)
        #expect(!WindowPlacementFit.isRestorable(parked, onAnyOf: [ultrawide]))
    }
}
