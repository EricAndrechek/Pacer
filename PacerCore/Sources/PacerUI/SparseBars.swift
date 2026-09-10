import SwiftUI
import Charts

/// Bar width for a series whose length varies wildly.
///
/// The problem it solves, and the mistake it fixes, are two ends of the same
/// thing. Swift Charts' `.automatic` width divides the plot among the bands, so
/// a two-day account's "last 30 days" drew two bars a third of the card wide —
/// a rendering fault, not a chart. Capping with `.fixed` fixed that and broke
/// the common case: a *full* series has more bands than a fixed width fits, so
/// 30 bars at 44pt overlapped into a smear.
///
/// `.fixed` only when the bands are few enough that the cap is genuinely the
/// smaller number; `.automatic` the rest of the time, which is every chart a
/// user with real history is looking at.
public enum PacerSparseBars {

    /// Below this many bands, `.automatic` starts producing slabs.
    public static let sparseThreshold = 8

    public static func width(count: Int, cap: CGFloat = 44) -> MarkDimension {
        count <= sparseThreshold ? .fixed(cap) : .automatic
    }
}
