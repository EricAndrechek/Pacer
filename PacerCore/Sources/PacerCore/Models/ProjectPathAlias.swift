import Foundation
import SwiftData

/// User-defined remap: every TokenSample whose canonicalized project
/// path equals `sourcePath` is attributed to `canonicalPath` instead.
///
/// Handles three real-world cases the worktree-stripping
/// `ProjectPathCanonicalizer` cannot:
///   1. Folder renames after-the-fact — `~/Code/ccmac` → `~/Code/Pacer`.
///   2. Sibling-directory worktrees — `~/Code/repo-feature-x` →
///      `~/Code/repo`. (In-tree `.claude/worktrees/<id>` and
///      `.worktrees/<id>` are still handled automatically by the
///      regex-driven canonicalizer.)
///   3. Cross-machine path differences — `/Users/alice/code/foo` →
///      `/Users/eric/code/foo` after restoring a SwiftData backup.
///
/// **Resolution order** in `ProjectPathCanonicalizer.canonicalize`:
///   1. Strip worktree segments (existing regex).
///   2. Look up the result in the alias map. Resolve transitively
///      (A→B, B→C ⇒ A→C) with cycle detection.
///   3. Final string is what's stored in `TokenSample.projectPath`.
///
/// **Migration on alias change**: writing/removing an alias bumps the
/// `pathCanonicalizationVersion` meta key. ScanCoordinator detects the
/// drift on its next cycle and runs `SamplePersister.canonicalizeProjectPaths`,
/// which re-applies the canonicalizer to every existing sample and folds
/// the (old, new) project-date pairs into the dirty set so
/// `ProjectAggregateRecomputer` rebuilds the affected rollups under the
/// new keys.
///
/// Aliases are user data: durable across schema upgrades, not derived
/// from anything else. Suggesting an alias from a `.git/config remote
/// origin` match still requires the user to confirm — we never write
/// an alias without explicit user intent.
@Model
public final class ProjectPathAlias {
    /// The project path that should be remapped. Stored verbatim from
    /// `ProjectPathCanonicalizer.canonicalize(_:aliases:)` AFTER the
    /// worktree-stripping pass but BEFORE alias resolution — i.e., the
    /// natural key the scanner would otherwise produce for samples in
    /// the source location.
    ///
    /// Unique: aliasing the same source to two different canonicals is
    /// undefined. Latest write wins from the API's perspective.
    @Attribute(.unique) public var sourcePath: String

    /// Where samples with `projectPath == sourcePath` should attribute.
    /// May itself be a `sourcePath` in another alias (chained aliases
    /// resolve transitively with cycle detection — see
    /// `ProjectPathCanonicalizer.canonicalize(_:aliases:)`).
    public var canonicalPath: String

    /// Audit metadata. Mostly for stable UI ordering (newest at top in
    /// the Settings table); not load-bearing for resolution.
    public var createdAt: Date

    public init(sourcePath: String, canonicalPath: String, createdAt: Date = Date()) {
        self.sourcePath = sourcePath
        self.canonicalPath = canonicalPath
        self.createdAt = createdAt
    }
}
