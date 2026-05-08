import SwiftUI
import PacerCore

/// Color mappings for `PacerCore.PaceBand` and `PacerCore.UsageBand`.
/// Living here (not in `PacerCore`) keeps `PacerCore` SwiftUI-free for
/// CLI / test contexts that don't link AppKit. Anything that wants to
/// render a band color imports `PacerUI` and gets a single source of
/// truth — same green/yellow/orange/red across the dashboard, menu
/// bar, and widgets.
public extension PaceBand {
    /// SwiftUI `Color` for the four pace bands. `.white` maps to
    /// `.primary` so it adapts in dark mode (white-on-white would
    /// vanish on the light system widget background).
    var color: Color {
        switch self {
        case .green:  return .green
        case .white:  return .primary
        case .yellow: return .yellow
        case .red:    return .red
        }
    }
}

public extension UsageBand {
    /// Four-step ramp green → yellow → orange → red mirroring the
    /// `PacerSettings` notification thresholds (50 / 75 / 90).
    var color: Color {
        switch self {
        case .green:  return .green
        case .yellow: return .yellow
        case .orange: return .orange
        case .red:    return .red
        }
    }
}
