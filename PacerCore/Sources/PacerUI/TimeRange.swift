import Foundation
import PacerCore
import SwiftUI

/// Shared rolling-window selection used by Projects, Models, and any
/// future view that needs a "last N days" picker. Persists the user's
/// last choice across launches via App Group `UserDefaults` (the prior
/// per-view `@State` reset to "90 days" on every launch, which the user
/// flagged as annoying).
public enum TimeRange: String, CaseIterable, Identifiable {
    case sevenDays   = "7d"
    case thirtyDays  = "30d"
    case ninetyDays  = "90d"
    case oneYear     = "1y"
    case all         = "all"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .sevenDays:   return "7 days"
        case .thirtyDays:  return "30 days"
        case .ninetyDays:  return "90 days"
        case .oneYear:     return "1 year"
        case .all:         return "All time"
        }
    }

    /// Short label used in tighter pickers (e.g. the History summary
    /// card's segmented control). Same set of choices as `label` but
    /// dropped to two-character codes so all five fit in a narrow row.
    public var shortLabel: String {
        switch self {
        case .sevenDays:   return "7d"
        case .thirtyDays:  return "30d"
        case .ninetyDays:  return "90d"
        case .oneYear:     return "1y"
        case .all:         return "All"
        }
    }

    /// Days of history to include. `nil` means "everything ever recorded."
    public var days: Int? {
        switch self {
        case .sevenDays:   return 7
        case .thirtyDays:  return 30
        case .ninetyDays:  return 90
        case .oneYear:     return 365
        case .all:         return nil
        }
    }

    /// Where "the last N days" starts: local midnight of the first of
    /// exactly N calendar days, today and the N − 1 before it. `nil` for all
    /// time.
    ///
    /// The one definition every range cut reads (History, Projects, Models,
    /// the summary strip, the range's session counts), each as
    /// `date >= formatDate(since)` on the day rollups or `>= since` on an
    /// instant. It used to be `now − N days`, an instant part-way through a
    /// day: a date cut on it took that whole day too, so "7 days" read 8
    /// dates and the strip said "of 366 days" for a year (#342).
    public var since: Date? {
        since(now: PacerClock.now)
    }

    /// `since` at a given instant, in a given calendar (its time zone decides
    /// where a day starts). Separate so the span is tested at fixed instants.
    public func since(now: Date, calendar: Calendar = .current) -> Date? {
        guard let days else { return nil }
        let today: Date = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(days - 1), to: today)
    }
}
