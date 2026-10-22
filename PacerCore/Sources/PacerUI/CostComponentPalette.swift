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
/// chart's overall colour does not change character. The two cache-write tiers
/// are the warm neighbours (amber for 5-minute, red-orange for 1-hour): two
/// prices for one act, read as a pair. Fresh input, usually a sliver, is mint.
///
/// **Output is purple, but not the ridge's purple.** Parts stack in
/// `CostComponent` order, so output touches the blue reads in every bar and
/// sits beside them in every legend. At the ridge's lightness the two were
/// ΔE 5.9 apart under protanopia (OKLab ×100, Machado 2009 simulation), below
/// the 6 floor and the 8 target, and a colour-blind owner could not tell them
/// apart. Same hue family, different lightness: a deep violet on light
/// backgrounds and a soft lavender on dark ones (where a deep violet would
/// sink into the card). That puts every pair, not just neighbours, at ΔE 12.7
/// (light) / 9.2 (dark) under protanopia and deuteranopia. It also moves output
/// off Opus's mid-tone purple; Opus 5.x lands at the band's pink edge
/// (`PacerModelPalette`, uncatalogued versions), well clear of either.
/// Hue alone was tried and rejected: swapping output with a warm hue read as a
/// warning colour, and the pinks collide with Opus 5.x.
/// `CostBreakdownTests` checks the separation in both appearances.
public enum PacerCostPalette {
    /// Hue in degrees, per part. Internal so the tests can pin the layout.
    static func hue(_ part: CostComponent) -> Double {
        switch part {
        case .input:        return 189    // mint
        case .output:       return 312.4  // purple (drawn off-ridge, below)
        case .cacheRead:    return 257.4  // blue
        case .cacheWrite5m: return 76     // amber
        case .cacheWrite1h: return 40     // red-orange
        }
    }

    /// Output's purple per appearance (OKLCH): lightness is what separates it
    /// from the blue reads for a colour-blind reader. See the type's doc.
    static let outputOnLight: (l: Double, c: Double, h: Double) = (0.48, 0.18, 300)
    static let outputOnDark: (l: Double, c: Double, h: Double) = (0.72, 0.16, 305)

    public static func color(_ part: CostComponent) -> Color {
        if part == .output {
            return Color(nsColor: NSColor(name: nil) { appearance in
                let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                let v = dark ? outputOnDark : outputOnLight
                return NSColor(pacerOKLCH(l: v.l, c: v.c, hueDegrees: v.h))
            })
        }
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
