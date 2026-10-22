import SwiftUI
import Charts
import PacerCore

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

/// The shared identity donut behind every "share" ring, drawn through
/// ``PacerShareDonut`` in every donut card (`PacerDonutListCard`): Today by
/// model, Top projects, the Models tab's Share and Project detail's By model. The `SectorMark` ring, color pinning,
/// hover-highlight opacity, and accessibility used to be copy-pasted five
/// times (and drifted); they live here now.
///
/// Callers keep their own hover *state* and pass in the hovered slice `id`
/// plus the angle-selection binding (``PacerShareDonut`` is one such caller).
/// A legend, where a card has one, shares ``PacerDonutLegendRow`` so the
/// color swatch is defined once.
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

// MARK: - A share donut beside its list

/// What a share donut measures: one column whose values add up to a whole
/// (a cost, a token count, a count of sessions).
public struct PacerShareMetric: Equatable, Sendable {
    /// The column it follows: a `UsageColumn` raw value or a screen's own
    /// column id.
    public let column: String
    /// What the donut's centre names it: "Cost", "Tokens", "Sessions".
    public let title: String

    public init(column: String, title: String) {
        self.column = column
        self.title = title
    }

    public static let cost = PacerShareMetric(column: UsageColumn.cost.rawValue, title: "Cost")
}

public extension UsageColumn {
    /// The metric a share donut measures while its list is sorted by this
    /// column, or nil for a column whose values do not add up to a whole
    /// (`isAdditive`): the label, the two ratios, the Mix bar. Named as the
    /// column is, so the ring's centre and the list's title agree ("Tokens").
    var shareMetric: PacerShareMetric? {
        guard isAdditive else { return nil }
        return self == .cost ? .cost : PacerShareMetric(column: rawValue, title: title(label: ""))
    }
}

/// The wedges of a share donut, built from the rows of the list beside it.
///
/// The donut measures whatever the list is sorted by, when that adds up
/// (cost, a token column, a screen's count), and cost otherwise (the label,
/// a ratio, a date): the list's column titles are the donut's metric picker,
/// so there is one control rather than two that can disagree. The wedges run
/// largest first whatever the sort's direction: flipping it reorders the
/// list, not the ring.
///
/// Plain and `Equatable`, built where the screen caches its rows: a hover
/// changes only the donut's own state, never this.
public struct PacerShareDonutData: Equatable {
    public struct Slice: Identifiable, Equatable {
        public let id: String
        public let label: String
        public let value: Double
        public let color: Color
        /// Rows folded into this wedge: one, or the tail's count for Other.
        public let rows: Int
    }

    /// The id of the wedge the tail folds into.
    public static let otherID = "__other__"

    public let metric: PacerShareMetric
    public let slices: [Slice]
    public let total: Double
    /// Each wedge's end on the ring (a running total), for hover lookups.
    let ends: [Double]

    /// - `maxSlices`: how many rows get a wedge of their own before the rest
    ///   fold into one Other wedge. A single leftover row keeps its own: an
    ///   Other of one would hide a name to save nothing.
    public init<Extra: PacerUsageExtra>(
        rows: [PacerUsageRow<Extra>],
        sort: PacerUsageSort,
        maxSlices: Int = .max
    ) {
        let metric = Self.metric(for: sort, extra: Extra.self)
        let valued: [(row: PacerUsageRow<Extra>, value: Double)] = rows.compactMap { row in
            let value = Self.value(of: row, metric)
            return value > 0 ? (row, value) : nil
        }
        let ordered = valued.sorted {
            $0.value != $1.value ? $0.value > $1.value : $0.row.id < $1.row.id
        }
        var slices: [Slice] = []
        // At least two rows past the cap (written so `.max` cannot overflow).
        let folds = ordered.count - 1 > maxSlices
        let named = folds ? Array(ordered.prefix(maxSlices)) : ordered
        for entry in named {
            slices.append(Slice(id: entry.row.id, label: entry.row.label, value: entry.value,
                                color: entry.row.color ?? .gray, rows: 1))
        }
        if folds {
            let tail = ordered.dropFirst(maxSlices)
            let sum: Double = tail.reduce(0) { $0 + $1.value }
            slices.append(Slice(id: Self.otherID, label: "\(tail.count) others", value: sum,
                                color: .secondary, rows: tail.count))
        }
        var running = 0.0
        var ends: [Double] = []
        for slice in slices {
            running += slice.value
            ends.append(running)
        }
        self.metric = metric
        self.slices = slices
        self.total = running
        self.ends = ends
    }

