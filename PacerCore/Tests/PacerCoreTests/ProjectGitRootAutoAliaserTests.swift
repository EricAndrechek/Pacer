import Foundation
import SwiftData
import Testing
@testable import PacerCore

@MainActor
@Suite struct ProjectGitRootAutoAliaserTests {

    // MARK: - sibling-merge canonical selection

    /// Two siblings (same origin URL): one is the main worktree
    /// (`.git/` directory), the other is a secondary (`.git` file
    /// pointer). The main one must win regardless of recency.
    @Test func siblingMergePicksMainWorktreeOverSecondary() async throws {
        let (mainPath, secondaryPath, origin, cleanup) = try makeSiblingPair()
        defer { cleanup() }

        let container = try makeContainer()
        let context = ModelContext(container)
        // Seed probes for both paths so `run()` skips the walk
        // (it would still find the same gitRoots, but seeding makes
        // the test independent of FS walk performance/ordering).
        seedProbe(in: context, path: mainPath, gitRoot: mainPath, origin: origin)
        seedProbe(in: context, path: secondaryPath, gitRoot: secondaryPath, origin: origin)
        // Activity that would have picked the *wrong* canonical
        // under the old rule: secondary is more recently active.
        seedDailyAggregate(in: context, projectPath: mainPath, lastActive: hoursAgo(48))
        seedDailyAggregate(in: context, projectPath: secondaryPath, lastActive: hoursAgo(1))
        try context.save()

        let aliaser = ProjectGitRootAutoAliaser(context: context)
        _ = try await aliaser.run(candidatePaths: [])

        let aliases = try context.fetch(FetchDescriptor<ProjectPathAlias>())
        #expect(aliases.count == 1)
        #expect(aliases[0].sourcePath == secondaryPath)
        #expect(aliases[0].canonicalPath == mainPath)
    }

    /// When neither sibling looks like a main worktree (both `.git`
    /// files — i.e. two secondary worktrees of some elsewhere main,
    /// or both repos with no `.git` at all — falls back to the old
    /// "most recently active wins" rule.
    @Test func siblingMergeFallsBackToRecencyWithoutMain() async throws {
        let (a, b, origin, cleanup) = try makeTwoSecondaries()
        defer { cleanup() }

        let container = try makeContainer()
        let context = ModelContext(container)
        seedProbe(in: context, path: a, gitRoot: a, origin: origin)
        seedProbe(in: context, path: b, gitRoot: b, origin: origin)
        seedDailyAggregate(in: context, projectPath: a, lastActive: hoursAgo(48))
        seedDailyAggregate(in: context, projectPath: b, lastActive: hoursAgo(1))
        try context.save()

        let aliaser = ProjectGitRootAutoAliaser(context: context)
        _ = try await aliaser.run(candidatePaths: [])

        let aliases = try context.fetch(FetchDescriptor<ProjectPathAlias>())
        #expect(aliases.count == 1)
        // b is more recently active → b wins.
        #expect(aliases[0].sourcePath == a)
        #expect(aliases[0].canonicalPath == b)
    }

    // MARK: - reconcileSiblingMergeAliases

    /// The smoking-gun case: an alias was written under the old rule
    /// pointing main→secondary. `reconcileSiblingMergeAliases` must
    /// delete it so the next `run()` re-creates the edge in the
    /// correct direction.
    @Test func reconcileDeletesAliasPointingAtNonMainWhenMainExists() async throws {
        let (mainPath, secondaryPath, origin, cleanup) = try makeSiblingPair()
        defer { cleanup() }

        let container = try makeContainer()
        let context = ModelContext(container)
        seedProbe(in: context, path: mainPath, gitRoot: mainPath, origin: origin)
        seedProbe(in: context, path: secondaryPath, gitRoot: secondaryPath, origin: origin)
        // The bad alias from the old rule: main → secondary.
        context.insert(ProjectPathAlias(sourcePath: mainPath, canonicalPath: secondaryPath))
        try context.save()

        let aliaser = ProjectGitRootAutoAliaser(context: context)
        let removed = try aliaser.reconcileSiblingMergeAliases()
        #expect(removed == 1)
        #expect(try context.fetchCount(FetchDescriptor<ProjectPathAlias>()) == 0)
    }

    /// An alias pointing the correct direction (secondary → main) is
    /// left intact — reconcile must be a no-op on healthy data.
    @Test func reconcileLeavesAliasPointingAtMain() async throws {
        let (mainPath, secondaryPath, origin, cleanup) = try makeSiblingPair()
        defer { cleanup() }

        let container = try makeContainer()
        let context = ModelContext(container)
        seedProbe(in: context, path: mainPath, gitRoot: mainPath, origin: origin)
        seedProbe(in: context, path: secondaryPath, gitRoot: secondaryPath, origin: origin)
        context.insert(ProjectPathAlias(sourcePath: secondaryPath, canonicalPath: mainPath))
        try context.save()

        let aliaser = ProjectGitRootAutoAliaser(context: context)
        let removed = try aliaser.reconcileSiblingMergeAliases()
        #expect(removed == 0)
        #expect(try context.fetchCount(FetchDescriptor<ProjectPathAlias>()) == 1)
    }

