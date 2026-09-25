import Foundation

/// What the threshold alerts remember between evaluations: the last reading of
/// every window they have seen, and today's cost.
///
/// A crossing is judged against the previous reading, so that reading has to
/// outlive any one evaluator. It used to live in `@State` on an invisible view
/// inside the main window. A menu-bar-only session evaluated nothing, and
/// reopening the window re-seeded it from current data, silently swallowing
/// whatever had crossed while it was closed (#143). Persisted, each reading is
/// judged exactly once whatever is on screen, and a crossing that happened
/// while Pacer was not running is caught on the next evaluation.
///
/// Keys are `"<accountId>|<window>"` for the fixed windows and
/// `"<accountId>|<identity>"` for scoped ones: two logins have independent
/// utilisation and independent cycles.
public struct AlertCrossingState: Codable, Equatable, Sendable {
    struct Reading: Codable, Equatable, Sendable {
        var percent: Double
        var resetsAt: Date?
        var sampledAt: Date
    }

    private var readings: [String: Reading] = [:]
    private var dailyCost: Double?
    private var dailyCostDate: String?

    public init() {}

    /// The previous reading a new one is judged against.
    public struct Step: Equatable, Sendable {
        public let previousPercent: Double
        public let previousResetsAt: Date?
    }

    /// Record the newest reading for `key`.
    ///
    /// - Returns: the previous reading to judge this one against, or nil when
    ///   there is nothing to judge: the reading is not newer than one already
    ///   recorded, or it is the first ever seen for this key. A first reading
    ///   is recorded silently, so a window that is already over a threshold
    ///   when Pacer first sees it does not fire; it fires on its next crossing.
    ///   `RateLimitThresholdPolicy` reads a missing previous value as 0, so
    ///   passing nil through would fire every threshold the window is past.
    public mutating func advance(
        _ key: String, percent: Double, resetsAt: Date?, sampledAt: Date
    ) -> Step? {
        let previous = readings[key]
        if let previous, previous.sampledAt >= sampledAt { return nil }
        readings[key] = Reading(percent: percent, resetsAt: resetsAt, sampledAt: sampledAt)
        guard let previous else { return nil }
        return Step(previousPercent: previous.percent, previousResetsAt: previous.resetsAt)
    }

    /// Record today's cost, and say whether it rose.
    ///
    /// That is the gate the daily-cost alert has always had, so the first sight
    /// of a day already over its threshold does not fire. A new day starts from
    /// zero, so its first spend counts as a rise; a first-ever reading records
    /// silently.
    public mutating func advanceDailyCost(_ cost: Double, date: String) -> Bool {
        let previous: Double? = dailyCostDate == date ? dailyCost : (dailyCostDate == nil ? nil : 0)
        dailyCost = cost
        dailyCostDate = date
        guard let previous else { return false }
        return cost > previous
    }

    /// For persisting between launches.
    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    /// A state read back from `encoded()`, or a fresh one when there is none
    /// or it cannot be read.
    public init(data: Data?) {
        self = data.flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }
}
