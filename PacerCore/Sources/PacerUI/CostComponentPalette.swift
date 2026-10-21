import SwiftUI
import PacerCore

/// The colour of each priced part of a cost (#225): the one definition every
/// breakdown, cost bar and component-stacked chart reads.
///
/// `CostComponent` itself stays in `PacerCore`, SwiftUI-free, like
/// `UsageBand`; this is its colour mapping, like `PaceBandColor`.
///
/// **Layout.** Hues sit on the same "pretty ridge" as the model and project
/// colours (`pacerRidge`), so a part is as legible as a model swatch in both
/// appearances. The two cache-write tiers are the warm neighbours (amber for
/// 5-minute, red-orange for 1-hour): they are two prices for one act, and
/// reading as a pair is the point. Cache reads, which are most of the bill on
/// a real store, take the calm blue the cost chart was drawn in before it was
/// stacked, so the chart's overall colour does not change character. Output
/// is purple and fresh input — usually a sliver — is mint.
public enum PacerCostPalette {
    /// Hue in degrees, per part. Internal so the tests can pin the layout.
    static func hue(_ part: CostComponent) -> Double {
        switch part {
        case .input:        return 189    // mint
        case .output:       return 312.4  // purple
        case .cacheRead:    return 257.4  // blue
        case .cacheWrite5m: return 76     // amber
        case .cacheWrite1h: return 40     // red-orange
        }
    }

    public static func color(_ part: CostComponent) -> Color {
        let h = hue(part)
        let (l, c) = pacerRidge(h)
        return pacerOKLCH(l: l, c: c, hueDegrees: h)
    }

    /// Domain and range for a Swift Charts `chartForegroundStyleScale`, in
    /// stacking order. A chart stacked by part takes both from here so its
    /// segments and legend are the colours every breakdown shows.
    public static var chartDomain: [String] { CostComponent.allCases.map(\.label) }
    public static var chartRange: [Color] { CostComponent.allCases.map(color) }
}

public extension CostComponent {
    var color: Color { PacerCostPalette.color(self) }
}