    /// Aliases that aren't sibling-merge results (e.g. git-root
    /// rollups where source is a descendant of canonical) must be
    /// left untouched even if the canonical happens to be a
    /// secondary worktree.
    @Test func reconcileSkipsGitRootRollupAliases() async throws {
        let (mainPath, secondaryPath, origin, cleanup) = try makeSiblingPair()
        defer { cleanup() }

        let container = try makeContainer()
        let context = ModelContext(container)
        // The rollup probe: a subdir's gitRoot is the secondary's
        // path — NOT a root probe (gitRoot != path).
        let subdirPath = secondaryPath + "/subdir"
        seedProbe(in: context, path: subdirPath, gitRoot: secondaryPath, origin: origin)
        seedProbe(in: context, path: mainPath, gitRoot: mainPath, origin: origin)
        seedProbe(in: context, path: secondaryPath, gitRoot: secondaryPath, origin: origin)
        context.insert(ProjectPathAlias(sourcePath: subdirPath, canonicalPath: secondaryPath))
        try context.save()

        let aliaser = ProjectGitRootAutoAliaser(context: context)
        let removed = try aliaser.reconcileSiblingMergeAliases()
        // Subdir → secondary is a git-root rollup, not a sibling
        // merge. Reconcile must not touch it.
        #expect(removed == 0)
    }

    /// When `run()` happens AFTER reconcile on the bad-alias case,
    /// the new sibling-merge pass re-creates the alias in the
    /// correct direction.
    @Test func runAfterReconcileRecreatesAliasCorrectly() async throws {
        let (mainPath, secondaryPath, origin, cleanup) = try makeSiblingPair()
        defer { cleanup() }

        let container = try makeContainer()
        let context = ModelContext(container)
        seedProbe(in: context, path: mainPath, gitRoot: mainPath, origin: origin)
        seedProbe(in: context, path: secondaryPath, gitRoot: secondaryPath, origin: origin)
        seedDailyAggregate(in: context, projectPath: secondaryPath, lastActive: hoursAgo(1))
        // The bad alias.
        context.insert(ProjectPathAlias(sourcePath: mainPath, canonicalPath: secondaryPath))
        try context.save()

        let aliaser = ProjectGitRootAutoAliaser(context: context)
        _ = try aliaser.reconcileSiblingMergeAliases()
        _ = try await aliaser.run(candidatePaths: [])

        let aliases = try context.fetch(FetchDescriptor<ProjectPathAlias>())
        #expect(aliases.count == 1)
        #expect(aliases[0].sourcePath == secondaryPath)
        #expect(aliases[0].canonicalPath == mainPath)
    }

    // MARK: - helpers

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: Heartbeat.self,
            TokenSample.self,
            DailyAggregate.self,
            ProjectDailyAggregate.self,
            RateLimitSample.self,
            SessionInfo.self,
            ClaudeCodeMeta.self,
            JSONLFileCursor.self,
            ProjectPathAlias.self,
            ProjectPathProbe.self,
            configurations: config
        )
    }

    /// Creates a main repo with `.git/` directory and a secondary
    /// worktree sibling with `.git` file pointing at it. Returns
    /// both paths + the synthetic origin URL written into the main
    /// repo's `.git/config`.
    private func makeSiblingPair() throws -> (
        main: String, secondary: String, origin: String, cleanup: () -> Void
    ) {
        let root = try makeTempDir()
        let main = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        let gitDir = main.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        let origin = "git@example.com:org/repo.git"
        try """
        [remote "origin"]
            url = \(origin)
        """.write(
            to: gitDir.appendingPathComponent("config"),
            atomically: true,
            encoding: .utf8
        )
        let secondary = root.appendingPathComponent("repo.feature-x")
        try FileManager.default.createDirectory(at: secondary, withIntermediateDirectories: true)
        // Synthetic worktree shape: `.git` is a file pointing at a
        // (faked) gitdir under the main repo's .git/worktrees/.
        let worktreesDir = gitDir.appendingPathComponent("worktrees/feature-x")
        try FileManager.default.createDirectory(at: worktreesDir, withIntermediateDirectories: true)
        try "gitdir: \(worktreesDir.path)".write(
            to: secondary.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
        let cleanup: () -> Void = { _ = try? FileManager.default.removeItem(at: root) }
        return (main.path, secondary.path, origin, cleanup)
    }

    /// Two secondary-worktree-shaped directories with the same
    /// origin URL. Used to exercise the recency fallback when no
    /// main worktree is on disk.
    private func makeTwoSecondaries() throws -> (
        a: String, b: String, origin: String, cleanup: () -> Void
    ) {
        let root = try makeTempDir()
        let origin = "git@example.com:org/repo.git"
        // Both directories carry a `.git` *file* — neither is the
        // main worktree per `isMainWorktree`. To keep the origin URL
        // resolvable for both, point them at the same shared
        // `worktrees/<name>` parents. The originURL value stored in
        // the probe is supplied directly by the test so we don't
        // need a working `.git/config` lookup here.
        let a = root.appendingPathComponent("a")
        let b = root.appendingPathComponent("b")
        for url in [a, b] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try "gitdir: /unused".write(
                to: url.appendingPathComponent(".git"),
                atomically: true,
                encoding: .utf8
            )
        }
        let cleanup: () -> Void = { _ = try? FileManager.default.removeItem(at: root) }
        return (a.path, b.path, origin, cleanup)
    }

    private func makeTempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PacerAutoAliaserTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func seedProbe(
        in context: ModelContext,
        path: String,
        gitRoot: String?,
        origin: String?
    ) {
        context.insert(ProjectPathProbe(
            path: path,
            gitRoot: gitRoot,
            originURL: origin,
            probedAt: Date()
        ))
    }

    private func seedDailyAggregate(
        in context: ModelContext,
        projectPath: String,
        lastActive: Date
    ) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        context.insert(ProjectDailyAggregate(
            projectPath: projectPath,
            date: formatter.string(from: lastActive),
            lastActive: lastActive
        ))
    }

    private func hoursAgo(_ hours: Double) -> Date {
        Date(timeIntervalSinceNow: -hours * 3600)
    }
}
