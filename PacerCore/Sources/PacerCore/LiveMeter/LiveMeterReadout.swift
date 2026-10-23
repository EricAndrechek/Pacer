import Foundation

/// What a surface shows as one window's current %: the live meter's value
/// when there is one for the reading it holds, else that reading (#318).
///
/// Every surface that shows a window's current % (the menu bar, the window
/// title, the pace card, the model comparison, the widgets) goes through
/// this, from plain values, so no two of them can disagree about which
/// number is current. A surface holds its own reading, loaded on its own
/// signal; the live value comes from `LiveMeterBoard` (or, in the widget
/// extension, straight from `LiveMeterSource`). The two can be a moment
/// apart, and the rules below say which wins.
public struct LiveMeterReadout: Sendable, Equatable {

    /// The reading the number starts from: the surface's, or the live
    /// value's when that one is newer.
    public let reading: MeterReading
    /// The live value, when it applies to that reading at `now`.
    public let live: LiveMeterValue?

    /// A live value built on a reading older than the surface's by more than
    /// this is from before the latest poll and is set aside: a new reading
    /// replaces the estimate. Exact instants match in practice (the reading,
    /// the account's cached copy and the live value's all carry the poll's
    /// `sampledAt`); this only absorbs a rounding of the stored date.
    static let sameReadingTolerance: TimeInterval = 1

    /// - Parameters:
    ///   - reading: what the surface itself loaded.
    ///   - live: the shared live value for the same account and window.
    ///   - now: the moment shown, for the age and reset rules.
    public init(reading: MeterReading, live: LiveMeterValue?, now: Date) {
        guard let live,
              live.reading.at >= reading.at.addingTimeInterval(-Self.sameReadingTolerance),
              // Readings stopped: the estimate runs an hour, then the reading
              // stands alone (`LiveMeter.maxReadingAge`).
              now.timeIntervalSince(live.reading.at) <= LiveMeter.maxReadingAge,
              // Built before its window reset: that window is over, and the
              // number for the new one is the next value's to give.
              live.restarted || (live.reading.resetsAt.map { $0 > now } ?? true)
        else {
            self.reading = reading
            self.live = nil
            return
        }
        self.reading = live.reading.at > reading.at ? live.reading : reading
        self.live = live
    }

    /// The number to show.
    public var percent: Double { live?.percent ?? reading.percent }

    /// Whether the number is something other than the reading.
    public var differsFromReading: Bool {
        guard let live else { return false }
        return live.restarted || live.percent != reading.percent
    }

    /// The hover text on the number: "read 42% 3 min ago · live 45%". Nil
    /// when the number is the reading.
    public func help(now: Date) -> String? {
        guard let live, differsFromReading else { return nil }
        let read = "read \(Self.whole(reading.percent))% \(Self.ago(reading.at, now: now))"
        let reset = live.restarted ? ", reset since" : ""
        return "\(read)\(reset) · live \(Self.whole(live.percent))%"
    }

    static func whole(_ v: Double) -> String { String(Int(v.rounded())) }

    /// "just now", "1 min ago", "42 min ago", "1 hr ago". A reading behind a
    /// live value is at most an hour old.
    static func ago(_ at: Date, now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(at)) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        return "\(minutes / 60) hr ago"
    }
}
