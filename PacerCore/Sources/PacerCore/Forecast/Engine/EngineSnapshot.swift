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

    public let generatedUnix: Double
    public let fiveHour: WindowOutlook?
    public let sevenDay: WindowOutlook?

    public init(generatedUnix: Double, fiveHour: WindowOutlook?, sevenDay: WindowOutlook?) {
        self.generatedUnix = generatedUnix
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
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
