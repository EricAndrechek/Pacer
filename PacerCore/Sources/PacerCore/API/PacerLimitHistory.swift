import Foundation
import SwiftData

/// The curve behind every rate-limit window: utilization over time, bucketed.
///
/// `/v1/snapshot` answers "where am I now" and the engine answers "where will I
/// end up". Neither lets a consumer *see the shape* — whether the last hour was
/// a steady climb or one enormous step, whether a window has already reset once
/// today, what its slope was before the run started. Pacer keeps every raw
/// sample (it never prunes them), so this is a read, not a new measurement.
///
/// **Levels, not rates.** Each point is the window's utilization as reported,
/// so a bucket reduces by taking its *last* sample rather than a mean or a max:
/// a mean smears the step across a reset, and a max hides one entirely.
///
/// **Resets are visible, never smoothed.** A window that rolled over inside the
/// range drops from 90% to 0% between two adjacent points, which is a real
/// event and not a gap to interpolate — and a consumer that fits a slope
/// across it gets a meaningless number. Every point carries a `cycle` index
/// that increments on each rollover, so segmenting is an integer comparison.
///
/// The index exists because the obvious alternative does not work: the
/// server's `resets_at` jitters by a few hundred milliseconds between polls,
/// so grouping by it exactly splits one cycle into as many groups as there
/// were polls. Membership goes through `RateLimitCycle` — within half a window
/// of each other is the same cycle — which is the same rule every chart in the
/// app uses.
public struct PacerLimitHistory: Codable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    /// The `?account=` this covers, echoed back; absent when it is the active
    /// login's (the default, matching `/v1/snapshot`).
    public let account: String?
    public let bucketSeconds: Int
    public let windows: [Window]

    public struct Window: Codable, Sendable {
        public let identity: String
        public let label: String
        public let group: String
        public let points: [Point]

        public init(identity: String, label: String, group: String, points: [Point]) {
            self.identity = identity
            self.label = label
            self.group = group
            self.points = points
        }
    }

    public struct Point: Codable, Sendable {
        /// Start of the bucket this sample was reduced into.
        public let at: Date
        public let usedPercent: Double
        /// Which cycle of this window the reading belongs to, counting from 0
        /// at the start of the range. A change between adjacent points is a
        /// reset — the one thing a consumer must not read as a slope.
        public let cycle: Int
        /// The rollover time as recorded. Informational: it drifts by
        /// milliseconds between polls, so segment on `cycle`, not on this.
        public let resetsAt: Date?

        public init(at: Date, usedPercent: Double, cycle: Int, resetsAt: Date?) {
            self.at = at
            self.usedPercent = usedPercent
            self.cycle = cycle
            self.resetsAt = resetsAt
        }
    }

    public func encodedJSON() throws -> String { try pacerAPIEncodedJSON(self) }
}

public enum PacerLimitHistoryBuilder {

    /// Default and bounds for the bucket width. 15 minutes is three of Pacer's
    /// ~5-minute polls — fine enough to see a burst, coarse enough that a day
    /// of history is 96 points.
    public static let defaultBucketSeconds = 900
    public static let minBucketSeconds = 60
    public static let maxBucketSeconds = 86_400

    /// `hours` is clamped to 1…720 (30 days) and `bucketSeconds` to the range
    /// above. `account` is a resolved rollup key, nil for the active login.
    public nonisolated static func history(hours: Int = 24,
                                           bucketSeconds: Int = defaultBucketSeconds,
                                           account: String? = nil,
                                           now: Date = Date()) throws -> PacerLimitHistory {
        try history(container: PacerStore.sharedModelContainer(), hours: hours,
                    bucketSeconds: bucketSeconds, account: account,
                    activeAccountId: UsageScope.storedActiveAccountId, now: now)
    }

