import Foundation
import SwiftData

/// Runs the git-root walk-up pass during each scan cycle and writes
/// the resulting `path → gitRoot` rows into `ProjectPathAlias`
/// automatically — no user confirmation needed. Persistent
/// `ProjectPathProbe` rows ensure we don't re-walk the same paths
/// every cycle and that user deletions of auto-generated aliases
/// stick across launches.
///
/// Two heuristics run in sequence each cycle:
///
/// 1. **Git-root rollup.** A path whose nearest `.git` ancestor is
///    a different directory becomes `path → ancestor`. Folds
///    subdirs of a repo into the repo root (`support-infra/local/
///    potato → support-infra`).
///
/// 2. **Sibling-worktree merge.** Two git roots that share the same
///    `remote.origin.url` are clones of the same repo (typical case:
///    `git worktree add ../repo-feature-x main`). The less-recently-
///    active root aliases into the more-recently-active one so
///    samples accumulate against the "current" working copy.
///
/// Both writes flow through `ProjectPathAliasManager`, so the user
/// can delete any auto-generated alias from Settings and the probe
/// row keeps the deletion sticking across launches.
///
/// Sits between `ProjectGitRootScanner` / `ProjectGitOriginScanner`
/// (pure heuristics) and `ProjectPathAliasManager` (the alias
/// writer). Lives in the persistence layer because it writes to
/// multiple tables and needs the `ModelContext`.
@MainActor
public final class ProjectGitRootAutoAliaser {
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    /// Outcome of one auto-aliasing pass. `aliasesAdded > 0` is
    /// what triggers the existing alias-fingerprint migration to
    /// re-canonicalize affected samples on this same scan cycle.
    public struct Result: Sendable, Equatable {
        public let pathsProbed: Int
        public let aliasesAdded: Int
    }

