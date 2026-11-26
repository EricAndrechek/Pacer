import Foundation
import Observation

// MARK: - Why this exists (#475)
//
// A quit asked for with the displays asleep on a loaded Mac took about 124 s
// to end the process. Pacer's own shutdown took 11 s of that. Most of the rest
// was the main thread laying out the dashboard while starved of CPU (a 105 s
// stall at 233 ms of CPU), so the quit's Apple Event waited behind it.
// Once quit has begun there is nothing left to show anyone. Refreshing a view
// then only competes with the shutdown for the main thread. AppKit's own end
// of the quit, after `reply(toApplicationShouldTerminate:)`, runs on that same
// run loop.
//
// So once quit begins, view work stops at the source:
//
// - the dashboard window's refresh signals are held for good
//   (`ViewRefreshGate.beginTermination`): every dashboard view refreshes only
//   on those, so no card reloads, re-asks an engine or redraws after this;
// - the menu-bar label stops reading what it draws (`TerminationFreeze`), so
//   a last scan cycle, poll or live-meter publish during the shutdown redraws
//   nothing.
//
// Nothing is closed or hidden. The dashboard stays on screen exactly as it
// was, so the next launch restores it open (`MainWindowPlacement.wasOpen`
// is only cleared by the user closing it).

/// Whether quit has begun. One-way: a quit Pacer accepts is never cancelled
/// (`applicationShouldTerminate` always replies yes).
///
/// Observable, so a view whose `body` reads `isTerminating` is redrawn once
/// when quit begins, and can stop reading anything else from then on.
@MainActor
@Observable
public final class TerminationGate {

    public static let shared = TerminationGate(onBegin: { ViewRefreshGate.shared.beginTermination() })

    /// True from the moment quit begins until the process ends.
    public private(set) var isTerminating = false

    /// When quit began, for the log.
    @ObservationIgnored public private(set) var beganAt: Date?

    @ObservationIgnored private let onBegin: @MainActor () -> Void

    /// `onBegin` runs once, on the first `begin()`. The app's stops the
    /// dashboard's refresh signals; a test passes its own.
    public init(onBegin: @escaping @MainActor () -> Void = {}) {
        self.onBegin = onBegin
    }

    /// Quit has begun. The first call returns true; later ones change nothing.
    @discardableResult
    public func begin(now: Date = Date()) -> Bool {
        guard !isTerminating else { return false }
        isTerminating = true
        beganAt = now
        onBegin()
        return true
    }
}

/// What a view last drew, kept so that once quit begins its `body` can stop
/// reading its inputs.
///
/// A view updates on what its own `body` read (AGENTS.md, "SwiftUI state and
/// data flow"). Before quit, `resolve` runs `live`, so the reads inside it
/// are the body's and every change redraws the view, as usual. After quit it
/// returns the value from the last pass without running `live`. The body
/// then depends on `TerminationGate.isTerminating` alone, and nothing else
/// can schedule it again.
///
/// A plain reference, held in `@State`, written during `body`. That is
/// allowed here, against the usual rule, because nothing is shown from it
/// that is not already on screen. It is read only after `isTerminating`
/// turned true, and that change is what redraws the view. At that point it
/// holds exactly the value the previous pass drew.
@MainActor
public final class TerminationFreeze<Value> {
    private var last: Value?

    public init() {}

    /// `live()` until quit begins, and remembered; after, the remembered
    /// value. A view that is first drawn after quit began (nothing was
    /// remembered yet) gets `live()` once, and that one from then on.
    public func resolve(isTerminating: Bool, _ live: () -> Value) -> Value {
        if isTerminating, let last { return last }
        let value = live()
        last = value
        return value
    }
}
