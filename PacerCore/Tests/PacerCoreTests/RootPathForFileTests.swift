import Foundation
import Testing
@testable import PacerCore

/// `ResolvedRoot.rootPath(forFile:among:)` — how a bulk importer rediscovers
/// the root a transcript was found under. It must hand back exactly what
/// `JSONLScanner` stamps (`root.path`), since `AccountTrail` keys on the string.
@Suite("Root of a transcript file")
struct RootPathForFileTests {

    private func root(_ config: String) -> ClaudePathResolver.ResolvedRoot {
        let url = URL(fileURLWithPath: config)
        return .init(root: url, projectsDirectory: url.appendingPathComponent("projects"))
    }

    @Test("a file maps to its config root, not its projects directory")
    func mapsToConfigRoot() {
        let roots = [root("/profiles/1"), root("/profiles/2")]
        #expect(ClaudePathResolver.ResolvedRoot.rootPath(
            forFile: "/profiles/2/projects/-code-acme/s.jsonl", among: roots) == "/profiles/2")
    }

    @Test("a trailing slash on a root does not change the answer")
    func trailingSlashIsIgnored() {
        let slashed = ClaudePathResolver.ResolvedRoot(
            root: URL(fileURLWithPath: "/profiles/2/", isDirectory: true),
            projectsDirectory: URL(fileURLWithPath: "/profiles/2/projects/", isDirectory: true))
        #expect(ClaudePathResolver.ResolvedRoot.rootPath(
            forFile: "/profiles/2/projects/a/s.jsonl", among: [slashed]) == "/profiles/2")
    }

    @Test("a sibling directory sharing a prefix is not inside the root")
    func requiresPathBoundary() {
        #expect(ClaudePathResolver.ResolvedRoot.rootPath(
            forFile: "/profiles/2/projects-old/s.jsonl", among: [root("/profiles/2")]) == nil)
    }

    @Test("nested roots resolve to the longest match")
    func longestRootWins() {
        let outer = root("/data")
        let inner = ClaudePathResolver.ResolvedRoot(
            root: URL(fileURLWithPath: "/data/projects/pinned"),
            projectsDirectory: URL(fileURLWithPath: "/data/projects/pinned/projects"))
        #expect(ClaudePathResolver.ResolvedRoot.rootPath(
            forFile: "/data/projects/pinned/projects/a/s.jsonl", among: [outer, inner])
                == "/data/projects/pinned")
        #expect(ClaudePathResolver.ResolvedRoot.rootPath(
            forFile: "/data/projects/a/s.jsonl", among: [outer, inner]) == "/data")
    }
}
