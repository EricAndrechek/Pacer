import SwiftUI
import PacerCore

/// How old something is, said one way everywhere (#318): "just now", "3m ago",
/// "1h ago", "2d ago".
///
/// **One formatter.** Every "read 3m ago" (the pace card's caption under each
/// number, the stale caption, the page's freshness line, the comparison
/// sheet's live line), the dashboard strip's "last sample 3m ago", the
/// toolbar's freshness pill, the hover on a window's number and the menu
/// bar's tooltip all go through `string(_:now:)` or `text(_:now:)`.
///
/// **One schedule.** In the app every label is drawn on `Schedule`: the whole
/// minutes of the wall clock. Every age on screen, and the hover or tooltip
/// beside it, changes at the same instant, once a minute at most, and nothing
/// ticks per second. A hover (`.help`) or an AppKit tooltip is a plain string
/// and cannot keep itself current; built on the same instants as the label,
/// it always says the same words. Labels used to keep themselves current with
/// SwiftUI's time-driven text, each on its own instants, so two cards reading
/// the same poll a few seconds apart changed a few seconds apart.
///
/// **Minutes, rounded.** "3m ago" is 2.5 to 3.5 minutes, the same rounding
/// SwiftUI's and Foundation's own relative styles use, so the widgets (which
/// cannot run a schedule and use the self-updating text) say the same number.
///
/// **The style is one line.** `style` switches every label at once to
/// SwiftUI's `Text(date, style: .relative)` ("3 min, 12 sec", updating every
/// second) or to its long-form `.reference(to:)` ("3 minutes ago", updating
/// itself). Hovers and tooltips stay on the schedule in every style.
public enum PacerReadAge {

    public enum Style: Sendable {
        /// "3m ago", drawn on `Schedule`.
        case short
        /// `Text(date, style: .relative)`: "3 min, 12 sec ago", self-updating.
        case relative
        /// `Text(.currentDate, format: .reference(to:))`: "3 minutes ago",
        /// self-updating.
        case reference
    }

    /// The one switch for every age label in the app and the widgets.
    public static let style: Style = .short

    /// Under half a minute rounds to no minutes at all.
    static let justNow = "just now"

    /// The words for `at`'s age as of `now`.
    public static func string(_ at: Date, now: Date = PacerClock.now,
                              locale: Locale = .autoupdatingCurrent) -> String {
        switch style {
        case .short:
            // A future `at` (clock skew between the poll and this Mac) is as
            // fresh as anything gets.
            guard now.timeIntervalSince(at) >= 30 else { return justNow }
            return shortStyle(at, locale: locale).format(now)
        case .relative:
            let range = min(at, now)..<max(at, now)
            return range.formatted(.components(style: .abbreviated, fields: [.day, .hour, .minute, .second]))
                + " ago"
        case .reference:
            return String(referenceStyle(at).locale(locale).format(now).characters)
        }
    }

    /// The age as a `Text`, for a label drawn on `Schedule` with that
    /// schedule's date as `now`. In the two SwiftUI styles it keeps itself
    /// current between the schedule's instants.
    public static func text(_ at: Date, now: Date) -> Text {
        switch style {
        case .short:     return Text(verbatim: string(at, now: now))
        case .relative:  return Text("\(Text(at, style: .relative)) ago")
        case .reference: return Text(.currentDate, format: referenceStyle(at))
        }
    }

    /// The age for a widget, which cannot run a schedule: text that keeps
    /// itself current between timeline refreshes. In the README screenshot
    /// build the widget clock is pinned (`PacerClock`) and the system's
    /// self-updating text would read the real clock, so there the words are
    /// written out as of the pinned instant instead (#154).
    public static func widgetText(_ at: Date) -> Text {
        guard PacerClock.pinned == nil else { return Text(verbatim: string(at, now: PacerClock.now)) }
        switch style {
        case .short:
            // The short style's own words, kept current by the system. Under
            // half a minute it says "this minute": the self-updating style has
            // no "just now".
            var named = shortStyle(at)
            named.presentation = .named
            return Text(.currentDate, format: named)
        case .relative, .reference:
            return text(at, now: PacerClock.now)
        }
    }

    /// `prefix` then the age, on the schedule: "read 3m ago".
    @MainActor
    public static func label(_ prefix: String, _ at: Date,
                             help: ((Date) -> String)? = nil) -> PacerAgeLabel {
        PacerAgeLabel(at, help: help) { Text("\(prefix) \($0)") }
    }

    static func shortStyle(_ at: Date, locale: Locale = .autoupdatingCurrent) -> Date.AnchoredRelativeFormatStyle {
        Date.AnchoredRelativeFormatStyle(anchor: at, allowedFields: [.day, .hour, .minute],
                                         presentation: .numeric, unitsStyle: .narrow, locale: locale)
    }

    static func referenceStyle(_ at: Date) -> SystemFormatStyle.DateReference {
        SystemFormatStyle.DateReference(to: at, allowedFields: [.day, .hour, .minute], maxFieldCount: 1)
    }

    /// The next instant the shared schedule fires after `date`: the next
    /// whole minute of the wall clock. Time zones are offset from UTC by
    /// whole minutes, so the epoch's minutes are every zone's minutes.
    public static func nextChange(after date: Date) -> Date {
        Date(timeIntervalSince1970: ((date.timeIntervalSince1970 / 60).rounded(.down) + 1) * 60)
    }

    /// The one schedule every age label, countdown and the hover beside each
    /// is drawn on: the moment the view appears, then each whole minute of
    /// the wall clock. Use it as `TimelineView(PacerReadAge.Schedule())` and
    /// pass the context's date as `now`.
    public struct Schedule: TimelineSchedule {
        public init() {}

        public func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
            Entries(upcoming: startDate)
        }

        public struct Entries: Sequence, IteratorProtocol {
            var upcoming: Date?

            public mutating func next() -> Date? {
                guard let current = upcoming else { return nil }
                upcoming = PacerReadAge.nextChange(after: current)
                return current
            }
        }
    }
}

/// A label whose words include an age, drawn on `PacerReadAge.Schedule`, with
/// its hover built on the same instant: "read 3m ago", "last sample 3m ago",
/// "Last activity 3m ago — Opus 4.7."
///
/// `content` gets the age as a `Text` (`PacerReadAge.text`) and returns the
/// whole label; `help` gets the schedule's date and returns the hover.
public struct PacerAgeLabel: View {
    let at: Date
    let help: ((Date) -> String)?
    let content: (Text) -> Text

    public init(_ at: Date, help: ((Date) -> String)? = nil, _ content: @escaping (Text) -> Text) {
        self.at = at
        self.help = help
        self.content = content
    }

    public var body: some View {
        TimelineView(PacerReadAge.Schedule()) { context in
            content(PacerReadAge.text(at, now: context.date))
                .modifier(PacerOptionalHelp(text: help?(context.date)))
        }
    }
}

/// `.help` only when there is something to say, so a caller's own `.help`
/// outside the view is not covered by an empty one.
struct PacerOptionalHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text { content.help(text) } else { content }
    }
}
