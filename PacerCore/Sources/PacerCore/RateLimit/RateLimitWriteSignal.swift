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

    public private(set) var newest: Date?

    private init() {}

    /// Record a write. Never moves backwards, so an archive fold of old rows
    /// finishing after a fresh poll does not un-signal the poll.
    public func note(_ sampledAt: Date) {
        if let newest, newest >= sampledAt { return }
        newest = sampledAt
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
        if let at = (try? context.fetch(fixed))?.first?.sampledAt { note(at) }
        if let at = (try? context.fetch(scoped))?.first?.sampledAt { note(at) }
    }
}
