import Foundation
import Testing
@testable import PacerCore

@Suite struct ProjectGitRootScannerTests {

    // MARK: - findGitRoot

    /// Walking from a *descendant* of a git repo returns the repo
    /// root. This is the canonical use case: `support-infra/local/potato`
    /// → `support-infra`.
    @Test func findsGitRootFromDescendant() async throws {
        let repoRoot = try makeTempRepo(subdirs: ["local/potato"])
        defer { try? FileManager.default.removeItem(at: repoRoot) }

        let descendant = repoRoot.appendingPathComponent("local/potato").path
        let found = await ProjectGitRootScanner.findGitRoot(
            from: descendant,
            home: "/nowhere"
        )
        #expect(found == repoRoot.path)
    }

    /// When the input path IS the repo root, `findGitRoot` still
    /// returns it (the same value) — the caller filters that case
    /// separately in `suggest`.
    @Test func findsGitRootFromRepoRootItself() async throws {
        let repoRoot = try makeTempRepo(subdirs: [])
        defer { try? FileManager.default.removeItem(at: repoRoot) }

        let found = await ProjectGitRootScanner.findGitRoot(
            from: repoRoot.path,
            home: "/nowhere"
        )
        #expect(found == repoRoot.path)
    }

    /// `.git` as a FILE (worktree shape) is accepted just like a
    /// `.git` directory. The worktree's working dir is its own
    /// canonical for samples taken inside it.
    @Test func acceptsGitFileForWorktrees() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gitFile = dir.appendingPathComponent(".git")
        try "gitdir: /other/.git/worktrees/foo".write(
            to: gitFile,
            atomically: true,
            encoding: .utf8
        )
        let found = await ProjectGitRootScanner.findGitRoot(
            from: dir.path,
            home: "/nowhere"
        )
        #expect(found == dir.path)
    }

    /// Paths that don't exist on disk return nil — can't probe a
    /// folder that's been renamed/deleted since the JSONL was
    /// written.
    @Test func returnsNilForMissingPath() async {
        let found = await ProjectGitRootScanner.findGitRoot(
            from: "/this/path/does/not/exist/anywhere/probably",
            home: "/nowhere"
        )
        #expect(found == nil)
    }

    /// The walk stops at HOME — we don't suggest aliasing arbitrary
    /// subdirs to the user's home directory even if a `.git` ever
    /// lived there.
    @Test func stopsAtHome() async throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let inside = home.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(
            at: inside, withIntermediateDirectories: true)
        // No .git anywhere. Walking up from `inside` should hit HOME
        // and return nil rather than walking above it.
        let found = await ProjectGitRootScanner.findGitRoot(
            from: inside.path,
            home: home.path
        )
        #expect(found == nil)
    }

    // MARK: - suggest

    /// Bog-standard suggestion: a sub-path that lives inside a git
    /// repo gets mapped to the repo root with the relative subpath
    /// recorded.
    @Test func suggestsAliasForDescendant() async throws {
        let repoRoot = try makeTempRepo(subdirs: ["local/potato"])
        defer { try? FileManager.default.removeItem(at: repoRoot) }

        let sub = repoRoot.appendingPathComponent("local/potato").path
        let suggestions = await ProjectGitRootScanner.suggest(
            projectPaths: [sub, repoRoot.path]
        )
        // Repo root itself shouldn't suggest aliasing to itself.
        #expect(suggestions.count == 1)
        #expect(suggestions.first?.suggestedSource == sub)
        #expect(suggestions.first?.suggestedCanonical == repoRoot.path)
        #expect(suggestions.first?.relativeSubpath == "local/potato")
    }

    /// Paths already in the user's alias table are skipped — re-
    /// suggesting them would be UI noise.
    @Test func skipsAlreadyAliasedSources() async throws {
        let repoRoot = try makeTempRepo(subdirs: ["sub"])
        defer { try? FileManager.default.removeItem(at: repoRoot) }

        let sub = repoRoot.appendingPathComponent("sub").path
        let suggestions = await ProjectGitRootScanner.suggest(
            projectPaths: [sub],
            existingAliasedSources: [sub]
        )
        #expect(suggestions.isEmpty)
    }

    // MARK: - helpers

    private func makeTempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PacerGitRootScannerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    /// Lay out a fake repo: temp dir with an empty `.git/` directory
    /// inside and the named subdirs created.
    private func makeTempRepo(subdirs: [String]) throws -> URL {
        let root = try makeTempDir()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"),
            withIntermediateDirectories: true)
        for sub in subdirs {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(sub),
                withIntermediateDirectories: true)
        }
        return root
    }
}
