import SwiftUI

/// "spent so far → projected total", in the same fill-on-a-track grammar
/// as the budget bar. Replaces the RangeBar, which layered four encodings
/// (track, range segment, point marker, reference tick) on an unlabeled
/// dollar axis and never read clearly even with a legend — the calibrated
/// range and accuracy live in the tooltip instead.
///
/// The Now strip's Today tile draws it labelled, "$X spent" on the left and
/// the projection on the right. A screen whose own tiles already print both
/// numbers draws `SpendProgressTrack`, the same bar without the labels.
public struct SpendProgressBar: View {
    private let spent: Double
    /// Always ≥ spent (callers clamp).
    private let projected: Double
    private let projectedLabel: String
    private let help: String

    public init(spent: Double, projected: Double, projectedLabel: String, help: String = "") {
        self.spent = spent
        self.projected = projected
        self.projectedLabel = projectedLabel
        self.help = help
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("\(pacerCost(spent)) spent")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 8)
                Text(projectedLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            SpendProgressTrack(spent: spent, projected: projected)
        }
        .modifier(OptionalHelp(text: help))
    }
}

/// The spent → projected bar on its own: the filled share of the track is
/// `spent` over `projected`.
public struct SpendProgressTrack: View {
    private let spent: Double
    /// Always ≥ spent (callers clamp).
    private let projected: Double

    /// The bar's height, for a caller that holds its room before it draws.
    public static let height: CGFloat = 5

    public init(spent: Double, projected: Double) {
        self.spent = spent
        self.projected = projected
    }

    public var body: some View {
        GeometryReader { geo in
            // Typed in steps: Xcode 16 finds mixed CGFloat/Double maths
            // ambiguous.
            let ratio: Double = projected > 0 ? min(1, max(0, spent / projected)) : 0
            let fill: CGFloat = max(4, geo.size.width * CGFloat(ratio))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.accentColor.opacity(0.18))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: fill)
            }
        }
        .frame(height: Self.height)
    }
}