    /// The metric for `sort`: its column when that adds up, cost otherwise.
    static func metric<Extra: PacerUsageExtra>(for sort: PacerUsageSort, extra: Extra.Type) -> PacerShareMetric {
        if let standard = UsageColumn(rawValue: sort.column) {
            return standard.shareMetric ?? .cost
        }
        return Extra.shareMetric(forColumn: sort.column) ?? .cost
    }

    static func value<Extra: PacerUsageExtra>(of row: PacerUsageRow<Extra>, _ metric: PacerShareMetric) -> Double {
        if let standard = UsageColumn(rawValue: metric.column) {
            if standard == .cost { return row.cost }
            return Double(standard.tokenCount(of: row.tokens) ?? 0)
        }
        return row.extra.shareValue(forColumn: metric.column) ?? 0
    }

    /// The wedge at `angle`, the value `chartAngleSelection` reports: a
    /// point on the ring's running total.
    public func slice(at angle: Double?) -> Slice? {
        guard let angle, !slices.isEmpty else { return nil }
        for (index, end) in ends.enumerated() where angle <= end {
            return slices[index]
        }
        return slices.last
    }

    /// A wedge's share of the ring, 0...1.
    public func share(of slice: Slice) -> Double {
        total > 0 ? slice.value / total : 0
    }

    /// What VoiceOver reads in place of the ring: the five largest shares.
    var spokenSummary: String {
        guard total > 0 else { return "no data yet" }
        return slices.prefix(5).map { slice in
            "\(slice.label) \(Int((share(of: slice) * 100).rounded())) percent"
        }.joined(separator: ", ")
    }
}

/// A share donut with its own hover: the ring in the rows' colours, and in
/// its centre the metric it measures, or, under the pointer, that wedge's
/// share and name. The numbers themselves are in the list beside it.
public struct PacerShareDonut: View {
    let data: PacerShareDonutData
    let size: CGFloat
    let accessibilityLabel: String
    /// The hover lives here, so moving the pointer over the ring redraws the
    /// ring and its centre, not the card or the list beside it.
    @State private var hoveredAngle: Double?

    static let innerRatio: Double = 0.62

    public init(_ data: PacerShareDonutData, size: CGFloat = 140, accessibilityLabel: String) {
        self.init(data, size: size, accessibilityLabel: accessibilityLabel, hoveredAngle: nil)
    }

    /// With a hover already in place: for the render tests, which cannot
    /// move a pointer.
    init(_ data: PacerShareDonutData, size: CGFloat = 140, accessibilityLabel: String,
         hoveredAngle: Double?) {
        self.data = data
        self.size = size
        self.accessibilityLabel = accessibilityLabel
        _hoveredAngle = State(initialValue: hoveredAngle)
    }

    public var body: some View {
        let hovered = data.slice(at: hoveredAngle)
        PacerDonut(
            slices: data.slices.map { PacerDonutSlice(id: $0.id, value: $0.value, color: $0.color) },
            innerRatio: Self.innerRatio,
            size: size,
            hoveredID: hovered?.id,
            hoveredAngle: $hoveredAngle,
            accessibilityLabel: accessibilityLabel,
            accessibilityValue: data.spokenSummary)
            .overlay {
                centre(hovered)
                    // The ring takes the pointer; the text must not.
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }

    @ViewBuilder
    private func centre(_ hovered: PacerShareDonutData.Slice?) -> some View {
        let inner: CGFloat = size * CGFloat(Self.innerRatio) - 12
        VStack(spacing: 1) {
            if let hovered {
                Text(PacerUsageCellText(share: data.share(of: hovered), help: "", none: "–").text)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(hovered.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                // Which column the ring measures: it follows the list's sort.
                Text(data.metric.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: inner)
    }
}
