import SwiftUI
import PacerCore

/// How old a reading is, said one way everywhere (#318): "now",
/// "1 minute ago", "3 minutes ago", "1 hour ago".
///
/// **One formatter.** The account header's "read 3 minutes ago", the stale
/// caption, the page's freshness line, the comparison sheet's live line, the
/// hover on a window's number and the menu bar's tooltip all go through
/// `style(_:)`. The pace card's label and its number's hover used to be built
/// by two formatters on two clocks about two readings, and said 8 and 9
/// minutes about what read as the same reading.
///
/// **Self-updating where SwiftUI can do it.** `label` is SwiftUI's own
/// time-driven text (`Text(.currentDate, format:)`): it redraws itself when
/// its words change, with nothing in the view ticking. A hover (`.help`) or
/// an AppKit tooltip is a plain string and cannot do that, so those are built
/// from `string(_:)` on `Schedule`, which fires at exactly the instants the
/// label's words change. A label and the hover beside it therefore change
/// together.
public enum PacerReadAge {

    /// Minutes, hours, days, one field: "3 minutes ago", not "3 minutes, 12
    /// seconds ago". No seconds: a label that changes every second for the
    /// first minute after each reading (every 30 s on a busy account) is a
    /// dashboard redrawing once a second for nothing.
    public static func style(_ at: Date) -> SystemFormatStyle.DateReference {
        SystemFormatStyle.DateReference(to: at, allowedFields: [.day, .hour, .minute], maxFieldCount: 1)
    }

    /// The same words as `label`, as of `now`.
    public static func string(_ at: Date, now: Date = PacerClock.now) -> String {
        String(style(at).format(now).characters)
    }

    /// `prefix` then the age, kept current by SwiftUI: "read 3 minutes ago".
    public static func label(_ prefix: String, _ at: Date) -> Text {
        Text("\(prefix) \(.currentDate, format: style(at))")
    }

    /// The instants `label(_, at)` changes its words, for a `TimelineView`
    /// around a hover or a tooltip built from `string(_:)`.
    public struct Schedule: TimelineSchedule {
        let style: SystemFormatStyle.DateReference

        public init(_ at: Date) { style = PacerReadAge.style(at) }

        public func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
            Entries(upcoming: startDate, style: style)
        }

        public struct Entries: Sequence, IteratorProtocol {
            var upcoming: Date?
            let style: SystemFormatStyle.DateReference

            public mutating func next() -> Date? {
                guard let current = upcoming else { return nil }
                // Never later than a minute: a reading's age keeps changing
                // even where the style has no further change to report.
                let change = style.discreteInput(after: current) ?? current.addingTimeInterval(60)
                upcoming = Swift.max(current.addingTimeInterval(1), Swift.min(change, current.addingTimeInterval(60)))
                return current
            }
        }
    }
}
