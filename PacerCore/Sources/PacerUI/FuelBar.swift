import SwiftUI
import PacerCore

/// A window's use as one thin horizontal bar (#318, the menu-bar dropdown's
/// "fuel bars"): how full it is, where even pace would be by now, and how
/// much of the number is Pacer's estimate.
///
/// - **The fill** is the reading, coloured by the window's `PaceBand`: the
///   same green / yellow / red as the dashboard card's big number, so the two
///   never disagree about the same window. A window with no clock (no pace)
///   falls back to the `UsageBand` of the number shown.
/// - **An estimate's extra part** is a lighter tail of the same colour past
///   the reading, the way `CircularGauge` draws its ring and the chart its
///   dotted stretch. An estimate below its reading has restarted past that
///   reading's reset: the reading is the window before's, so the bar is the
///   estimate's tail alone.
/// - **The tick** is the pace fraction: where an even burn would have the
///   window by now. Nil draws none (an idle window has no clock).
/// - **No reading** draws the empty track: not 0%, which nobody knows.
///
/// Plain values in, so the dropdown, a widget or a dashboard card can each
/// draw it from whatever they hold. No animation: it sits in the status
/// menu, whose host re-measures on open.
public struct PacerFuelBar: View {
    /// Anthropic's reading, 0–100; nil for none.
    public let reading: Double?
    /// The live estimate on that reading, when the number is one.
    public let estimate: Double?
    /// The elapsed share of the window, 0–1; nil draws no tick.
    public let pace: Double?
    public var height: CGFloat

    public init(reading: Double?, estimate: Double? = nil, pace: Double? = nil, height: CGFloat = 6) {
        self.reading = reading
        self.estimate = reading == nil ? nil : estimate
        self.pace = pace
        self.height = height
    }

    /// The number the colour is judged on: the estimate, else the reading.
    public var shown: Double? { estimate ?? reading }

    nonisolated static func fraction(_ percent: Double?) -> CGFloat {
        guard let percent else { return 0 }
        return max(0, min(1, CGFloat(percent) / 100))
    }

    /// The solid and the tail's ends, 0–1, as drawn.
    public var stretches: (solid: CGFloat, tail: CGFloat) { Self.stretches(reading: reading, estimate: estimate) }

    /// The solid stretch is the reading, the tail runs on to the estimate.
    /// An estimate under its reading has restarted past that reading's
    /// reset, so it is drawn alone, from 0.
    public nonisolated static func stretches(reading: Double?, estimate: Double?) -> (solid: CGFloat, tail: CGFloat) {
        guard reading != nil else { return (0, 0) }
        let restarted = estimate.map { $0 < (reading ?? 0) } ?? false
        let solid = restarted ? 0 : fraction(reading)
        return (solid, max(solid, fraction(estimate)))
    }

    public var body: some View {
        let color = pace.map { PaceBand(usedPct: shown ?? 0, paceEndPct: $0 * 100).barColor }
            ?? UsageBand(percentage: shown ?? 0).color
        let (solid, tail) = stretches
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(height: height)
                // Under the solid stretch, from 0, so the two never show a
                // seam where they meet.
                if tail > solid {
                    Capsule()
                        .fill(color.opacity(CircularGauge.estimateOpacity))
                        .frame(width: Self.drawn(tail, of: width), height: height)
                }
                if solid > 0 {
                    Capsule()
                        .fill(color)
                        .frame(width: Self.drawn(solid, of: width), height: height)
                }
                if let pace {
                    // White on a dark menu, as drawn in the mockup; dark on a
                    // light one, where white would vanish into the track.
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary.opacity(0.8))
                        .frame(width: Self.tickWidth, height: height * 2)
                        .offset(x: Self.tickOffset(pace, width: width))
                }
            }
            .frame(width: width, height: height * 2)
        }
        .frame(height: height * 2)
        .accessibilityElement()
        .accessibilityValue(shown.map { PacerMeterFormat.percent($0, isEstimate: estimate != nil) } ?? "no reading")
    }

    nonisolated static let tickWidth: CGFloat = 2

    /// A stretch's width: its share, but never thinner than a hairline that
    /// still shows, so 0.8% is visible without reading as 3%.
    nonisolated static func drawn(_ fraction: CGFloat, of width: CGFloat) -> CGFloat {
        max(2, width * fraction)
    }

    /// The tick's left edge, centred on the pace and kept inside the bar.
    nonisolated static func tickOffset(_ pace: Double, width: CGFloat) -> CGFloat {
        let x = width * CGFloat(max(0, min(1, pace))) - tickWidth / 2
        return min(max(0, x), max(0, width - tickWidth))
    }
}
