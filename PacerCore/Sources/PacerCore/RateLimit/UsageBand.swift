import Foundation

/// Discrete color band for a usage percentage. Drives the gauge fill
/// in the dashboard, the MenuBarExtra rows, and the widget gauges so
/// the visual grammar is consistent across surfaces.
///
/// Keys off absolute usage only. A pace-aware variant
/// (`PaceColor(usagePct, pacePct)`) compares actual usage to where
/// linear pace would have you — see `PaceBand` for that policy.
public enum UsageBand: Sendable, Equatable {
    /// 0–50%. Plenty of headroom.
    case green
    /// 50–75%. Steady consumption.
    case yellow
    /// 75–90%. Approaching the cap; user might want to slow down or
    /// switch models.
    case orange
    /// 90%+. Cap is imminent or hit.
    case red

    /// Server returns `usedPercentage` 0–100 (not 0–1), so accept it in
    /// the same form. Boundary values (50/75/90) round up to the
    /// "warmer" band — matches what feels right when staring at a
    /// number that just crossed a threshold.
    public init(percentage: Double) {
        switch percentage {
        case ..<50:  self = .green
        case ..<75:  self = .yellow
        case ..<90:  self = .orange
        default:     self = .red
        }
    }
}
