import Foundation

/// A compact, JSON-codable export of the engine's current rate-limit outlook,
/// written into `ClaudeCodeMeta` after every refit.
///
/// Why it exists: the widgets run in a separate process and read the shared
/// store directly — they can't reach the in-app engine actor, and running a
/// ~0.5s refit inside a WidgetKit timeline budget is a non-starter. The app
/// exports this snapshot instead, so the widget's pace chart can draw the
/// same dashed trajectory and outlook caption the dashboard shows, from the
/// same fitted models.
public struct EngineSnapshot: Codable, Sendable, Equatable {

    public struct TrajectoryPoint: Codable, Sendable, Equatable {
        /// Unix seconds — Codable-stable and timezone-free.
        public let t: Double
        public let v: Double
        public init(t: Double, v: Double) { self.t = t; self.v = v }
    }

    public struct WindowOutlook: Codable, Sendable, Equatable {
        public let usedPct: Double
        /// Projected utilization at the window reset, with its calibrated band.
        public let endPct: Double?
        public let endLoPct: Double?
        public let endHiPct: Double?
        /// Projected pre-reset 100% crossing (unix seconds), nil = none.
        public let crossingUnix: Double?
        public let resetsUnix: Double
        /// The selected model's forward trajectory, downsampled and truncated
        /// at the crossing — ready for `PaceChartView`'s projection overlay.
        public let trajectory: [TrajectoryPoint]

        public init(usedPct: Double, endPct: Double?, endLoPct: Double?, endHiPct: Double?,
                    crossingUnix: Double?, resetsUnix: Double, trajectory: [TrajectoryPoint]) {
            self.usedPct = usedPct
            self.endPct = endPct
            self.endLoPct = endLoPct
            self.endHiPct = endHiPct
            self.crossingUnix = crossingUnix
            self.resetsUnix = resetsUnix
            self.trajectory = trajectory
        }

        public var crossingDate: Date? { crossingUnix.map { Date(timeIntervalSince1970: $0) } }
        public var resetsDate: Date { Date(timeIntervalSince1970: resetsUnix) }
    }

    /// One scoped per-model window's outlook, exported so out-of-process
    /// readers (widgets) can surface the same projected-fill/crossing the
    /// dashboard tiles show, keyed by the `limits[]` identity so a reader can
    /// match it to a live row. `isActive` flags the binding limit in its group.
    public struct ScopedWindowOutlook: Codable, Sendable, Equatable {
        public let identity: String
        public let displayName: String
        public let group: String
        public let isActive: Bool
        public let outlook: WindowOutlook

        public init(identity: String, displayName: String, group: String,
                    isActive: Bool, outlook: WindowOutlook) {
            self.identity = identity
            self.displayName = displayName
            self.group = group
            self.isActive = isActive
            self.outlook = outlook
        }
    }

    /// The engine's cost projection + pace read, exported so out-of-process
    /// readers (widgets, the Shortcuts intents) can surface the same
    /// projected-spend and "running hot / quieter than usual" the dashboard
    /// shows without reaching the in-app engine actor. All fields are optional
    /// — `nil` means the engine hasn't enough history to answer that question.
    public struct CostOutlook: Codable, Sendable, Equatable {
        /// Projected end-of-day spend (USD) with its calibrated 80% band.
        public let projectedTodayUSD: Double?
        public let projectedTodayLoUSD: Double?
        public let projectedTodayHiUSD: Double?
        /// Projected end-of-month spend (USD) with its 80% band.
        public let projectedMonthUSD: Double?
        public let projectedMonthLoUSD: Double?
        public let projectedMonthHiUSD: Double?
        /// Today's projected spend as a percentile of the user's own daily
        /// norm (0…1). 0.82 = "heavier than 82% of your days".
        public let pacePercentile: Double?
        /// Human descriptor for `pacePercentile`:
        /// "quieter than usual" / "about normal" / "running hot".
        public let paceNote: String?

        public init(projectedTodayUSD: Double?, projectedTodayLoUSD: Double?, projectedTodayHiUSD: Double?,
                    projectedMonthUSD: Double?, projectedMonthLoUSD: Double?, projectedMonthHiUSD: Double?,
                    pacePercentile: Double?, paceNote: String?) {
            self.projectedTodayUSD = projectedTodayUSD
            self.projectedTodayLoUSD = projectedTodayLoUSD
            self.projectedTodayHiUSD = projectedTodayHiUSD
            self.projectedMonthUSD = projectedMonthUSD
            self.projectedMonthLoUSD = projectedMonthLoUSD
            self.projectedMonthHiUSD = projectedMonthHiUSD
            self.pacePercentile = pacePercentile
            self.paceNote = paceNote
        }
    }

    public let generatedUnix: Double
    public let fiveHour: WindowOutlook?
    public let sevenDay: WindowOutlook?
    /// Optional so snapshots written before this field existed still decode
    /// (a missing key → `nil` via the synthesized `decodeIfPresent`).
    public let cost: CostOutlook?
    /// Scoped per-model windows' outlooks (empty/nil when none). Optional +
    /// defaulted so snapshots written before this field existed still decode.
    public let scoped: [ScopedWindowOutlook]?

    public init(generatedUnix: Double, fiveHour: WindowOutlook?, sevenDay: WindowOutlook?,
                cost: CostOutlook? = nil, scoped: [ScopedWindowOutlook]? = nil) {
        self.generatedUnix = generatedUnix
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.cost = cost
        self.scoped = scoped
    }

    /// `ClaudeCodeMeta` key the snapshot is stored under.
    public static let metaKey = "engineOutlookSnapshot"

    /// Snapshots older than this are ignored by readers (the app may not be
    /// running; a stale projection is worse than none).
    public static let maxAge: TimeInterval = 30 * 60

    public var isFresh: Bool {
        Date().timeIntervalSince1970 - generatedUnix < Self.maxAge
    }

    public func encodedJSON() -> String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func decode(_ json: String) -> EngineSnapshot? {
        json.data(using: .utf8).flatMap { try? JSONDecoder().decode(EngineSnapshot.self, from: $0) }
    }
}
