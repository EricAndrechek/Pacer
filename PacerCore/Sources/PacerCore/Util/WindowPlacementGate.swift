import Foundation

/// Decides whether a window move is the user parking the window, or
/// something else moving it.
///
/// Pacer remembers where the dashboard was left by watching
/// `NSWindow.didMove` / `didResize`. The trouble is that most moves a
/// window makes are not the user's:
///
/// - we move it ourselves, restoring it to its stored frame at launch;
/// - the menu-bar open path relocates it to the display the cursor is on;
/// - AppKit shuffles every window on screen when a display sleeps, wakes,
///   or is unplugged — a Mac on a dock does that several times a day.
///
/// Recording one of those overwrites the parked frame with a frame nobody
/// chose. And because the stored frame is what every later launch
/// restores, a wrong answer written once is permanent: the window comes
/// back in the wrong place forever, and each launch re-records it.
///
/// **Why a clock rather than a flag.** The obvious guard is a boolean set
/// around our own `setFrame` call. That is what shipped, and it never once
/// fired: the move notification is observed on the main queue, but the
/// observer defers the actual recording by one main-actor hop, so a flag
/// set and cleared on consecutive lines is always back to `false` by the
/// time the move is judged. A deadline survives the hop; a flag cannot.
///
/// Extracted from the AppKit layer because this rule is the whole bug, and
/// a rule that cannot be tested is a rule that regresses.
public struct WindowPlacementGate: Sendable {

    /// How long to disown moves after we set a frame ourselves. Covers the
    /// notification hop plus AppKit's own follow-up constrain pass.
    public static let programmaticGrace: TimeInterval = 1.0

    /// How long a freshly appeared window keeps being placed by SwiftUI.
    /// Anything inside this window is the restore finishing, not a user.
    public static let appearanceGrace: TimeInterval = 2.5

    /// How long AppKit keeps rearranging windows after the set of displays
    /// changes. Deliberately the longest of the three: a monitor waking up
    /// behind a Mac that woke first can move windows twice, seconds apart.
    public static let displayChangeGrace: TimeInterval = 5.0

    /// How long a move that is not the user's hand waits before it may be
    /// stored — long enough for a display change that *caused* it to be
    /// reported.
    ///
    /// The display-change grace only looks forward, and AppKit does not
    /// promise to announce the change first. When monitors sleep it moves the
    /// window, then posts the change in the same second: on 2026-09-22 the
    /// dashboard was stored at `1932,-98` — a spot that only existed in the
    /// half-rearranged layout — and every launch after restored it to nowhere.
    public static let settleDelay: TimeInterval = 2.0

    private var lastDisplayChangeAt: Date = .distantPast
    private var programmaticEndsAt: Date = .distantPast
    private var appearanceEndsAt: Date = .distantPast
    private var displayChangeEndsAt: Date = .distantPast

    public init() {}

    private var ignoreMovesUntil: Date {
        max(programmaticEndsAt, max(appearanceEndsAt, displayChangeEndsAt))
    }

    /// We are about to set the frame ourselves.
    public mutating func noteProgrammaticMove(at now: Date = Date()) {
        programmaticEndsAt = max(programmaticEndsAt, now + Self.programmaticGrace)
    }

    /// A window just materialized and is still being placed.
    ///
    /// Assigned rather than `max`'d: a *new* window restarts the grace, and
    /// it is anchored here — at the moment the window appears — rather than
    /// at process launch. Anchoring it to launch is what made the restore
    /// unreliable, because the window that comes back through the reopen
    /// path appears a second and a half after launch at the earliest and
    /// can miss a launch-anchored window entirely.
    public mutating func noteWindowAppeared(at now: Date = Date()) {
        appearanceEndsAt = now + Self.appearanceGrace
    }

    /// A display was connected, disconnected, woken, or rearranged.
    public mutating func noteDisplayConfigurationChanged(at now: Date = Date()) {
        displayChangeEndsAt = max(displayChangeEndsAt, now + Self.displayChangeGrace)
        lastDisplayChangeAt = max(lastDisplayChangeAt, now)
    }

    /// The user parked the window; stop second-guessing moves.
    ///
    /// Leaves the programmatic deadline alone — that one is about frames
    /// *we* are mid-way through setting, and a user gesture does not make
    /// those ours to record.
    public mutating func noteUserParked() {
        appearanceEndsAt = .distantPast
        displayChangeEndsAt = .distantPast
    }

    /// Should an observed move be stored as where the user keeps the window?
    ///
    /// - Parameter userDriven: the move arrived while the user was working
    ///   the mouse, so it is a drag rather than a restore. It outranks the
    ///   appearance and display-change graces — someone dragging a window
    ///   that just came back in the wrong place means it *now*, and making
    ///   them wait out a grace period would snap it back under their cursor.
    ///   It never outranks the programmatic grace: the user may well be
    ///   dragging something else entirely while we set a frame.
    public func shouldRecordMove(userDriven: Bool = false, at now: Date = Date()) -> Bool {
        if now >= ignoreMovesUntil { return true }
        return userDriven && now >= programmaticEndsAt
    }

    /// May a move observed at `observedAt`, not driven by the user, be stored
    /// now that it has waited out `settleDelay`?
    ///
    /// No if the displays changed at any point since just before it — that
    /// change is the likelier author of the move than the user is.
    public func shouldCommitSettledMove(observedAt: Date, at now: Date = Date()) -> Bool {
        guard now >= observedAt + Self.settleDelay else { return false }
        // A little slack before the move: the change and the move it causes
        // are posted in the same instant, in either order.
        guard lastDisplayChangeAt < observedAt - 0.5 else { return false }
        return shouldRecordMove(at: now)
    }

    /// True while a newly appeared window may still be moved by SwiftUI's
    /// own restore — the period in which we keep re-asserting our frame so
    /// that ours, not SwiftUI's, gets the last word.
    public func isPlacingNewWindow(at now: Date = Date()) -> Bool {
        now < appearanceEndsAt
    }
}
