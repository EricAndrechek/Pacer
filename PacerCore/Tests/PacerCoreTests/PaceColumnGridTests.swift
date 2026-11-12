import Testing
import SwiftUI
import AppKit
@testable import PacerUI

/// Sentry PACER-10: the grid measured every subview in `sizeThatFits` and again
/// in `placeSubviews`, and each subview is a deep tree. The layout cache makes
/// a pass measure each subview once per width.
@MainActor
struct PaceColumnGridTests {
    final class Counter: @unchecked Sendable {
        nonisolated(unsafe) var calls = 0
    }

    /// A child whose own layout counts every time its parent asks it for a size.
    struct CountingLayout: Layout {
        let counter: Counter
        let height: Double
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            counter.calls += 1
            return CGSize(width: proposal.width ?? 10, height: height)
        }
        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {}
    }

    @Test func cacheMeasuresOncePerIndexPerWidth() {
        var cache = PaceColumnGrid.Cache()
        var calls = 0
        for _ in 0..<3 {
            for index in 0..<4 {
                _ = cache.height(at: index, itemWidth: 300) { calls += 1; return Double(index) }
            }
        }
        #expect(calls == 4)
        _ = cache.height(at: 0, itemWidth: 280) { calls += 1; return 0 }
        #expect(calls == 5)
        // The first width is still cached after another was probed.
        _ = cache.height(at: 1, itemWidth: 300) { calls += 1; return 0 }
        #expect(calls == 5)
    }

    @Test func cacheReturnsTheMeasuredValue() {
        var cache = PaceColumnGrid.Cache()
        #expect(cache.height(at: 2, itemWidth: 100) { 42 } == 42)
        #expect(cache.height(at: 2, itemWidth: 100) { 7 } == 42)
    }

    @Test func hostedGridMeasuresEachChildAtMostOncePerWidthAndKeepsItsSize() {
        let counter = Counter()
        let heights: [Double] = [40, 90, 60, 30, 70]
        let grid = PaceColumnGrid(itemSpacing: 24, rowSpacing: 22, minItemWidth: 250)
        let root = grid {
            ForEach(0..<heights.count, id: \.self) { i in
                CountingLayout(counter: counter, height: heights[i]) { Color.clear }
            }
        }
        .frame(width: 800)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        host.layoutSubtreeIfNeeded()
        let fitting = host.fittingSize

        // 5 items at 800 wide: 3 columns (5 -> 3+2), item width (800-48)/3.
        let tallestRow1 = 90.0, tallestRow2 = 70.0
        #expect(abs(Double(fitting.height) - (tallestRow1 + 22 + tallestRow2)) < 0.5)
        // Without the cache this is 2 per child (size pass + place pass) or more.
        #expect(counter.calls <= heights.count, "calls: \(counter.calls)")
        #expect(counter.calls > 0)
    }
}
