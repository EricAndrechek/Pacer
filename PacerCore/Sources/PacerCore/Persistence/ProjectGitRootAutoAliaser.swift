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
                _ = try manager.upsert(sourcePath: probe.path, canonicalPath: gitRoot)
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
            // Activity index — pick the most-recently-active root
            // as the canonical for each sibling group. Fall back to
            // alphabetical order if neither has activity yet
            // (highly unusual but defensively handled).
            let lastActive = try loadLastActiveByPath()
            for (_, group) in groupedByOrigin where group.count >= 2 {
                let canonical = group.max { lhs, rhs in
                    let l = lastActive[lhs.path] ?? .distantPast
                    let r = lastActive[rhs.path] ?? .distantPast
                    if l != r { return l < r }
                    return lhs.path > rhs.path
                }!
                for entry in group where entry.path != canonical.path {
                    do {
                        _ = try manager.upsert(
                            sourcePath: entry.path,
                            canonicalPath: canonical.path
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
}
