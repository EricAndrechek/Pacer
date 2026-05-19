import Foundation
import SwiftData

/// Per-project spending caps. One row per project the user wants to
/// monitor — projects without a row have no budget (no notification,
/// no progress bar). `enabled` is the master switch so a user can
/// temporarily mute a project's budget without losing the configured
/// thresholds.
///
/// Stored separately from `ProjectDailyAggregate` because:
///   - Budgets are user-input config; aggregates are derived data.
///     Mixing them makes the recomputer responsible for not stomping
///     user edits.
///   - Most projects don't have budgets, so a dedicated table stays
///     small and the existence-check (one fetch by `projectPath`) is
///     fast.
///
/// Both `dailyLimitUSD` and `weeklyLimitUSD` are optional — the user
/// can set one without the other. nil = "no limit at this period."
/// `enabled = false` AND any limit set is a valid state: the
/// thresholds are preserved across a temporary mute.
@Model
public final class ProjectBudget {
    /// Canonical project path (post-alias). One row per project;
    /// `@Attribute(.unique)` ensures we never end up with two budgets
    /// for the same project (e.g., a UI bug double-saving).
    @Attribute(.unique) public var projectPath: String
    public var dailyLimitUSD: Double?
    public var weeklyLimitUSD: Double?
    /// Master switch — false means "this project has a budget
    /// configured but don't notify on it." Used by the ProjectDetailView
    /// toggle so the user can pause alerts without zeroing out their
    /// limits.
    public var enabled: Bool
    /// When the budget row was last updated. Surfaces in the Settings
    /// summary card so the user can see which budgets are recent.
    public var updatedAt: Date

    public init(
        projectPath: String,
        dailyLimitUSD: Double? = nil,
        weeklyLimitUSD: Double? = nil,
        enabled: Bool = true,
        updatedAt: Date = Date()
    ) {
        self.projectPath = projectPath
        self.dailyLimitUSD = dailyLimitUSD
        self.weeklyLimitUSD = weeklyLimitUSD
        self.enabled = enabled
        self.updatedAt = updatedAt
    }

    /// True when there's at least one non-nil limit AND the row is
    /// enabled. Notification + progress-bar code paths use this to
    /// skip rows that are configured-but-paused.
    public var isActive: Bool {
        enabled && (dailyLimitUSD != nil || weeklyLimitUSD != nil)
    }
}
