import SwiftUI
import PacerCore

/// A balanced grid for the pace columns, sized from the width it is actually
/// offered.
///
/// The card used to render a `LazyVGrid` whose column count came from a
/// `@State` width, populated by a `GeometryReader` preference in the grid's own
/// background. That round-trip is a frame behind by construction, and it goes
/// *stale*: with only the fixed 5h/7d windows the card takes a different code
/// path entirely and the grid never renders, so nothing re-measures — then a
/// scoped window appears, the grid comes back, and it lays three columns out
/// against whatever width was last recorded. Same window, same card, sometimes
/// three across and sometimes a lopsided two-plus-one.
///
/// A `Layout` is handed the real proposed width during layout, so the count is
/// computed from the truth on every pass and there is no state to go stale.
public struct PaceColumnGrid: Layout {
    public let itemSpacing: Double
    public let rowSpacing: Double
    public let minItemWidth: Double

    public init(itemSpacing: Double = 24, rowSpacing: Double = 22,
                minItemWidth: Double = 250) {
        self.itemSpacing = itemSpacing
        self.rowSpacing = rowSpacing
        self.minItemWidth = minItemWidth
    }

    /// Measured heights, by subview index, at the one item width they were
    /// measured for. Each subview is a deep tree (AnyLayout, a ScrollView,
    /// nested stacks) and measuring one compounds through every nested layout,
    /// so `sizeThatFits` and `placeSubviews` measuring all of them again each
    /// was a production 2 s+ hang (Sentry PACER-10). A pass measures each
    /// subview at most once per width; `updateCache` clears it whenever
    /// SwiftUI says the subviews changed.
    public struct Cache {
        var heights: [Double: [Int: Double]] = [:]
        private(set) var measurements = 0

        mutating func height(at index: Int, itemWidth width: Double,
                             measure: () -> Double) -> Double {
            if let known = heights[width]?[index] { return known }
            // The parent probes a handful of proposals per pass; a runaway
            // sequence of widths (a live resize) must not grow this forever.
            if heights[width] == nil, heights.count >= 8 { heights = [:] }
            let measured = measure()
            measurements += 1
            heights[width, default: [:]][index] = measured
            return measured
        }
    }

    public func makeCache(subviews: Subviews) -> Cache { Cache() }

    public func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                             cache: inout Cache) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = Double(proposal.width ?? CGFloat(minItemWidth))
        let plan = plan(width: width, count: subviews.count)
        var height: Double = 0
        for row in plan.rows {
            let tallest = row.reduce(0.0) { best, index in
                max(best, cache.height(at: index, itemWidth: plan.itemWidth) {
                    Double(subviews[index].sizeThatFits(
                        .init(width: CGFloat(plan.itemWidth), height: nil)).height)
                })
            }
            height += tallest + rowSpacing
        }
        return CGSize(width: CGFloat(width), height: CGFloat(max(0, height - rowSpacing)))
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                              subviews: Subviews, cache: inout Cache) {
        guard !subviews.isEmpty else { return }
        let plan = plan(width: Double(bounds.width), count: subviews.count)
        var y = Double(bounds.minY)
        for row in plan.rows {
            var x = Double(bounds.minX)
            var tallest: Double = 0
            for index in row {
                let height = cache.height(at: index, itemWidth: plan.itemWidth) {
                    Double(subviews[index].sizeThatFits(
                        .init(width: CGFloat(plan.itemWidth), height: nil)).height)
                }
                subviews[index].place(
                    at: CGPoint(x: x, y: y), anchor: .topLeading,
                    proposal: .init(width: CGFloat(plan.itemWidth), height: nil))
                tallest = max(tallest, height)
                x += plan.itemWidth + itemSpacing
            }
            y += tallest + rowSpacing
        }
    }

    /// Rows of subview indices, left-aligned, and the width each item gets.
    /// The column count is `PaceColumnLayout.columnCount` — the same balancing
    /// rule the card documented (4→2+2, 5→3+2), now fed a real width.
    private func plan(width: Double, count: Int) -> (rows: [[Int]], itemWidth: Double) {
        let columns = max(1, PaceColumnLayout.columnCount(
            itemCount: count, availableWidth: width,
            minItemWidth: minItemWidth, spacing: itemSpacing))
        let itemWidth = max(1, (width - itemSpacing * Double(columns - 1)) / Double(columns))
        var rows: [[Int]] = []
        var index = 0
        while index < count {
            let upper = min(index + columns, count)
            rows.append(Array(index..<upper))
            index = upper
        }
        return (rows, itemWidth)
    }
}
