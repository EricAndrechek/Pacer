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

    public init(
        path: String,
        gitRoot: String?,
        originURL: String? = nil,
        probedAt: Date = Date()
    ) {
        self.path = path
        self.gitRoot = gitRoot
        self.originURL = originURL
        self.probedAt = probedAt
    }
}
