import Foundation
import SwiftData

/// Sparse per-project user metadata, keyed by canonical project path —
/// the project-identity analogue of `ProjectBudget`. One row only for
/// projects the user has actually customized; most projects have none.
///
/// v1 holds a user-chosen color; the model is deliberately its own table
/// (not folded into `ProjectBudget`) so future per-project bits — a pin, a
/// custom display name, a note — land here without widening budget.
///
/// **Additive**: a brand-new `@Model`, so SwiftData's lightweight
/// migration adds it with no store reset and no migration plan.
///
/// **Keyed on the canonical (post-alias) path**, matching `ProjectBudget`.
/// When an alias merge rewrites a project's canonical path, the same
/// re-attribution pass that moves budgets must move these rows too, or a
/// merged project silently loses its color.
@Model
public final class ProjectMeta {
    @Attribute(.unique) public var projectPath: String

    /// User-chosen color as `#RRGGBB`. `nil` → fall back to the stable
    /// hash-of-path auto color.
    public var colorHex: String?

    public var updatedAt: Date

    public init(
        projectPath: String,
        colorHex: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.projectPath = projectPath
        self.colorHex = colorHex
        self.updatedAt = updatedAt
    }
}
