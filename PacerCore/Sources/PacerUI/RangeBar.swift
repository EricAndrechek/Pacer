import SwiftUI

/// The app's one idiom for "a point estimate with its calibrated range, in
/// the context of what's normal" — the horizontal range bar Apple's Weather
/// uses for daily temperature spans, adapted to dashboard rows.
///
/// Anatomy (back to front):
///   - full-width 6pt capsule *track* — the context domain (e.g. zero to a
///     high percentile of the user's own daily totals), in a quiet fill;
///   - inner capsule *segment* — the calibrated 80% range, in accent;
///   - a *tick* — an optional reference value (e.g. the user's typical day);
///   - an 8pt circle *marker* — the point estimate, stroked so it reads on
///     top of the segment.
///
/// Deliberately not a Gauge (a gauge needle implies meaningful scale
/// endpoints a forecast doesn't have) and not error-bar whiskers (lay
/// viewers misread within-bar values as likelier — Newman & Scholl 2012).
/// One encoding, no gradients, no animation (decorative animation measurably
/// cost MainActor time in this app's perf history).
public struct RangeBar: View {
    /// Context domain the whole bar spans.
    public let domain: ClosedRange<Double>
    /// The calibrated range segment (clamped into the domain).
    public let range: ClosedRange<Double>?
    /// The point estimate marker.
    public let point: Double
    /// Optional reference tick (e.g. "your typical day").
    public let reference: Double?
    /// Endpoint labels flanking the bar — the units the bar is read in
    /// (Weather's lo°/hi° row pattern). Without them a bare bar is
    /// uninterpretable; with them it needs no caption at all.
    public let lowerLabel: String?
    public let upperLabel: String?
    public var tint: Color

    public init(
        domain: ClosedRange<Double>,
        range: ClosedRange<Double>?,
        point: Double,
        reference: Double? = nil,
        lowerLabel: String? = nil,
        upperLabel: String? = nil,
        tint: Color = .accentColor
    ) {
        self.domain = domain
        self.range = range
        self.point = point
        self.reference = reference
        self.lowerLabel = lowerLabel
        self.upperLabel = upperLabel
        self.tint = tint
    }

    public var body: some View {
        if lowerLabel != nil || upperLabel != nil {
            HStack(spacing: 8) {
                if let lowerLabel {
                    Text(lowerLabel)
                        .font(.caption.weight(.medium)).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .layoutPriority(1)
                }
                bar
                if let upperLabel {
                    Text(upperLabel)
                        .font(.caption.weight(.medium)).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .layoutPriority(1)
                }
            }
        } else {
            bar
        }
    }

    private var bar: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 6)
                if let range {
                    let x0 = x(range.lowerBound, in: w)
                    let x1 = x(range.upperBound, in: w)
                    Capsule()
                        .fill(tint.opacity(0.35))
                        .frame(width: max(6, x1 - x0), height: 6)
                        .offset(x: x0)
                }
                if let reference {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.7))
                        .frame(width: 1.5, height: 12)
                        .offset(x: x(reference, in: w) - 0.75)
                }
                Circle()
                    .fill(tint)
                    .stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 1.5)
                    .frame(width: 9, height: 9)
                    .offset(x: x(point, in: w) - 4.5)
            }
            .frame(height: 12)
        }
        .frame(height: 12)
    }

    private func x(_ value: Double, in width: CGFloat) -> CGFloat {
        let span = domain.upperBound - domain.lowerBound
        guard span > 0 else { return 0 }
        let f = (min(max(value, domain.lowerBound), domain.upperBound) - domain.lowerBound) / span
        return CGFloat(f) * width
    }
}
