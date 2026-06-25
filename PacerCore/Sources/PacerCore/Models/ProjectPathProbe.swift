import Foundation
import SwiftData

/// Persistent record that Pacer has already considered a given
/// project path for git-root auto-aliasing.
///
/// Why this exists: the scan coordinator's auto-aliasing pass walks
/// up the filesystem from each known project path looking for the
/// nearest `.git`. If found, it writes a `path → gitRoot` alias.
/// Probe rows close the loop:
///   - On the next scan cycle we don't re-walk paths we've already
///     considered (filesystem reads are cheap individually, but
///     ~50 paths × 16 stat calls × every scan cycle adds up).
///   - If the user manually deletes an auto-generated alias, the
///     probe row stays. The next scan sees "this path is already
///     probed → don't re-suggest" and the deletion sticks across
///     launches.
///
/// To force a fresh probe of every path (e.g. after a major repo
/// reorg), the user can clear the probe table from Settings → Data;
/// the next scan will re-walk everything.
@Model
public final class ProjectPathProbe {
    /// The project path we probed — verbatim, no normalisation. We
    /// key off the same canonical form the scanner reads from
    /// `ProjectDailyAggregate.projectPath` so reverse-lookup is
    /// trivial.
    @Attribute(.unique) public var path: String

    /// The discovered git repo root, or nil if the probe didn't
    /// find a `.git` ancestor. Stored for diagnostics and for the
    /// "Reset auto-merge" affordance — nil rows are kept so we
    /// remember "we looked and there was nothing" without re-walking.
    public var gitRoot: String?

    /// `remote.origin.url` read from the discovered git repo's
    /// `.git/config`. Used to detect sibling-dir worktrees: when
    /// two project paths have different `gitRoot` but the same
    /// `originURL`, they're checkouts of the same repo and Pacer
    /// auto-merges them. Nil for paths with no git ancestor OR
    /// repos that don't have a remote `origin`.
    public var originURL: String?

    public var probedAt: Date

    /// The user deleted an auto-generated alias for this path, so Pacer
    /// must not re-create it. The git-root rollup pass already honours
    /// deletions implicitly (it skips any path that already has a probe
    /// row), but the sibling-worktree pass re-evaluates *every* root
    /// probe each cycle and would otherwise re-merge a path the moment
    /// its alias was removed. This flag is the sibling pass's "the user
    /// said no" signal — set by `ProjectPathAliasManager.remove(...,
    /// rejectAutoMerge: true)` and checked in
    /// `ProjectGitRootAutoAliaser.run`. Re-adding the alias by hand is
    /// the way back (it becomes a manual alias).
    ///
    /// Declared with a default so SwiftData's lightweight migration adds
    /// the column additively (existing rows get `false`).
    public var autoMergeRejected: Bool = false

    /// We attempted the `.git/config` origin read for this probe at least
    /// once. Set after the backfill pass tries a row — regardless of
    /// result — so origin-less repos (local-only, no `remote.origin.url`)
    /// stop getting their `.git/config` re-read on every cycle forever.
    /// Without this, a probe with `gitRoot != nil && originURL == nil`
    /// re-qualifies for backfill on every run and never converges. If a
    /// remote is later added, "Reset auto-merge" (which clears the probe
    /// table) re-probes it.
    ///
    /// Declared with a default so SwiftData's lightweight migration adds
    /// the column additively (existing rows get `false`).
    public var originBackfillAttempted: Bool = false

    public init(
        path: String,
        gitRoot: String?,
        originURL: String? = nil,
        probedAt: Date = Date(),
        autoMergeRejected: Bool = false,
        originBackfillAttempted: Bool = false
    ) {
        self.path = path
        self.gitRoot = gitRoot
        self.originURL = originURL
        self.probedAt = probedAt
        self.autoMergeRejected = autoMergeRejected
        self.originBackfillAttempted = originBackfillAttempted
    }
}
