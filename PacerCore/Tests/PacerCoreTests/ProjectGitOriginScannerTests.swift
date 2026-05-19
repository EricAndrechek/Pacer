import Foundation
import Testing
@testable import PacerCore

@Suite struct ProjectGitOriginScannerTests {

    // MARK: - parseOriginURL (pure parser)

    @Test func parsesOriginURL() {
        let config = """
        [core]
            repositoryformatversion = 0
        [remote "origin"]
            url = git@github.com:example/repo.git
            fetch = +refs/heads/*:refs/remotes/origin/*
        """
        #expect(
            ProjectGitOriginScanner.parseOriginURL(from: config)
                == "git@github.com:example/repo.git"
        )
    }

    @Test func parsesOriginURLWithNoSpaces() {
        let config = """
        [remote "origin"]
        url=https://github.com/example/repo.git
        """
        #expect(
            ProjectGitOriginScanner.parseOriginURL(from: config)
                == "https://github.com/example/repo.git"
        )
    }

    @Test func parsesOriginURLAfterOtherRemotes() {
        let config = """
        [remote "upstream"]
            url = git@github.com:upstream/repo.git
        [remote "origin"]
            url = git@github.com:fork/repo.git
        """
        #expect(
            ProjectGitOriginScanner.parseOriginURL(from: config)
                == "git@github.com:fork/repo.git"
        )
    }

    @Test func returnsNilWithoutOriginSection() {
        let config = """
        [core]
            repositoryformatversion = 0
        [remote "upstream"]
            url = git@github.com:upstream/repo.git
        """
        #expect(ProjectGitOriginScanner.parseOriginURL(from: config) == nil)
    }

    @Test func returnsNilForEmptyConfig() {
        #expect(ProjectGitOriginScanner.parseOriginURL(from: "") == nil)
    }

    // MARK: - End-to-end suggestion using on-disk fixtures

    @Test func suggestsPairWhenTwoProjectsShareOrigin() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pacer-gitorigin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let projectA = tmp.appendingPathComponent("repo")
        let projectB = tmp.appendingPathComponent("repo-feature-x")
        try writeGitConfig(at: projectA, origin: "git@github.com:example/shared.git")
        try writeGitConfig(at: projectB, origin: "git@github.com:example/shared.git")

        let suggestions = await ProjectGitOriginScanner.suggest(
            projectPaths: [projectA.path, projectB.path]
        )
        #expect(suggestions.count == 1)
        #expect(suggestions[0].originURL == "git@github.com:example/shared.git")
        let pair = Set([suggestions[0].suggestedSource, suggestions[0].suggestedCanonical])
        #expect(pair == [projectA.path, projectB.path])
    }

    @Test func suggestsNoneForDifferentOrigins() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pacer-gitorigin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let projectA = tmp.appendingPathComponent("alpha")
        let projectB = tmp.appendingPathComponent("beta")
        try writeGitConfig(at: projectA, origin: "git@github.com:example/alpha.git")
        try writeGitConfig(at: projectB, origin: "git@github.com:example/beta.git")

        let suggestions = await ProjectGitOriginScanner.suggest(
            projectPaths: [projectA.path, projectB.path]
        )
        #expect(suggestions.isEmpty)
    }

    @Test func skipsAlreadyAliasedSources() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pacer-gitorigin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let projectA = tmp.appendingPathComponent("repo")
        let projectB = tmp.appendingPathComponent("repo-feature-x")
        try writeGitConfig(at: projectA, origin: "git@github.com:example/shared.git")
        try writeGitConfig(at: projectB, origin: "git@github.com:example/shared.git")

        // If the user has already aliased projectB → projectA, we
        // shouldn't re-suggest the pair.
        let suggestions = await ProjectGitOriginScanner.suggest(
            projectPaths: [projectA.path, projectB.path],
            existingAliasedSources: [projectB.path]
        )
        #expect(suggestions.isEmpty)
    }

    @Test func skipsPathsThatDoNotExist() async {
        let suggestions = await ProjectGitOriginScanner.suggest(
            projectPaths: [
                "/nonexistent/path-A",
                "/nonexistent/path-B",
            ]
        )
        #expect(suggestions.isEmpty)
    }

    @Test func deterministicIdForSamePair() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pacer-gitorigin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let projectA = tmp.appendingPathComponent("repo-a")
        let projectB = tmp.appendingPathComponent("repo-b")
        try writeGitConfig(at: projectA, origin: "git@github.com:example/shared.git")
        try writeGitConfig(at: projectB, origin: "git@github.com:example/shared.git")

        // Same inputs in two different orders should produce the same
        // suggestion id (so the user's "dismissed" set stays stable).
        let first = await ProjectGitOriginScanner.suggest(
            projectPaths: [projectA.path, projectB.path]
        )
        let second = await ProjectGitOriginScanner.suggest(
            projectPaths: [projectB.path, projectA.path]
        )
        #expect(first.map(\.id) == second.map(\.id))
    }

    // MARK: - Test helpers

    private func writeGitConfig(at projectURL: URL, origin: String) throws {
        let gitDir = projectURL.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        let config = """
        [core]
            repositoryformatversion = 0
        [remote "origin"]
            url = \(origin)
        """
        try config.write(
            to: gitDir.appendingPathComponent("config"),
            atomically: true,
            encoding: .utf8
        )
    }
}