    nonisolated static func history(container: ModelContainer, hours: Int,
                                    bucketSeconds: Int, account: String?,
                                    activeAccountId: String?,
                                    now: Date) throws -> PacerLimitHistory {
        let span = min(max(hours, 1), 720)
        let bucket = min(max(bucketSeconds, minBucketSeconds), maxBucketSeconds)
        let context = ModelContext(container)
        let limitAccount = account ?? activeAccountId
        let since = now.addingTimeInterval(-Double(span) * 3600)

        // Fixed blocks, from the same table the hero cards read.
        var series: [String: (label: String, group: String, points: [String: PacerLimitHistory.Point])] = [:]
        var order: [String] = []
        // Per-window cycle tracking: the reset each window is currently in, and
        // how many rollovers have been seen since the range began.
        var cycleAnchor: [String: Date] = [:]
        var cycleIndex: [String: Int] = [:]

        func record(identity: String, label: String, group: String, duration: TimeInterval,
                    at: Date, percent: Double, resetsAt: Date?) {
            let start = Date(timeIntervalSince1970:
                (at.timeIntervalSince1970 / Double(bucket)).rounded(.down) * Double(bucket))
            let key = String(Int(start.timeIntervalSince1970))
            if series[identity] == nil {
                series[identity] = (label, group, [:])
                order.append(identity)
                cycleIndex[identity] = 0
            }
            // A `nil` reset is the post-rollover 0%-used reading before the new
            // window re-anchors, so it belongs to whatever cycle is current
            // rather than starting one.
            if let resetsAt {
                if let anchor = cycleAnchor[identity] {
                    if RateLimitCycle.contains(sampleReset: resetsAt, resets: anchor,
                                               duration: duration) {
                        cycleAnchor[identity] = resetsAt   // absorb the drift
                    } else {
                        cycleIndex[identity] = (cycleIndex[identity] ?? 0) + 1
                        cycleAnchor[identity] = resetsAt
                    }
                } else {
                    cycleAnchor[identity] = resetsAt
                }
            }
            // Last write wins, and callers iterate ascending by sample time —
            // so the reading a bucket keeps is its latest, which is the only
            // honest reducer for a level.
            series[identity]?.points[key] = PacerLimitHistory.Point(
                at: start, usedPercent: percent,
                cycle: cycleIndex[identity] ?? 0, resetsAt: resetsAt)
        }

        let fixed = (try? context.fetch(
            LimitScope.rateLimits(account: limitAccount, since: since))) ?? []
        // Ascending, so "last write wins" inside a bucket is genuinely the
        // latest reading rather than whichever the fetch happened to return.
        for row in fixed.sorted(by: { $0.sampledAt < $1.sampledAt }) {
            let spec: WindowSpec? = row.window == RateLimitWindowName.fiveHour
                ? .fixed(.fiveHour)
                : (row.window == RateLimitWindowName.sevenDay ? .fixed(.sevenDay) : nil)
            record(identity: row.window,
                   label: spec?.displayName ?? row.window,
                   group: row.window == RateLimitWindowName.fiveHour ? "session" : "weekly",
                   duration: spec?.duration ?? 5 * 3600,
                   at: row.sampledAt, percent: row.usedPercentage, resetsAt: row.resetsAt)
        }

        let scoped = (try? context.fetch(
            LimitScope.modelScopedLimits(account: limitAccount, since: since))) ?? []
        for row in scoped.sorted(by: { $0.sampledAt < $1.sampledAt }) {
            record(identity: row.identity, label: row.label, group: row.group,
                   duration: WindowSpec.scopedDuration(group: row.group),
                   at: row.sampledAt, percent: row.percent, resetsAt: row.resetsAt)
        }

        let windows = order.compactMap { identity -> PacerLimitHistory.Window? in
            guard let entry = series[identity] else { return nil }
            return PacerLimitHistory.Window(
                identity: identity, label: entry.label, group: entry.group,
                points: entry.points.values.sorted { $0.at < $1.at })
        }
        return PacerLimitHistory(
            schemaVersion: 1, generatedAt: now,
            account: account.map(PacerUsageBuilder.publicKey),
            bucketSeconds: bucket,
            windows: windows.sorted { $0.identity < $1.identity })
    }

    /// Parse a `?bucket=` value: bare seconds, or `30s` / `15m` / `1h`.
    public static func parseBucket(_ raw: String?) -> Int {
        guard let raw, !raw.isEmpty else { return defaultBucketSeconds }
        let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let unit = trimmed.last
        let numeric = (unit.map { "smh".contains($0) } == true)
            ? String(trimmed.dropLast()) : trimmed
        guard let value = Int(numeric), value > 0 else { return defaultBucketSeconds }
        switch unit {
        case "m": return value * 60
        case "h": return value * 3600
        default:  return value
        }
    }
}
