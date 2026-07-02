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

    /// Frozen color seed captured when the project was first seen — the
    /// git remote origin URL when the project has one, else its canonical
    /// path. The UI hashes this into a stable palette color
    /// (`pacerProjectColor`). Recording it (rather than hashing the live
    /// path each render) means the color survives a folder rename, a
    /// remote change, or a rank reshuffle. Declared optional with a
    /// default so the column is additive.
    public var colorSeed: String?

    /// Optional user-chosen color override as `#RRGGBB`. Wins over
    /// `colorSeed` when set. (No picker UI yet — reserved for a future
    /// manual override.)
    public var colorHex: String?

    public var updatedAt: Date

    public init(
        projectPath: String,
        colorSeed: String? = nil,
        colorHex: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.projectPath = projectPath
        self.colorSeed = colorSeed
        self.colorHex = colorHex
        self.updatedAt = updatedAt
    }
}
