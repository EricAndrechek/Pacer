import Foundation

/// Normalizes a Claude Code JSONL `cwd` so usage from agents spawned
/// inside a worktree gets attributed to the parent project they
/// branched from — instead of showing up as its own one-session
/// "project" with a hash name like `agent-aef4a72`.
///
/// Two layers, applied in order:
///
/// 1. **Worktree-segment stripping** (regex; automatic; always on):
///
///        /path/to/repo/.claude/worktrees/<id>(/...)?  → /path/to/repo
///        /path/to/repo/.worktrees/<id>(/...)?         → /path/to/repo
///
///    These are common conventions — Claude Code's own subagent system
///    writes to `.claude/worktrees/`, and many people put hand-managed
///    worktrees under `.worktrees/` at the repo root.
///
/// 2. **User-defined aliases** (`[sourcePath: canonicalPath]`; opt-in):
///    Handles cases the regex cannot — folder renames after-the-fact
///    (`~/Code/ccmac` → `~/Code/Pacer`), sibling-directory worktrees
///    (`~/Code/repo-feature-x` → `~/Code/repo`), cross-machine path
///    differences after a SwiftData restore. Aliases resolve
///    transitively (A→B and B→C ⇒ A→C) with a hard cap on chain depth
///    to terminate cycles introduced by a buggy UI or test.
///
/// We do NOT touch the filesystem. The JSONL was potentially written
/// weeks ago and the worktree dir may not exist anymore; pure string
/// canonicalization is robust against that.
public enum ProjectPathCanonicalizer {

    /// Max alias-chain depth. The legitimate use case is "A→B→C" (a
    /// folder renamed once then moved); 32 is well past anything a real
    /// user would set up by hand and well below the recursion-depth /
    /// loop-time at which a buggy alias graph would degrade the scan.
    /// Hitting the cap returns the last resolved path — the user gets
    /// stable behavior plus a log line, never a crash.
    public static let maxAliasChainDepth = 32

    /// Canonicalize the path with no aliases. Convenience overload used
    /// in unit tests and in code paths that haven't been threaded yet.
    /// In production every JSONL line goes through the aliases-aware
    /// overload below.
    public static func canonicalize(_ path: String) -> String {
        canonicalize(path, aliases: [:])
    }

    /// Canonicalize with both worktree-stripping AND user aliases.
    ///
    /// `aliases` keys are post-worktree-strip paths, matching what the
    /// scanner persists for unaliased samples. Resolution chases the
    /// chain until either:
    ///   - the current key has no alias entry, OR
    ///   - we exceed `maxAliasChainDepth` (cycle / pathological graph), OR
    ///   - we revisit a path we've already seen in this resolution.
    ///
    /// Both terminal conditions return the last good value — never a
    /// throw, never a nil — so a misconfigured alias never breaks the
    /// scan.
    public static func canonicalize(_ path: String, aliases: [String: String]) -> String {
        let stripped = stripWorktreeSegment(path)
        return resolveAlias(stripped, aliases: aliases)
    }

    private static func stripWorktreeSegment(_ path: String) -> String {
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

    private static func resolveAlias(
        _ path: String,
        aliases: [String: String]
    ) -> String {
        if aliases.isEmpty { return path }
        var current = path
        var visited: Set<String> = []
        for _ in 0..<maxAliasChainDepth {
            guard let next = aliases[current] else { return current }
            // Self-alias is a no-op (UI-validated against, but defensive
            // here). Cycle detection: if we ever revisit a path we've
            // already resolved through, stop with the current value
            // rather than looping.
            if next == current { return current }
            if !visited.insert(current).inserted { return current }
            current = next
        }
        // Exceeded depth cap — buggy alias graph. Return last value and
        // log so the user can audit their alias table.
        Log.write("ProjectPathCanonicalizer",
                  "alias chain exceeded depth \(maxAliasChainDepth) starting from \(path)")
        return current
    }
}
