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
}
