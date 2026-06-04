import Foundation
import Observation
#if canImport(AppKit)
import AppKit
#endif

/// Shared "what local day is it right now?" state, expressed as the same
/// `yyyy-MM-dd` key `TokenSample.formatDate` writes into aggregate rows.
///
/// **Why this exists**: every "today" card builds its `@Query` predicate
/// from `TokenSample.formatDate(Date())` captured *once* in `init()`.
/// `@Query` reactively tracks row changes but its predicate is frozen at
/// init time, so a Dashboard window left open across midnight keeps
/// asking for *yesterday's* date string — today's rows land under a key
/// the predicate no longer matches and the card looks stale. The only
/// thing that fixed it was switching tabs, which tears down and rebuilds
/// the cards (re-running their inits against a fresh `Date()`).
///
/// Views read `PacerToday.shared.key` while computing their body and key
/// the relevant subtree on it (`.id(PacerToday.shared.key)`). Because
/// the read is tracked by `@Observable`, a day rollover re-evaluates the
/// body, the `.id` changes, and SwiftUI rebuilds exactly what a manual
/// tab switch used to — now automatically.
///
/// Rollover is driven by `NSCalendarDayChanged` (the system posts it on
/// the main thread when the local day changes). We *also* refresh on app
/// activation and system wake: if the Mac slept through midnight the
/// calendar notification can be missed, and the user's first interaction
/// after waking should already show the correct day.
///
/// MainActor-isolated `@Observable`, single shared instance — same shape
/// as `PacerWindowVisibility`; the current day is a property of the
/// process, not of any one subscriber.
@MainActor
@Observable
public final class PacerToday {

    public static let shared = PacerToday()

    /// Local-day key in `TokenSample.formatDate` form (`yyyy-MM-dd`).
    /// Matches the value aggregate rows are stored under so it can be
    /// compared directly against `DailyAggregate.date` predicates.
    public private(set) var key: String

    private init() {
        key = TokenSample.formatDate(Date())
        subscribe()
    }

    /// Recompute the day key and publish if it changed. Idempotent —
    /// re-publishing the same value is suppressed so subscribers don't
    /// rebuild on every app activation, only on an actual rollover.
    public func refresh() {
        let current = TokenSample.formatDate(Date())
        guard current != key else { return }
        key = current
    }

    private func subscribe() {
        let center = NotificationCenter.default

        // System posts this on the main thread at the local midnight
        // boundary — the primary, precise rollover signal.
        center.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }

        #if canImport(AppKit)
        // Backstops for the slept-through-midnight case, where the
        // calendar notification can be coalesced or missed:
        //   - app brought back to the foreground
        //   - machine woken from sleep
        center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        #endif
    }
}
