import Foundation

/// Four-band coloring for "are you ahead or behind your linear pace within
/// the current rate-limit window."
///
/// This is a richer version of `UsageBand` (which keys off absolute usage
/// only). Where `UsageBand` answers "how full is the bucket", `PaceBand`
/// answers "given how much of the window has elapsed, are you on track."
///
/// Four-band policy:
///
///   - **green**:   used% < pace% − tolerance        → behind pace, plenty of headroom
///   - **white**:   |used% − pace%| ≤ tolerance       → on track
///   - **yellow**:  used% > pace% + tolerance         → ahead of pace
///   - **red**:     used% > pace% + 15pp  OR  used% > 90  → cap imminent
///
/// `tolerance` defaults to 5 percentage points — small enough that the
/// indicator reacts to real drift, large enough that a fresh post-reset
/// chart doesn't jitter between green and white during the first few
/// minutes when both numbers are tiny.
public enum PaceBand: Sendable, Equatable {
    case green
    case white
    case yellow
    case red

    /// `usedPct` and `paceEndPct` are 0–100. Order of checks matters:
    /// the red ceiling fires before yellow so a >90% used always reads
    /// red regardless of pace position.
    public init(usedPct: Double, paceEndPct: Double, tolerance: Double = 5.0) {
        if usedPct >= 90 || usedPct > paceEndPct + 15 {
            self = .red
            return
        }
        if usedPct > paceEndPct + tolerance {
            self = .yellow
            return
        }
        if usedPct < paceEndPct - tolerance {
            self = .green
            return
        }
        self = .white
    }
}

/// Pure-function helpers for pace-chart math. Lives in PacerCore so the
/// dashboard, MenuBarExtra, and widgets share one source of truth.
public enum PaceMath {

    /// Fraction (0..1) of the current rate-limit window that has elapsed.
    /// `windowStart = resetsAt − windowDuration`. Clamps to 0..1 so a
    /// just-reset window doesn't return a slightly-negative fraction
    /// (clock skew between server reset and our local now).
    public static func paceFraction(
        now: Date,
        resetsAt: Date,
        windowDuration: TimeInterval
    ) -> Double {
        let elapsed = now.timeIntervalSince(resetsAt.addingTimeInterval(-windowDuration))
        if elapsed <= 0 { return 0 }
        if elapsed >= windowDuration { return 1 }
        return elapsed / windowDuration
    }

    /// Window length in seconds for a given window key. Returns nil for
    /// unknown keys so callers can decide whether to skip rendering or
    /// fall back to a default.
    public static func windowDuration(for window: String) -> TimeInterval? {
        switch window {
        case "five_hour":  return 5 * 60 * 60
        case "seven_day":  return 7 * 24 * 60 * 60
        default:           return nil
        }
    }
}
