import Foundation
import SwiftData

/// The readings a window's `RecentBurn` reads from the store, kept between
/// snapshot builds (#358).
///
/// A weekly window's burn reaches back 16.8 hours (`RecentBurn.lookbackLimit`),
/// about 2,400 rows a window on an account polled every 25 seconds. Read on
/// every build, the weekly and per-model reads took the snapshot's `limits`
/// from 3–5 ms to 400–600 ms (a synthetic store at that cadence, debug build,
/// a loaded Mac), and the API rebuilds it every few seconds. So the reach is
/// read whole once; after that each build reads only the last
/// `RecentBurn.defaultLookback`, which replaces what is held for that
/// stretch: 9–10 ms a build on the same store. The half hour the burn
/// measures first is always the store's own, and only the older ticks come
/// from here.
///
/// The whole reach is read again every `rereadEvery`, which picks up a row
/// written late with an older time (an archive fold) and lets go of rows
/// that have left the store, and whenever the last read is too far back for
/// the fresh stretch to meet it. Held per container, weakly, so a new store
/// (a test's, the CLI's) never sees another's rows.
///
/// A window whose reach is the half hour itself (the 5-hour one) is read
/// directly: there is nothing older to keep.
final class RecentBurnHistory: @unchecked Sendable {

    static let shared = RecentBurnHistory()

    /// How often the whole reach is read again.
    static let rereadEvery: TimeInterval = 10 * 60

    /// The furthest the last read may be behind `now` for the fresh stretch
    /// to still overlap it, with room for rows written a little late.
    static let maxGap: TimeInterval = RecentBurn.defaultLookback / 2

    /// One reading and the window it is of: a fixed window's name, or a
    /// scoped window's identity.
    struct Row: Sendable, Equatable {
        let identity: String
        let reading: RecentBurn.Reading
    }

    private struct Key: Hashable {
        let account: String?
        /// A fixed window's name, or nil for every scoped window at once.
        let window: String?
    }

    private struct Entry {
        weak var container: ModelContainer?
        /// Oldest first.
        var rows: [Row]
        var reach: TimeInterval
        var wholeReadAt: Date
        var lastNow: Date
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]

    /// One fixed window's readings back to its `RecentBurn.lookbackLimit`.
    func fixed(context: ModelContext, account: String?, window: String,
               duration: TimeInterval, now: Date) -> [RecentBurn.Reading] {
        rows(context: context, key: Key(account: account, window: window),
             reach: RecentBurn.lookbackLimit(duration: duration), now: now) { since in
            var d = LimitScope.rateLimits(account: account, window: window, since: since,
                                          limit: Self.fetchLimit)
            d.propertiesToFetch = [\.sampledAt, \.usedPercentage, \.resetsAt]
            return ((try? context.fetch(d)) ?? []).map {
                Row(identity: window,
                    reading: .init(at: $0.sampledAt, percent: $0.usedPercentage, resetsAt: $0.resetsAt))
            }
        }.map(\.reading)
    }

    /// Every model-scoped window's readings back to `reach`, by identity.
    func scoped(context: ModelContext, account: String?, reach: TimeInterval,
                now: Date) -> [String: [RecentBurn.Reading]] {
        let rows = rows(context: context, key: Key(account: account, window: nil),
                        reach: reach, now: now) { since in
            var d = LimitScope.modelScopedLimits(account: account, since: since, limit: Self.fetchLimit)
            d.propertiesToFetch = [\.identity, \.sampledAt, \.percent, \.resetsAt]
            return ((try? context.fetch(d)) ?? []).map {
                Row(identity: $0.identity,
                    reading: .init(at: $0.sampledAt, percent: $0.percent, resetsAt: $0.resetsAt))
            }
        }
        return Dictionary(grouping: rows, by: \.identity).mapValues { $0.map(\.reading) }
    }

    /// Backstop on one read, far above what the pollers write: a lane every
    /// 10 s for 16.8 hours is about 6,000 rows. Past it the read keeps the
    /// newest rows, and the burn reaches back less far.
    static let fetchLimit = 16_384

    /// The rows since `now − reach`, oldest first. `read` returns every row
    /// since the date it is given.
    private func rows(context: ModelContext, key: Key, reach: TimeInterval, now: Date,
                      read: (Date) -> [Row]) -> [Row] {
        let since = now.addingTimeInterval(-reach)
        let fresh = now.addingTimeInterval(-RecentBurn.defaultLookback)
        guard since < fresh else { return Self.oldestFirst(read(since)) }
        let container = context.container
        lock.lock()
        let held = entries[key]
        lock.unlock()
        let entry: Entry
        if let held, held.container === container, held.reach == reach,
           now >= held.lastNow, now.timeIntervalSince(held.lastNow) <= Self.maxGap,
           now.timeIntervalSince(held.wholeReadAt) < Self.rereadEvery {
            let older = held.rows.filter { $0.reading.at >= since && $0.reading.at < fresh }
            entry = Entry(container: container, rows: older + Self.oldestFirst(read(fresh)),
                          reach: reach, wholeReadAt: held.wholeReadAt, lastNow: now)
        } else {
            entry = Entry(container: container, rows: Self.oldestFirst(read(since)),
                          reach: reach, wholeReadAt: now, lastNow: now)
        }
        lock.lock()
        entries[key] = entry
        lock.unlock()
        return entry.rows
    }

    /// The reads come newest first. Same-instant ties are `RecentBurn`'s to
    /// order (`RecentBurn.ascending`).
    private static func oldestFirst(_ rows: [Row]) -> [Row] {
        rows.reversed()
    }
}
