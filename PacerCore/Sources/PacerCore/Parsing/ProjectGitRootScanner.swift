import Foundation

/// Walks up the filesystem from each known project path looking for
/// the nearest `.git` marker (directory OR file — git worktrees use
/// the file form). When the project path is a *descendant* of a git
/// repo's root, emit a `path → repoRoot` alias suggestion.
///
/// The motivating case: a Claude Code session run inside
/// `~/Code/work/.../support-infra/local/potato` writes its cwd as
/// the full subdir path. Without this scanner, that subdir shows up
/// as its own "project" in Pacer's UI even though it's really just
/// a subdirectory of the `support-infra` repo. After accepting the
/// suggestion (or the one-click "Auto-merge" bulk action), all
/// samples re-attribute to `support-infra` and the new
/// `originalProjectPath` field on `TokenSample` carries the subdir
/// detail so the project-detail drill-down can still surface
/// `local/potato` as a sub-bucket.
///
/// **Deliberate boundaries** (mirrors `ProjectGitOriginScanner`'s
/// philosophy):
/// - Suggestion engine only — never writes aliases on its own.
/// - Filesystem-aware but bounded: each path's upward walk stops at
///   `HOME`, capped at `maxWalkDepth`, and skipped entirely if the
///   path doesn't currently exist (the JSONL may have been written
///   weeks ago against a folder that's since been renamed/deleted).
/// - Skips paths already in the alias table — re-suggesting
///   something the user has already mapped would be noise.
/// - Skips paths that *are* the git root (no merge needed; that's
///   already the canonical).
public enum ProjectGitRootScanner {

    /// Defensive cap on how far up the directory tree to walk.
    /// Real-world project paths rarely exceed 8 levels deep; 16 is
    /// well past anything a human would have set up and well below
    /// the wall-clock cost of pathological cases.
    public static let maxWalkDepth = 16

    public struct Suggestion: Identifiable, Hashable, Sendable {
        /// The descendant path Pacer currently attributes samples to.
        /// Aliasing this `→ suggestedCanonical` folds those samples
        /// into the repo root on the next scan cycle.
        public let suggestedSource: String
        /// The git repo root (parent dir of `.git`).
        public let suggestedCanonical: String
        /// Path relative to the repo root, e.g. `local/potato`.
        /// Surfaced in the suggestion UI so the user can recognise
        /// what's about to fold ("merge `support-infra/local/potato`
        /// into `support-infra`").
        public let relativeSubpath: String

        public var id: String {
            "\(suggestedSource)→\(suggestedCanonical)"
        }
    }

    /// For every input path: walk up the directory tree until we
    /// hit a `.git`, recording the parent dir as the repo root.
    ///
    /// Skips:
    /// - paths that don't currently exist (can't probe filesystem)
    /// - paths that ARE a git root (`.git` lives directly inside)
    /// - paths in `existingAliasedSources` (already-mapped — re-
    ///   suggesting would be noise)
    /// - paths whose walk reaches `HOME` or `maxWalkDepth` without
    ///   finding a `.git`
    ///
    /// Suggestions are deterministic-ordered by source path for
    /// stable UI rendering.
    public static func suggest(
        projectPaths: [String],
        existingAliasedSources: Set<String> = []
    ) async -> [Suggestion] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var out: [Suggestion] = []
        for raw in projectPaths {
            if existingAliasedSources.contains(raw) { continue }
            guard let root = await findGitRoot(from: raw, home: home) else { continue }
            // The path IS the repo root — already canonical, nothing
            // to suggest. (Don't filter by string equality alone: the
            // canonical might have a trailing slash; normalize both.)
            if normalize(raw) == normalize(root) { continue }
            let subpath = relativePath(from: root, to: raw)
            out.append(Suggestion(
                suggestedSource: raw,
                suggestedCanonical: root,
                relativeSubpath: subpath
            ))
        }
        return out.sorted { $0.suggestedSource < $1.suggestedSource }
    }

    /// Walk `path` upward looking for a `.git`. Returns the parent
    /// directory of the `.git` we find, or nil if:
    /// - `path` doesn't exist on disk
    /// - we reach the user's home dir without finding a `.git`
    /// - we exceed `maxWalkDepth`
    ///
    /// Accepts both forms of `.git`:
    /// - directory (normal repo)
    /// - file (worktree — the file points at the parent repo's
    ///   `.git/worktrees/<id>`; the working dir IS the canonical
    ///   root for samples taken inside it, so we don't follow the
    ///   pointer)
    static func findGitRoot(from path: String, home: String) async -> String? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        let homeNormalized = normalize(home)
        var current = URL(fileURLWithPath: path).standardizedFileURL
        for _ in 0..<maxWalkDepth {
            let candidate = current.appendingPathComponent(".git").path
            if fm.fileExists(atPath: candidate) {
                return current.path
            }
            // Stop at HOME (don't walk above ~).
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent == current { return nil }       // hit filesystem root
            if normalize(parent.path) == homeNormalized { return nil }
            current = parent
        }
        return nil
    }

    /// Strip trailing slashes. Both `/Users/eric/Code/Pacer/` and
    /// `/Users/eric/Code/Pacer` should compare equal for the
    /// "already-canonical" check.
    private static func normalize(_ p: String) -> String {
        var s = p
        while s.count > 1, s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// `relativePath(from: "/a/b", to: "/a/b/c/d")` → `"c/d"`.
    /// Returns the absolute path if `to` isn't a descendant of `from`
    /// (shouldn't happen by construction, but defensive).
    private static func relativePath(from base: String, to descendant: String) -> String {
        let b = normalize(base)
        let d = normalize(descendant)
        guard d.hasPrefix(b + "/") else { return d }
        return String(d.dropFirst(b.count + 1))
    }
}
