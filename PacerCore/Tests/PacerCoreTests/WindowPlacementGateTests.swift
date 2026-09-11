import Foundation
import Testing
@testable import PacerCore

@Suite("Window placement gate")
struct WindowPlacementGateTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("a quiet move is the user parking the window")
    func quietMoveIsRecorded() {
        let gate = WindowPlacementGate()
        #expect(gate.shouldRecordMove(at: t0))
    }

    /// The bug this type exists for. The move notification is observed on
    /// the main queue but recorded one main-actor hop later, so a boolean
    /// cleared right after `setFrame` is already false by then — and the
    /// frame we just set gets stored as the user's choice.
    @Test("a frame we set ourselves is not recorded, even a hop later")
    func programmaticMoveSurvivesTheAsyncHop() {
        var gate = WindowPlacementGate()
        gate.noteProgrammaticMove(at: t0)
        #expect(!gate.shouldRecordMove(at: t0.addingTimeInterval(0.001)))
        #expect(!gate.shouldRecordMove(at: t0.addingTimeInterval(0.25)))
        #expect(gate.shouldRecordMove(at: t0.addingTimeInterval(1.5)))
    }

    @Test("SwiftUI finishing its own restore is not recorded")
    func appearanceGraceSuppressesRestoreMoves() {
        var gate = WindowPlacementGate()
        gate.noteWindowAppeared(at: t0)
        #expect(!gate.shouldRecordMove(at: t0.addingTimeInterval(1.0)))
        #expect(gate.shouldRecordMove(at: t0.addingTimeInterval(3.0)))
    }

    /// A dock unplug, or a monitor waking up after the Mac did, moves every
    /// window on screen. None of it is a decision the user made.
    @Test("a display reshuffle is not recorded")
    func displayChangeSuppressesMoves() {
        var gate = WindowPlacementGate()
        gate.noteDisplayConfigurationChanged(at: t0)
        #expect(!gate.shouldRecordMove(at: t0.addingTimeInterval(4.0)))
        #expect(gate.shouldRecordMove(at: t0.addingTimeInterval(6.0)))
    }

    @Test("a shorter grace never cuts a longer one short")
    func gracesExtendRatherThanReplace() {
        var gate = WindowPlacementGate()
        gate.noteDisplayConfigurationChanged(at: t0)
        gate.noteProgrammaticMove(at: t0.addingTimeInterval(0.5))
        // The 1s programmatic grace ends well before the 5s display one.
        #expect(!gate.shouldRecordMove(at: t0.addingTimeInterval(3.0)))
    }

    @Test("a new window restarts the appearance grace rather than extending it")
    func appearanceGraceIsAnchoredToTheWindow() {
        var gate = WindowPlacementGate()
        gate.noteWindowAppeared(at: t0)
        gate.noteWindowAppeared(at: t0.addingTimeInterval(10))
        #expect(gate.isPlacingNewWindow(at: t0.addingTimeInterval(11)))
        #expect(!gate.shouldRecordMove(at: t0.addingTimeInterval(11)))
        #expect(gate.shouldRecordMove(at: t0.addingTimeInterval(13)))
    }

    /// Someone whose window came back in the wrong place drags it home in
    /// the first second. That has to stick, or we snap it back under their
    /// hand and forget where they wanted it.
    @Test("a drag outranks the appearance grace")
    func userDragBeatsAppearanceGrace() {
        var gate = WindowPlacementGate()
        gate.noteWindowAppeared(at: t0)
        #expect(!gate.shouldRecordMove(at: t0.addingTimeInterval(0.5)))
        #expect(gate.shouldRecordMove(userDriven: true, at: t0.addingTimeInterval(0.5)))
    }

    @Test("a drag does not outrank a frame we are setting ourselves")
    func userDragDoesNotBeatProgrammaticGrace() {
        var gate = WindowPlacementGate()
        gate.noteProgrammaticMove(at: t0)
        // The user may be dragging something else while we restore.
        #expect(!gate.shouldRecordMove(userDriven: true, at: t0.addingTimeInterval(0.2)))
    }

    @Test("parking ends the restore graces so the next move is honored")
    func parkingClearsGraces() {
        var gate = WindowPlacementGate()
        gate.noteWindowAppeared(at: t0)
        gate.noteDisplayConfigurationChanged(at: t0)
        gate.noteUserParked()
        #expect(gate.shouldRecordMove(at: t0.addingTimeInterval(0.1)))
        #expect(!gate.isPlacingNewWindow(at: t0.addingTimeInterval(0.1)))
    }

    /// Re-asserting our frame is only for the moment a window is being
    /// placed. Doing it on every click is what put the app's popup menus in
    /// a screen corner — a `setFrame` landing mid-menu moves the window out
    /// from under an anchor the menu had already resolved.
    @Test("we stop re-asserting placement once the window has settled")
    func placementHoldIsBounded() {
        var gate = WindowPlacementGate()
        gate.noteWindowAppeared(at: t0)
        #expect(gate.isPlacingNewWindow(at: t0.addingTimeInterval(2.0)))
        #expect(!gate.isPlacingNewWindow(at: t0.addingTimeInterval(2.6)))
    }
}
