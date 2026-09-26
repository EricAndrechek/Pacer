import Foundation
import SwiftUI
import PacerCore

/// The pace chart's loaded 8-day series, kept per account across rebuilds.
///
/// The chart card is rebuilt on every scope change (`.id` on the account), so
/// its `@State` starts empty each time — which is what makes the switch
/// deterministic, and would otherwise make it slow: on this machine the work
/// account's 8-day window is **31,370 rows and 1,451 ms**, against 1,010 rows
/// and 59 ms for the personal one. Paying that again every time you flip back
/// to an account you were just looking at is the difference between a control
/// that feels instant and one that feels broken.
///
/// So the series live here instead, outside the view's lifetime, keyed by
/// account. Bounded by the number of accounts a person has — two, in the case
/// this was built for — and dropped wholesale when the app quits, which is the
/// right lifetime for an 8-day window that the incremental path keeps current
/// anyway.
@MainActor
@Observable
final class PaceSeriesCache {
    static let shared = PaceSeriesCache()

    struct Series {
        var fixed: [LimitSamplePoint] = []
        var scoped: [ScopedSamplePoint] = []
        /// The column set, cached with the series it belongs to — otherwise a
        /// flip back would show the right history under the wrong columns for
        /// a frame.
        var windows: [ScopedWindowRow] = []
        /// Newest row already loaded; `nil` means "never loaded", which is the
        /// only case that reads all 8 days.
        var loadedThrough: Date?
    }

    private var byAccount: [String: Series] = [:]

    /// The `RateLimitWriteSignal.historyGeneration` the cached series were read
    /// at. A fold or adoption adds rows older than anything cached, and a top-up
    /// only fetches newer ones, so a series cached before it would never show
    /// them. A changed generation drops the cache (#142).
    private var history: UInt64 = 0

    private func dropIfHistoryRewritten() {
        let current = RateLimitWriteSignal.shared.historyGeneration
        guard current != history else { return }
        history = current
        byAccount = [:]
    }

    /// `nil` (all accounts / no scope yet) needs a key of its own, and it must
    /// not collide with a real account id.
    private static func key(_ account: String?) -> String {
        account ?? "\u{0000}unscoped"
    }

    func series(for account: String?) -> Series {
        dropIfHistoryRewritten()
        return byAccount[Self.key(account)] ?? Series()
    }

    func store(_ series: Series, for account: String?) {
        dropIfHistoryRewritten()
        byAccount[Self.key(account)] = series
    }

    /// The accounts the card last drew for a picked scope, in order.
    ///
    /// The card's `init` reads this to rebuild its series before the first
    /// frame. It cannot ask the store which accounts exist — that is a
    /// `@Query`, and it has no value until after `init` — so without this a
    /// tab switch back to the dashboard drew "Loading history…" for a frame and
    /// then the charts, shoving every card below by ~550 pt, for data that was
    /// sitting right here the whole time.
    private var targetsByScope: [String: [(accountId: String?, label: String?)]] = [:]

    func lastTargets(forPickedScope scope: String?) -> [(accountId: String?, label: String?)]? {
        targetsByScope[Self.key(scope)]
    }

    func storeTargets(_ targets: [(accountId: String?, label: String?)], forPickedScope scope: String?) {
        targetsByScope[Self.key(scope)] = targets
    }
}
