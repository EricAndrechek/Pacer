import Foundation

/// Pure layout arithmetic for the dashboard's rate-limit pace card — the two
/// decisions that arrange its columns, factored out of the SwiftUI view so
/// they're deterministic and unit-testable:
///
///   1. **Ordering** (`Side` + `scopedSide`): where a window sits in the run so
///      the account-wide 5-hour and 7-day heroes stay glued together, with
///      session-cadence scoped windows ahead of them and weekly-cadence (or
///      longer) scoped windows behind — a scoped per-model cap never lands
///      *between* 5h and 7d.
///   2. **Balancing** (`columnCount`): how many columns the responsive grid
///      uses at a given width, spread so rows stay even (4→2+2, 5→3+2, 6→3+3)
///      and drop as the pane narrows (6→2+2+2), never crushing 4+ windows into
///      a too-narrow row nor leaving an avoidable orphan last row of one.
public enum PaceColumnLayout {

    /// Where a pace column sits in the sorted run. The raw values ARE the sort
    /// key, so a plain `<` on `Side` orders the whole card: scoped session
    /// windows, then the fixed 5h, then the fixed 7d, then scoped weekly
    /// windows, then any longer/other scoped window. Because `fiveHour` and
    /// `sevenDay` are adjacent ranks with nothing that can sort between them,
    /// the two heroes are always rendered back-to-back.
    public enum Side: Int, Comparable, Sendable {
        /// Scoped window on the session (~5-hour) side — rendered before 5h.
        case sessionScoped = 0
        /// The account-wide fixed 5-hour block.
        case fiveHour = 1
        /// The account-wide fixed 7-day block.
        case sevenDay = 2
        /// Scoped window on the weekly (~7-day) side — rendered after 7d.
        case weeklyScoped = 3
        /// Scoped window whose period is longer than / unlike 7d — trailing.
        case otherScoped = 4

        public static func < (lhs: Side, rhs: Side) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Snap a scoped window to its ordering `Side` using the server `group`
    /// hint first (`session`/`weekly`), falling back to its period compared
    /// against the fixed 5h/7d durations when the group is an unrecognised
    /// word — so nothing ever lands between the two heroes:
    ///   - shorter than the weekly-scale threshold (a day) ⇒ session side;
    ///   - up to and including the 7-day period ⇒ weekly side;
    ///   - longer than 7 days ⇒ the trailing "other" bucket.
    public static func scopedSide(
        group: String,
        duration: TimeInterval,
        fiveHourDuration: TimeInterval,
        sevenDayDuration: TimeInterval
    ) -> Side {
        switch group.lowercased() {
        case "session": return .sessionScoped
        case "weekly":  return .weeklyScoped
        default:
            if duration < WindowSpec.weeklyScaleThreshold { return .sessionScoped }
            if duration <= sevenDayDuration { return .weeklyScoped }
            return .otherScoped
        }
    }

    /// Balanced, width-aware column count for the N-window pace grid.
    ///
    /// `fit` is how many `minItemWidth`-wide items actually fit on one row at
    /// `availableWidth` (accounting for inter-item `spacing`). Balancing then
    /// spreads the items across the fewest rows that many columns allows and
    /// pulls the column count back to the minimum those rows need — which is
    /// what turns 4→2+2 and 5→3+2 rather than 3+1 / 4+1 orphans, and keeps the
    /// grid dropping columns (6→2+2+2) instead of overflowing as width shrinks.
    ///
    /// Callers use this only for `itemCount > 2`; the 5h/7d-only case keeps its
    /// original two-column `HStack`.
    public static func columnCount(
        itemCount: Int,
        availableWidth: Double,
        minItemWidth: Double = 250,
        spacing: Double = 24
    ) -> Int {
        guard itemCount > 0 else { return 1 }
        guard availableWidth > 0, minItemWidth > 0 else { return 1 }
        // floor: how many min-width items fit across — N items share (N-1)
        // gaps, i.e. (width + spacing) / (item + spacing).
        let fit = Int((availableWidth + spacing) / (minItemWidth + spacing))
        let maxCols = max(1, min(fit, itemCount))
        let rows = Int((Double(itemCount) / Double(maxCols)).rounded(.up))
        let cols = Int((Double(itemCount) / Double(max(1, rows))).rounded(.up))
        return max(1, cols)
    }
}
