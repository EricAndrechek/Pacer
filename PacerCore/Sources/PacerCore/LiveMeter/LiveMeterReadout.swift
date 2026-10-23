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

    /// Whether the number shown is the live meter's estimate rather than
    /// Anthropic's reading (`LiveMeterValue.isEstimate`).
    public var isEstimate: Bool { live?.isEstimate ?? false }

    /// The number to show: the estimate to one decimal, else the reading
    /// (`PacerMeterFormat`).
    public var percent: Double {
        guard let live, live.isEstimate else { return reading.percent }
        return live.shownPercent
    }

    /// Whole points, for what judges them (threshold alerts): the estimate's
    /// floored value, else the reading.
    public var wholePercent: Double { live?.percent ?? reading.percent }

    /// "42%" for a reading, "42.6%" for an estimate.
    public var text: String { PacerMeterFormat.percent(percent, isEstimate: isEstimate) }

    /// "read 42% 3 min. ago", always about `reading`; ", reset since" when
    /// the estimate restarted past that reading's reset. `age` nil leaves the
    /// age out ("read 42%"), for text compared rather than shown.
    ///
    /// `age` is the reading's age as the surface writes it everywhere else
    /// (`pacerRelative` in the app), so a hover and the "read 3 min. ago"
    /// label beside it can never disagree: one reading, one clock, one
    /// formatter.
    public func readText(age: String?) -> String {
        let read = "read \(PacerMeterFormat.percent(reading.percent, isEstimate: false))"
        let reset = (live?.isEstimate == true && live?.restarted == true) ? ", reset since" : ""
        return (age.map { "\(read) \($0)" } ?? read) + reset
    }

    /// The hover on the number: `readText`, and for an estimate the number
    /// it is: "read 42% 3 min. ago · estimate 42.6%".
    public func help(age: String) -> String {
        guard isEstimate else { return readText(age: age) }
        return "\(readText(age: age)) · estimate \(text)"
    }
}
