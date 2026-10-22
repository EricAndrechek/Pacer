import CoreGraphics
import Testing
@testable import PacerUI

// The arithmetic behind a usage table that never scrolls sideways: a saved
// layout's widths scaled to the width the table has (`PacerTableFit`).

@Suite("Table fit")
struct TableFitTests {

    @Test("shrinking takes from each column in proportion to its room above its minimum")
    func shrinksProportionally() {
        // 260 + 140 × 3 = 680, minimums 60 + 30 × 3 = 150; fit to 415.
        let fitted: [CGFloat] = PacerTableFit.widths([260, 140, 140, 140], minimums: [60, 30, 30, 30], target: 415)
        let total: CGFloat = fitted.reduce(0, +)
        #expect(abs(total - 415) < 1e-9)
        // Half the room above the minimums kept: 60 + 200 / 2, 30 + 110 / 2.
        #expect(abs(fitted[0] - 160) < 1e-9)
        #expect(fitted.dropFirst().allSatisfy { abs($0 - 85) < 1e-9 })
    }

    @Test("a column already at its minimum stays there; nothing goes below one")
    func minimumsHold() {
        let fitted: [CGFloat] = PacerTableFit.widths([100, 30, 70], minimums: [40, 30, 30], target: 150)
        #expect(fitted[1] == 30)
        #expect(fitted.allSatisfy { $0 >= 30 })
        #expect(abs(fitted.reduce(0, +) - 150) < 1e-9)
        // Narrower than every minimum: every column at its minimum.
        let squeezed: [CGFloat] = PacerTableFit.widths([100, 50], minimums: [60, 30], target: 50)
        #expect(squeezed == [60, 30])
    }

    @Test("growing scales every column alike; a fit is left alone")
    func growsAndKeeps() {
        let grown: [CGFloat] = PacerTableFit.widths([100, 50, 50], minimums: [60, 30, 30], target: 400)
        #expect(grown == [200, 100, 100])
        let kept: [CGFloat] = PacerTableFit.widths([100, 50], minimums: [60, 30], target: 150.3)
        #expect(kept == [100, 50])
        #expect(PacerTableFit.widths([], minimums: [], target: 10).isEmpty)
    }

    @Test("whole points, summing to what the fractions did, the remainder on the widest")
    func wholePoints() {
        let rounded: [CGFloat] = PacerTableFit.wholePoints([117.34, 58.19, 58.19, 58.28])
        #expect(rounded == [118, 58, 58, 58])
        #expect(abs(rounded.reduce(0, +) - 292) < 1e-9)
    }

    @Test("what the columns may sum to is the visible width less what the table spends around them")
    func target() {
        // A table 1234 wide holding 1100 of columns spends 134 on spacing
        // and insets; in 600 the columns get 466.
        #expect(PacerTableFit.target(tableWidth: 1234, columnsWidth: 1100, visibleWidth: 600) == 466)
    }
}
