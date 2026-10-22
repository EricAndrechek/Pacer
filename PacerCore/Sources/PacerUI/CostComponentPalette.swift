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
/// appearances. Cache reads, which are most of the bill on a real store, take
/// the calm blue the cost chart was drawn in before it was stacked, so the
/// chart's overall colour does not change character.
///
/// **Neighbours must survive colour blindness.** The parts stack in
/// `CostComponent` order, so each touches the next in every bar and sits beside
/// it in every legend. Output was purple, right beside the blue reads, and
/// under protanopia the two were ΔE 5.9 apart (OKLab ×100, Machado 2009
/// simulation), below the 6 floor and the 8 target, so a colour-blind owner
/// could not tell them apart. The same five colours, with output and 1-hour
/// writes swapped, put every neighbouring pair at ΔE ≥ 18 under protanopia
/// and deuteranopia. That is why the 1-hour tier is purple rather than the
/// warm pair it used to make with the 5-minute amber. Only these two parts
/// moved; nothing outside cost-part views reads this mapping.
/// `CostBreakdownTests` checks the separation.
public enum PacerCostPalette {
    /// Hue in degrees, per part. Internal so the tests can pin the layout.
    static func hue(_ part: CostComponent) -> Double {
        switch part {
        case .input:        return 189    // mint
        case .output:       return 40     // red-orange
        case .cacheRead:    return 257.4  // blue
        case .cacheWrite5m: return 76     // amber
        case .cacheWrite1h: return 312.4  // purple
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
