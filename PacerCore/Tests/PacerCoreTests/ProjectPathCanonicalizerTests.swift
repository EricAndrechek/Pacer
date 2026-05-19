import Testing
@testable import PacerCore

@Suite struct ProjectPathCanonicalizerTests {
    @Test func plainPathPassesThrough() {
        #expect(ProjectPathCanonicalizer.canonicalize("/Users/eric/Code/foo")
                == "/Users/eric/Code/foo")
    }

    @Test func claudeCodeAgentWorktree() {
        #expect(
            ProjectPathCanonicalizer.canonicalize(
                "/Users/eric/Code/foo/.claude/worktrees/agent-aef4a721"
            ) == "/Users/eric/Code/foo"
        )
    }

    @Test func claudeCodeAgentWorktreeWithNestedPath() {
        // The parsed cwd can be deeper than the worktree root if the
        // session cd'd into a subdirectory inside the agent's working
        // copy. Everything from the worktree segment onwards gets
        // dropped.
        #expect(
            ProjectPathCanonicalizer.canonicalize(
                "/Users/eric/Code/foo/.claude/worktrees/agent-x/src/lib"
            ) == "/Users/eric/Code/foo"
        )
    }

    @Test func dotWorktreesConvention() {
        #expect(
            ProjectPathCanonicalizer.canonicalize(
                "/Users/eric/Code/foo/.worktrees/feature-branch"
            ) == "/Users/eric/Code/foo"
        )
    }

    @Test func dotWorktreesNestedPath() {
        #expect(
            ProjectPathCanonicalizer.canonicalize(
                "/Users/eric/Code/foo/.worktrees/feature-branch/src/main.swift"
            ) == "/Users/eric/Code/foo"
        )
    }

    @Test func emptyAndSpecialPaths() {
        #expect(ProjectPathCanonicalizer.canonicalize("") == "")
        #expect(ProjectPathCanonicalizer.canonicalize("/") == "/")
        // A literal "/.claude/worktrees" with no agent id afterwards
        // doesn't match — the regex requires an id segment to be safe.
        #expect(
            ProjectPathCanonicalizer.canonicalize("/Users/eric/.claude/worktrees")
                == "/Users/eric/.claude/worktrees"
        )
    }

    @Test func bothPatternsInPathPrefersClaudeWorktrees() {
        // If both patterns appear (unlikely but possible), the longer
        // .claude/worktrees match takes precedence. Either one is a
        // reasonable answer; the test pins the behavior.
        #expect(
            ProjectPathCanonicalizer.canonicalize(
                "/Users/eric/foo/.claude/worktrees/a/.worktrees/b"
            ) == "/Users/eric/foo"
        )
    }

    // MARK: - User-defined aliases

    @Test func aliasResolvesAfterWorktreeStrip() {
        // The folder-rename case: ccmac → Pacer.
        let aliases = [
            "/Users/eric/Code/public-projects/ccmac":
                "/Users/eric/Code/public-projects/Pacer",
        ]
        #expect(
            ProjectPathCanonicalizer.canonicalize(
                "/Users/eric/Code/public-projects/ccmac",
                aliases: aliases
            ) == "/Users/eric/Code/public-projects/Pacer"
        )
    }

    @Test func aliasAppliesAfterWorktreeStripping() {
        // Worktree strip happens FIRST, so the alias matches the
        // post-strip path. Without this ordering an alias would have
        // to mention every worktree subpath separately.
        let aliases = [
            "/Users/eric/Code/ccmac": "/Users/eric/Code/Pacer",
        ]
        #expect(
            ProjectPathCanonicalizer.canonicalize(
                "/Users/eric/Code/ccmac/.claude/worktrees/agent-abc/src",
                aliases: aliases
            ) == "/Users/eric/Code/Pacer"
        )
    }

    @Test func aliasChainResolvesTransitively() {
        // A → B → C should resolve to C.
        let aliases = [
            "/path/A": "/path/B",
            "/path/B": "/path/C",
        ]
        #expect(
            ProjectPathCanonicalizer.canonicalize("/path/A", aliases: aliases) == "/path/C"
        )
        #expect(
            ProjectPathCanonicalizer.canonicalize("/path/B", aliases: aliases) == "/path/C"
        )
    }

    @Test func aliasUnmappedPathPassesThrough() {
        let aliases = ["/path/A": "/path/B"]
        #expect(
            ProjectPathCanonicalizer.canonicalize("/path/elsewhere", aliases: aliases)
                == "/path/elsewhere"
        )
    }

    @Test func aliasCycleTerminatesSafely() {
        // A → B → A. canonicalize must not loop forever or crash; it
        // returns SOME path (the cycle's visit order determines which).
        let aliases = [
            "/path/A": "/path/B",
            "/path/B": "/path/A",
        ]
        let result = ProjectPathCanonicalizer.canonicalize("/path/A", aliases: aliases)
        #expect(result == "/path/A" || result == "/path/B")
    }

    @Test func aliasSelfLoopIsNoOp() {
        // The manager API rejects self-aliases at write time, but the
        // canonicalizer's job is to be defensive against bad state on
        // disk — round-trip a self-alias as identity.
        let aliases = ["/path/X": "/path/X"]
        #expect(
            ProjectPathCanonicalizer.canonicalize("/path/X", aliases: aliases) == "/path/X"
        )
    }

    @Test func siblingWorktreeAlias() {
        // The use case the regex CAN'T handle: a worktree at a sibling
        // directory rather than inside the parent repo.
        let aliases = [
            "/Users/eric/Code/repo-feature-x": "/Users/eric/Code/repo",
        ]
        #expect(
            ProjectPathCanonicalizer.canonicalize(
                "/Users/eric/Code/repo-feature-x",
                aliases: aliases
            ) == "/Users/eric/Code/repo"
        )
    }
}
