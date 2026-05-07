import Foundation

/// Normalizes a Claude Code JSONL `cwd` so usage from agents spawned
/// inside a worktree gets attributed to the parent project they
/// branched from — instead of showing up as its own one-session
/// "project" with a hash name like `agent-aef4a72`.
///
/// What it strips, in priority order:
///
///   `/path/to/repo/.claude/worktrees/<id>(/...)?` → `/path/to/repo`
///   `/path/to/repo/.worktrees/<id>(/...)?`         → `/path/to/repo`
///
/// Both patterns are common conventions — Claude Code's own subagent
/// system creates worktrees under `.claude/worktrees`, and many
/// people put hand-managed worktrees under `.worktrees` at the repo
/// root.
///
/// We do NOT touch the filesystem. The JSONL was potentially written
/// weeks ago and the worktree dir may not exist anymore; pure string
/// canonicalization is robust against that.
public enum ProjectPathCanonicalizer {

    /// Canonicalize the path. Returns the input unchanged when no
    /// known worktree segment is present.
    public static func canonicalize(_ path: String) -> String {
        // Patterns must match the worktree segment AND the agent dir
        // that follows it — otherwise we'd strip down to ".claude" or
        // ".worktrees" and lose the parent path entirely.
        // Order matters: `.claude/worktrees` must be checked first
        // because matching `.worktrees` alone would consume the wrong
        // chunk on a path that contains both.
        for pattern in [
            #"/\.claude/worktrees/[^/]+"#,
            #"/\.worktrees/[^/]+"#,
        ] {
            if let range = path.range(of: pattern, options: .regularExpression) {
                // Truncate at the start of the matched segment. Anything
                // after the matched agent-id directory (`/foo/bar` paths
                // inside the worktree) is dropped along with the
                // worktree itself.
                return String(path[..<range.lowerBound])
            }
        }
        return path
    }
}
