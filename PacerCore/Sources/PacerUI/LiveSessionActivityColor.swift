import SwiftUI
import PacerCore

/// SwiftUI color extension for `PacerCore.LiveSessionActivity`. Mirrors
/// the pattern in `PaceBandColor` so the core enum stays SwiftUI-free
/// and the widget / app / menu bar all import this for one canonical
/// color per state.
public extension LiveSessionActivity {
    /// Green for active sessions (Claude is generating now), yellow
    /// for recent (paused but the user is still here), `.secondary`
    /// for idle (the row exists but the session is over).
    var color: Color {
        switch self {
        case .active: return .green
        case .recent: return .yellow
        case .idle:   return .secondary
        }
    }
}
