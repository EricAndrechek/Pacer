import Foundation
import Testing
@testable import PacerCore

/// Unit coverage for the pure pace-card layout arithmetic — the balanced
/// column count and the scoped-window ordering side. The view wires these two
/// helpers together; pinning them here keeps the "5h/7d never split" and
/// "rows stay balanced" guarantees regression-proof without rendering SwiftUI.
struct PaceColumnLayoutTests {

    // MARK: - Balanced column count

    /// Content widths chosen against the defaults (minItemWidth 250, spacing
    /// 24 ⇒ 274 per slot): 900 fits 3 across, 600 fits 2, 300 fits 1.
    static let wide: Double = 900   // fit = floor((900+24)/274) = 3
    static let narrow: Double = 600 // fit = floor((600+24)/274) = 2
    static let tiny: Double = 300   // fit = floor((300+24)/274) = 1

    @Test func balancesFourToTwoPlusTwoWhenWide() {
        // 4 → 2 columns (2+2), never a lone row of 1.
        #expect(PaceColumnLayout.columnCount(itemCount: 4, availableWidth: Self.wide) == 2)
    }

    @Test func balancesFiveToThreePlusTwoWhenWide() {
        // 5 → 3 columns (3+2).
        #expect(PaceColumnLayout.columnCount(itemCount: 5, availableWidth: Self.wide) == 3)
    }

    @Test func balancesSixToThreePlusThreeWhenWide() {
        // 6 → 3 columns (3+3).
        #expect(PaceColumnLayout.columnCount(itemCount: 6, availableWidth: Self.wide) == 3)
    }

    @Test func dropsToTwoColumnsWhenNarrow() {
        // At a narrower width only 2 fit: 4→2 (2+2), 5→2 (2+2+1), 6→2 (2+2+2).
        #expect(PaceColumnLayout.columnCount(itemCount: 4, availableWidth: Self.narrow) == 2)
        #expect(PaceColumnLayout.columnCount(itemCount: 5, availableWidth: Self.narrow) == 2)
        #expect(PaceColumnLayout.columnCount(itemCount: 6, availableWidth: Self.narrow) == 2)
    }

    @Test func collapsesToOneColumnWhenTiny() {
        // Only one item fits across ⇒ single column, stacked.
        #expect(PaceColumnLayout.columnCount(itemCount: 4, availableWidth: Self.tiny) == 1)
        #expect(PaceColumnLayout.columnCount(itemCount: 6, availableWidth: Self.tiny) == 1)
    }

    @Test func neverExceedsItemCountOrFit() {
        // A very wide pane never invents more columns than there are items.
        #expect(PaceColumnLayout.columnCount(itemCount: 3, availableWidth: 5000) == 3)
        // The ≤2 case isn't rendered through this path (the view uses an
        // HStack), but the math is still well-defined and non-crashing.
        #expect(PaceColumnLayout.columnCount(itemCount: 2, availableWidth: Self.wide) == 2)
        #expect(PaceColumnLayout.columnCount(itemCount: 0, availableWidth: Self.wide) == 1)
    }

    @Test func sevenBalancesToFourPlusThreeWhenRoomy() {
        // 7 with room for 4 across → 4 columns (4+3), no orphan.
        // width fitting 4: floor((w+24)/274)=4 ⇒ w in [1072, 1346); use 1150.
        #expect(PaceColumnLayout.columnCount(itemCount: 7, availableWidth: 1150) == 4)
    }

    // MARK: - Scoped ordering side

    static let fiveH: TimeInterval = 5 * 3600
    static let sevenD: TimeInterval = 7 * 86_400

    @Test func sessionGroupSnapsAheadOfFiveHour() {
        let side = PaceColumnLayout.scopedSide(
            group: "session", duration: Self.fiveH,
            fiveHourDuration: Self.fiveH, sevenDayDuration: Self.sevenD)
        #expect(side == .sessionScoped)
        #expect(side < .fiveHour)
    }

    @Test func weeklyGroupSnapsAfterSevenDay() {
        let side = PaceColumnLayout.scopedSide(
            group: "weekly", duration: Self.sevenD,
            fiveHourDuration: Self.fiveH, sevenDayDuration: Self.sevenD)
        #expect(side == .weeklyScoped)
        #expect(side > .sevenDay)
    }

    @Test func unknownGroupFallsBackToPeriod() {
        // Short unknown-group window ⇒ session side.
        #expect(PaceColumnLayout.scopedSide(
            group: "mystery", duration: 3 * 3600,
            fiveHourDuration: Self.fiveH, sevenDayDuration: Self.sevenD) == .sessionScoped)
        // ~weekly-length unknown-group window ⇒ weekly side.
        #expect(PaceColumnLayout.scopedSide(
            group: "mystery", duration: Self.sevenD,
            fiveHourDuration: Self.fiveH, sevenDayDuration: Self.sevenD) == .weeklyScoped)
        // Longer-than-7d unknown-group window ⇒ trailing bucket.
        #expect(PaceColumnLayout.scopedSide(
            group: "monthly", duration: 30 * 86_400,
            fiveHourDuration: Self.fiveH, sevenDayDuration: Self.sevenD) == .otherScoped)
    }

    @Test func fixedHeroesAreAlwaysAdjacent() {
        // Nothing sorts strictly between the two heroes: no `Side` value v
        // satisfies fiveHour < v < sevenDay.
        let between = PaceColumnLayout.Side.allSidesForTest.filter {
            $0 > .fiveHour && $0 < .sevenDay
        }
        #expect(between.isEmpty)
    }
}

private extension PaceColumnLayout.Side {
    static var allSidesForTest: [PaceColumnLayout.Side] {
        [.sessionScoped, .fiveHour, .sevenDay, .weeklyScoped, .otherScoped]
    }
}
