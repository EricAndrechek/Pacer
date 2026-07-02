import SwiftUI
import Charts

/// One wedge of a ``PacerDonut``: a stable, unique `id` (which is also the
/// color-scale key and what hover compares against), its magnitude, and its
/// already-resolved color.
public struct PacerDonutSlice: Identifiable {
    public let id: String
    public let value: Double
    public let color: Color

    public init(id: String, value: Double, color: Color) {
        self.id = id
        self.value = value
        self.color = color
    }
}

/// The shared identity donut behind every "share" card — Top projects, Token
/// share, the dashboard per-model card, project detail, and day detail. The
/// `SectorMark` ring, color pinning, hover-highlight opacity, and
/// accessibility used to be copy-pasted five times (and drifted); they live
/// here now.
///
/// Callers keep their own hover *state* — each card derives the hovered slice
/// its own (often perf-tuned) way — and pass in the hovered slice `id` plus
/// the angle-selection binding. The legend stays per-card because its
/// trailing content differs, but every legend shares ``PacerDonutLegendRow``
/// so the color swatch is defined once.
public struct PacerDonut: View {
    private let slices: [PacerDonutSlice]
    private let innerRatio: Double
    private let size: CGFloat
    private let hoveredID: String?
    @Binding private var hoveredAngle: Double?
    private let accessibilityLabelText: String
    private let accessibilityValueText: String

    public init(
        slices: [PacerDonutSlice],
        innerRatio: Double = 0.6,
        size: CGFloat = 160,
        hoveredID: String? = nil,
        hoveredAngle: Binding<Double?>,
        accessibilityLabel: String,
        accessibilityValue: String
    ) {
        self.slices = slices
        self.innerRatio = innerRatio
        self.size = size
        self.hoveredID = hoveredID
        self._hoveredAngle = hoveredAngle
        self.accessibilityLabelText = accessibilityLabel
        self.accessibilityValueText = accessibilityValue
    }

    public var body: some View {
        Chart(slices) { slice in
            SectorMark(
                angle: .value("Value", slice.value),
                innerRadius: .ratio(innerRatio),
                // A clear gap between wedges so adjacent same-family slices
                // (Opus 4.7 next to 4.8) read as separate even when their
                // colors are close neighbors on the spectrum.
                angularInset: 2.5
            )
            .foregroundStyle(by: .value("Slice", slice.id))
            .cornerRadius(2)
            // Dim non-hovered wedges without touching chart geometry.
            .opacity(hoveredID.map { $0 == slice.id ? 1.0 : 0.45 } ?? 1.0)
        }
        .frame(width: size, height: size)
        // Pin each slice to its resolved color (domain and range share the
        // slice `id` order) so wedges match their legend swatches.
        .chartForegroundStyleScale(
            domain: slices.map(\.id),
            range: slices.map(\.color)
        )
        .chartLegend(.hidden)
        .chartAngleSelection(value: $hoveredAngle)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityValue(accessibilityValueText)
    }
}

/// A legend line for a ``PacerDonut``: color swatch + label on the left,
/// caller-supplied trailing content (value, %, in/out…) on the right.
/// Centralizing the swatch means a donut legend can't silently forget it —
/// three of them had.
public struct PacerDonutLegendRow<Trailing: View>: View {
    private let color: Color
    private let label: String
    private let labelMaxWidth: CGFloat?
    private let trailing: Trailing

    public init(
        color: Color,
        label: String,
        labelMaxWidth: CGFloat? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.color = color
        self.label = label
        self.labelMaxWidth = labelMaxWidth
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: labelMaxWidth, alignment: .leading)
            Spacer(minLength: 8)
            trailing
        }
    }
}
