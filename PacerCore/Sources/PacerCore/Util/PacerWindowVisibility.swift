import Foundation
import Observation

/// Shared "is the main window currently visible?" state. App layer
/// writes (`PacerAppDelegate.applyActivationPolicyForCurrentWindows`),
/// background and UI both read.
///
/// **Why**: Pacer runs constantly as a menu-bar/accessory agent. When
/// no window is up, none of the dashboard's `@Query`-fed views are
/// consuming scan data — but the scanner still fires at 500ms FSEvent
/// latency + 60s backstop as if a user were watching, and decorative
/// animations like `FreshnessPulse` keep waking the CPU.
///
/// Subscribers gate cadence + animation off this flag:
///   - `ScanCoordinator` widens the FSEvent latency window and the
///     backstop interval when hidden, so live-write reactivity stops
///     burning cycles nobody can see.
///   - `FreshnessPulse` adds `!isMainWindowVisible` to its
///     `paused:` condition so the 12fps TimelineView goes idle.
///
/// MainActor-isolated so `@Observable` reads from SwiftUI views are
/// just normal property accesses — no actor hop required. Single
/// shared instance because the visibility answer is a property of the
/// app process, not of any particular subscriber.
@MainActor
@Observable
public final class PacerWindowVisibility {

    public static let shared = PacerWindowVisibility()

    /// True iff at least one user-facing main window is currently on
    /// screen. Excludes panels, the menu-bar status item's hosting
    /// window, and anything that can't become main — same filter the
    /// App layer already uses to decide activation policy.
    public private(set) var isMainWindowVisible: Bool = false

    private init() {}

    /// Called by the App layer's window observers when the count of
    /// visible main windows transitions to / from zero. Idempotent —
    /// re-publishing the same value is a no-op (no `@Observable`
    /// notification fires).
    public func setMainWindowVisible(_ visible: Bool) {
        guard isMainWindowVisible != visible else { return }
        isMainWindowVisible = visible
    }
}
