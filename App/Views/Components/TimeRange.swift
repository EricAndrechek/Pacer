import Foundation
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
    case all         = "all"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .sevenDays:   return "7 days"
        case .thirtyDays:  return "30 days"
        case .ninetyDays:  return "90 days"
        case .all:         return "All time"
        }
    }

    /// Days of history to include. `nil` means "everything ever recorded."
    public var days: Int? {
        switch self {
        case .sevenDays:   return 7
        case .thirtyDays:  return 30
        case .ninetyDays:  return 90
        case .all:         return nil
        }
    }

    public var since: Date? {
        guard let days else { return nil }
        return Calendar.current.date(byAdding: .day, value: -days, to: Date())
    }
}
