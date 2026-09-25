import Foundation
import Observation
import SwiftData

/// The newest `sampledAt` written to `RateLimitSample` or `UsageLimitSample`,
/// by any account — the "reload now" trigger for every view that draws
/// rate-limit history (pace chart, menu-bar label and popover, notifications).
///
/// Those views each used to hold two one-row `@Query`s for this. Cheap in
/// principle, but a `@Query` re-fetches on every store *save*, not when its
/// own table changes, and Pacer saves on every scan cycle: eight fetches on the
/// main thread per save, each waiting its turn on the store behind the scan.
/// A `sample` of the live app with the dashboard open put more main-thread time
/// in those getters than in anything else. This changes only when rows land.
///
/// Written by `OAuthPoller` after each save that inserted rows (the only writer
/// of either table), seeded once from the store at launch.
@MainActor
@Observable
public final class RateLimitWriteSignal {

    public static let shared = RateLimitWriteSignal()

    /// Bumped on **every** write — the value views key their reloads on.
    ///
    /// A generation, not a timestamp, because a timestamp misses writes: rows
    /// folded back from the archive or adopted as the active account are older
    /// than the newest live row, a poll for account B can be saved after A's
    /// later capture, and two accounts written in the same second collapse to
    /// one key once rounded. A counter changes every time, and a spurious
    /// reload is cheap where a missed one is a stale screen.
    public private(set) var generation: UInt64 = 0

    /// The newest `sampledAt` seen. Informational; never a reload key.
    public private(set) var newest: Date?

    private init() {}

    /// Record a write of rate-limit rows. `sampledAt` is the newest row in the
    /// write, when there is one.
    public func note(_ sampledAt: Date? = nil) {
        generation &+= 1
        if let sampledAt, newest.map({ sampledAt > $0 }) ?? true { newest = sampledAt }
    }

    /// The newest row already in the store, so the first reload after launch
    /// is keyed to real data rather than `nil`.
    public func seed(from context: ModelContext) {
        var fixed = FetchDescriptor<RateLimitSample>(
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)])
        fixed.fetchLimit = 1
        var scoped = FetchDescriptor<UsageLimitSample>(
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)])
        scoped.fetchLimit = 1
        note((try? context.fetch(fixed))?.first?.sampledAt)
        note((try? context.fetch(scoped))?.first?.sampledAt)
    }
}