    /// Walk up from each candidate path, write probe rows, and
    /// insert aliases for paths whose git root differs from the
    /// path itself or whose git root shares an origin URL with
    /// another known git root.
    ///
    /// Skips for git-root pass:
    ///   - Paths already in `ProjectPathProbe` (we've considered
    ///     them before; user deletions of resulting aliases stick).
    ///   - Paths that already appear as a source in
    ///     `ProjectPathAlias` (something — auto or manual — already
    ///     remapped them).
    ///
    /// Sibling-worktree pass considers ALL probes (new + existing)
    /// since a sibling pair is only detectable when BOTH paths
    /// have been probed — that might span scan cycles.
    ///
    /// Saves are batched: one `context.save()` at the end of the
    /// pass, regardless of how many rows landed.
    @discardableResult
    public func run(candidatePaths: [String]) async throws -> Result {
        // Even with no new candidates we still need to run the
        // sibling-worktree pass — a path probed in a previous
        // cycle may have a new sibling appearing this cycle.
        let existingProbes = try loadAllProbes()
        let aliased = try loadAliasedSources()
        let toProbe = candidatePaths.filter {
            !existingProbes.keys.contains($0) && !aliased.contains($0) &&
            $0 != ProjectDailyAggregate.unknownProjectPath
        }

        // Backfill: existing probes added before the originURL
        // column existed (or before this pass ran) won't have a
        // URL recorded. Plug them in here — single .git/config
        // read per row, capped to the rows that actually need it.
        let probesNeedingOriginBackfill = existingProbes.values.filter {
            $0.gitRoot != nil && $0.originURL == nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // Walks are independent — fire them in parallel. With ~50
        // paths per scan cycle in practice, this hides the
        // worst-case sequential stat latency.
        var newProbes: [(path: String, gitRoot: String?, originURL: String?)] = []
        newProbes.reserveCapacity(toProbe.count)
        await withTaskGroup(of: (String, String?, String?).self) { group in
            for path in toProbe {
                group.addTask {
                    let root = await ProjectGitRootScanner.findGitRoot(
                        from: path, home: home
                    )
                    let origin: String?
                    if let root {
                        origin = await ProjectGitOriginScanner.readGitOrigin(at: root)
                    } else {
                        origin = nil
                    }
                    return (path, root, origin)
                }
            }
            for await result in group {
                newProbes.append((path: result.0, gitRoot: result.1, originURL: result.2))
            }
        }

        // Apply origin-URL backfill to existing rows in parallel.
        var backfillResults: [(probePath: String, originURL: String?)] = []
        backfillResults.reserveCapacity(probesNeedingOriginBackfill.count)
        if !probesNeedingOriginBackfill.isEmpty {
            await withTaskGroup(of: (String, String?).self) { group in
                for probe in probesNeedingOriginBackfill {
                    let rootPath = probe.gitRoot!
                    let probePath = probe.path
                    group.addTask {
                        let origin = await ProjectGitOriginScanner.readGitOrigin(at: rootPath)
                        return (probePath, origin)
                    }
                }
                for await result in group {
                    backfillResults.append((probePath: result.0, originURL: result.1))
                }
            }
            // Write the backfilled values directly to the existing
            // probe rows (we already loaded them).
            for r in backfillResults {
                if let row = existingProbes[r.probePath] {
                    row.originURL = r.originURL
                }
            }
        }

        let now = Date()
        var aliasesAdded = 0
        let manager = ProjectPathAliasManager(context: context)

        // Insert new probe rows and apply git-root aliases.
        for probe in newProbes {
            context.insert(ProjectPathProbe(
                path: probe.path,
                gitRoot: probe.gitRoot,
                originURL: probe.originURL,
                probedAt: now
            ))
            guard let gitRoot = probe.gitRoot, gitRoot != probe.path else { continue }
            do {
                _ = try manager.upsert(
                    sourcePath: probe.path,
                    canonicalPath: gitRoot,
                    autoGenerated: true
                )
                aliasesAdded += 1
            } catch {
                Log.write("ProjectGitRootAutoAliaser",
                          "git-root upsert failed for \(probe.path): \(error)")
            }
        }

        // Sibling-worktree pass: group root probes by originURL.
        // A "root probe" is one whose path IS its own gitRoot —
        // not a subdir. We consider EVERY known root probe (new
        // + existing + freshly backfilled) because a sibling
        // pair often spans cycles (first launch sees repo-A;
        // later the user creates repo-B and it shows up).
        var allRootProbes: [(path: String, gitRoot: String, originURL: String)] = []
        for probe in existingProbes.values {
            guard let root = probe.gitRoot, root == probe.path,
                  let origin = probe.originURL, !origin.isEmpty else { continue }
            allRootProbes.append((path: probe.path, gitRoot: root, originURL: origin))
        }
        for probe in newProbes {
            guard let root = probe.gitRoot, root == probe.path,
                  let origin = probe.originURL, !origin.isEmpty else { continue }
            allRootProbes.append((path: probe.path, gitRoot: root, originURL: origin))
        }
        // Drop probes whose path is already aliased — those have
        // been folded into another canonical and shouldn't be
        // grouped here.
        let aliasesAfterGitRoot = try loadAliasedSources()
        let groupable = allRootProbes.filter { !aliasesAfterGitRoot.contains($0.path) }
        let groupedByOrigin = Dictionary(grouping: groupable, by: { $0.originURL })

        if groupedByOrigin.values.contains(where: { $0.count >= 2 }) {
            // Canonical selection — see `pickCanonical` for the rule.
            // The short version: prefer the main worktree (`.git` is
            // a directory) over secondary worktrees (`.git` is a file
            // pointing at `<main>/.git/worktrees/<name>`). Tie-break
            // on most-recently-active, then alphabetical for full
            // determinism.
            let lastActive = try loadLastActiveByPath()
            for (_, group) in groupedByOrigin where group.count >= 2 {
                let canonical = Self.pickCanonical(
                    in: group, pathOf: { $0.path }, lastActive: lastActive)
                for entry in group where entry.path != canonical.path {
                    do {
                        _ = try manager.upsert(
                            sourcePath: entry.path,
                            canonicalPath: canonical.path,
                            autoGenerated: true
                        )
                        aliasesAdded += 1
                    } catch {
                        Log.write("ProjectGitRootAutoAliaser",
                                  "sibling upsert failed for \(entry.path) → \(canonical.path): \(error)")
                    }
                }
            }
        }

        if context.hasChanges {
            try context.save()
        }
        return Result(
            pathsProbed: newProbes.count + backfillResults.count,
            aliasesAdded: aliasesAdded
        )
    }

    /// Load every probe row keyed by `path`. We need both the
    /// "have we considered this path" check (the keys) and the
    /// stored `gitRoot` / `originURL` values for sibling matching
    /// and backfill, so a Set isn't enough.
    private func loadAllProbes() throws -> [String: ProjectPathProbe] {
        let descriptor = FetchDescriptor<ProjectPathProbe>()
        let rows = try context.fetch(descriptor)
        var out: [String: ProjectPathProbe] = [:]
        out.reserveCapacity(rows.count)
        for row in rows { out[row.path] = row }
        return out
    }

    private func loadAliasedSources() throws -> Set<String> {
        let descriptor = FetchDescriptor<ProjectPathAlias>()
        let rows = try context.fetch(descriptor)
        var out: Set<String> = []
        out.reserveCapacity(rows.count)
        for row in rows { out.insert(row.sourcePath) }
        return out
    }

    /// Most-recent `lastActive` per project path, sourced from
    /// `ProjectDailyAggregate`. Used to pick the canonical when a
    /// sibling-worktree group has 2+ candidates — the most
    /// recently-active root is the one the user is currently in.
    private func loadLastActiveByPath() throws -> [String: Date] {
        var descriptor = FetchDescriptor<ProjectDailyAggregate>()
        descriptor.propertiesToFetch = [\.projectPath, \.lastActive]
        let rows = try context.fetch(descriptor)
        var out: [String: Date] = [:]
        for row in rows {
            let current = out[row.projectPath, default: .distantPast]
            if row.lastActive > current {
                out[row.projectPath] = row.lastActive
            }
        }
        return out
    }

    /// Canonical-selection rule for a sibling-worktree group.
    ///
    /// Order of precedence:
    ///   1. **Main worktree wins.** `.git/` as a directory means
    ///      this path is the repo's primary working tree — a stable
    ///      identity whose directory name describes the repo, not a
    ///      feature branch. Secondary worktrees (`git worktree add`)
    ///      have `.git` as a file pointing at
    ///      `<main>/.git/worktrees/<name>` and tend to be named for
    ///      ephemeral things (`repo.issue-160`, `repo.feature-x`).
    ///   2. Most-recently-active wins. Used when zero or multiple
    ///      mains exist in the group (multiple mains: the user has
    ///      independent clones of the same remote — pick whichever
    ///      they're using).
    ///   3. Alphabetical (descending so the comparator's `>` is
    ///      consistent with the rest of the function) for full
    ///      determinism on ties.
    ///
    /// Generic over the element type — the run-pass uses tuples, the
    /// reconcile pass uses persistent `ProjectPathProbe` rows. Path
    /// access is supplied by the caller.
    static func pickCanonical<T>(
        in group: [T],
        pathOf: (T) -> String,
        lastActive: [String: Date]
    ) -> T {
        return group.max { lhs, rhs in
            let lPath = pathOf(lhs)
            let rPath = pathOf(rhs)
            let lMain = ProjectGitRootScanner.isMainWorktree(lPath)
            let rMain = ProjectGitRootScanner.isMainWorktree(rPath)
            if lMain != rMain { return !lMain }
            let l = lastActive[lPath] ?? .distantPast
            let r = lastActive[rPath] ?? .distantPast
            if l != r { return l < r }
            return lPath > rPath
        }!
    }

    /// One-shot reconciliation pass. Walks every existing
    /// `ProjectPathAlias` row and re-evaluates it under the current
    /// `pickCanonical` rule. Deletes aliases that point AT a
    /// non-main worktree when a main worktree exists in the same
    /// origin-URL sibling group — the regular sibling-merge pass in
    /// `run()` will then re-create the missing edge in the correct
    /// direction.
    ///
    /// Wired by `ScanCoordinator` to fire once when
    /// `pathCanonicalizationVersion` bumps to "4". Without this
    /// pass, the rule change only affects future probes — the
    /// `WaveHouse → WaveHouse.issue-160` alias written under the
    /// old "most recently active" rule would stay forever because
    /// the sibling-merge pass's filter (`!aliasesAfterGitRoot.
    /// contains($0.path)`) skips already-aliased paths.
    ///
    /// **Surgical by design.** We only delete an alias when:
    ///   - both endpoints are root probes (`probe.gitRoot ==
    ///     probe.path`) with the same `originURL` — i.e., this
    ///     alias was *itself* a sibling-merge result, not a
    ///     git-root rollup or a user-set rename, AND
    ///   - the alias's current canonical is NOT the main worktree
    ///     of the sibling group, AND a main worktree DOES exist
    ///     among the siblings.
    /// Aliases that already point at the correct canonical are
    /// left untouched, so this is a no-op on a healthy DB.
    ///
    /// Returns the count of aliases deleted (for logging).
    @discardableResult
    public func reconcileSiblingMergeAliases() throws -> Int {
        let probes = try loadAllProbes()
        let allAliases = try context.fetch(FetchDescriptor<ProjectPathAlias>())

        // Build origin → [root probe] index for "is there a main in
        // this group" lookups. Only consider probes whose path is
        // their own gitRoot AND that carry an originURL — those are
        // the population the sibling-merge pass considers.
        var rootsByOrigin: [String: [ProjectPathProbe]] = [:]
        for probe in probes.values {
            guard let gitRoot = probe.gitRoot, gitRoot == probe.path,
                  let origin = probe.originURL, !origin.isEmpty
            else { continue }
            rootsByOrigin[origin, default: []].append(probe)
        }

        var deleted = 0
        for alias in allAliases {
            guard let sourceProbe = probes[alias.sourcePath],
                  let canonicalProbe = probes[alias.canonicalPath],
                  let sourceRoot = sourceProbe.gitRoot,
                  let canonicalRoot = canonicalProbe.gitRoot,
                  sourceRoot == alias.sourcePath,
                  canonicalRoot == alias.canonicalPath,
                  let sourceOrigin = sourceProbe.originURL, !sourceOrigin.isEmpty,
                  let canonicalOrigin = canonicalProbe.originURL,
                  sourceOrigin == canonicalOrigin
            else { continue }

            // Both endpoints are sibling root probes. Does the
            // current canonical match the new rule?
            let siblings = rootsByOrigin[sourceOrigin] ?? []
            let groupHasMain = siblings.contains { ProjectGitRootScanner.isMainWorktree($0.path) }
            let canonicalIsMain = ProjectGitRootScanner.isMainWorktree(alias.canonicalPath)
            if groupHasMain, !canonicalIsMain {
                context.delete(alias)
                deleted += 1
            }
        }

        if deleted > 0 {
            try context.save()
        }
        return deleted
    }

    /// One-time classification of pre-existing `ProjectPathAlias` rows as
    /// auto-generated vs manual. Rows written before the
    /// `isAutoGenerated` field existed all default to `false` (manual)
    /// on migration; this pass re-derives the truth from `ProjectPathProbe`
    /// data so the Projects-tab alias manager can tuck auto-detected rows
    /// behind a disclosure instead of burying the handful of hand-made
    /// ones in a flat list.
    ///
    /// Wired by `ScanCoordinator` to fire once when
    /// `aliasOriginClassificationVersion` bumps. Cheap on a fresh DB (no
    /// aliases). Runs BEFORE `run()` so any rows the same cycle creates
    /// are already written with the correct flag.
    ///
    /// **Limitation:** classification leans on probe rows. A user who
    /// cleared the probe table (Settings → "Reset auto-merge") before
    /// upgrading loses the signal for their existing auto aliases, which
    /// then stay classified as manual. Acceptable — they explicitly reset
    /// that state, and new auto aliases are flagged correctly at write
    /// time going forward.
    ///
    /// Returns the count of rows whose classification changed.
    @discardableResult
    public func backfillOriginClassification() throws -> Int {
        let probes = try loadAllProbes()
        let aliases = try context.fetch(FetchDescriptor<ProjectPathAlias>())
        var changed = 0
        for alias in aliases {
            let auto = Self.looksAutoGenerated(alias: alias, probes: probes)
            if alias.isAutoGenerated != auto {
                alias.isAutoGenerated = auto
                changed += 1
            }
        }
        if changed > 0 {
            try context.save()
        }
        return changed
    }

    /// Reconstruct whether an alias was one the auto-aliaser would have
    /// written, by matching its endpoints against probe rows. Mirrors the
    /// two write paths in `run()`:
    ///   • Git-root rollup — the source was probed and its discovered git
    ///     root IS the canonical (and differs from the source itself).
    ///   • Sibling-worktree merge — both endpoints are root probes
    ///     (`path == gitRoot`) sharing a non-empty `originURL` (the same
    ///     guard `reconcileSiblingMergeAliases` uses).
    /// Anything else (folder rename, cross-machine restore, an accepted
    /// git-remote suggestion) reads as manual.
    static func looksAutoGenerated(
        alias: ProjectPathAlias,
        probes: [String: ProjectPathProbe]
    ) -> Bool {
        if let p = probes[alias.sourcePath], let gitRoot = p.gitRoot,
           gitRoot == alias.canonicalPath, gitRoot != p.path {
            return true
        }
        if let sp = probes[alias.sourcePath], let cp = probes[alias.canonicalPath],
           let sRoot = sp.gitRoot, sRoot == sp.path,
           let cRoot = cp.gitRoot, cRoot == cp.path,
           let sOrigin = sp.originURL, !sOrigin.isEmpty,
           let cOrigin = cp.originURL, sOrigin == cOrigin {
            return true
        }
        return false
    }
}

