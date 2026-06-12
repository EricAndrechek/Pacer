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
    /// The word to show next to the reference-tick swatch in the micro-legend,
    /// e.g. "typical Friday" or "spent so far". When this is non-nil (or when
    /// `range` is non-nil), a self-contained legend row is appended below the
    /// bar so the tick, segment, and dot are all named — user feedback
    /// identified these as uninterpretable without labels or tooltips.
    public let referenceLegend: String?
    public var tint: Color

    public init(
        domain: ClosedRange<Double>,
        range: ClosedRange<Double>?,
        point: Double,
        reference: Double? = nil,
        lowerLabel: String? = nil,
        upperLabel: String? = nil,
        referenceLegend: String? = nil,
        tint: Color = .accentColor
    ) {
        self.domain = domain
        self.range = range
        self.point = point
        self.reference = reference
        self.lowerLabel = lowerLabel
        self.upperLabel = upperLabel
        self.referenceLegend = referenceLegend
        self.tint = tint
    }

    public var body: some View {
        let labeledBar = Group {
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
        if range != nil || referenceLegend != nil {
            VStack(alignment: .leading, spacing: 4) {
                labeledBar
                legend
            }
        } else {
            labeledBar
        }
    }

    /// Micro-legend: one swatch+word pair per visual element present in the
    /// bar, rendered at 9pt tertiary so it reads as annotation rather than
    /// content. Only shown when there is something to label (a range segment
    /// or a reference tick); the dot is always present so it is always listed.
    @ViewBuilder private var legend: some View {
        HStack(spacing: 10) {
            if range != nil {
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(tint.opacity(0.35))
                        .frame(width: 14, height: 5)
                    Text("likely range")
                }
            }
            HStack(spacing: 4) {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
                Text("projected")
            }
            if reference != nil, let referenceLegend {
                HStack(spacing: 4) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.7))
                        .frame(width: 1.5, height: 9)
                    Text(referenceLegend)
                }
            }
        }
        .font(.system(size: 9))
        .foregroundStyle(.tertiary)
    }

    private var bar: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 8)
                if let range {
                    let x0 = x(range.lowerBound, in: w)
                    let x1 = x(range.upperBound, in: w)
                    Capsule()
                        .fill(tint.opacity(0.45))
                        .frame(width: max(8, x1 - x0), height: 8)
                        .offset(x: x0)
                }
                if let reference {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.7))
                        .frame(width: 2, height: 14)
                        .offset(x: x(reference, in: w) - 0.75)
                }
                Circle()
                    .fill(tint)
                    .stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 1.5)
                    .frame(width: 11, height: 11)
                    .offset(x: x(point, in: w) - 5.5)
            }
            .frame(height: 14)
        }
        .frame(height: 14)
    }

    private func x(_ value: Double, in width: CGFloat) -> CGFloat {
        let span = domain.upperBound - domain.lowerBound
        guard span > 0 else { return 0 }
        let f = (min(max(value, domain.lowerBound), domain.upperBound) - domain.lowerBound) / span
        return CGFloat(f) * width
    }
}
