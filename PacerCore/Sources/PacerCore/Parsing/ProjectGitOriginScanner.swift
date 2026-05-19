import Foundation

/// Suggests `ProjectPathAlias` rows by detecting when two project
/// paths Pacer has seen share the same `.git/config remote.origin.url`.
///
/// Two real-world scenarios this catches that the worktree-stripping
/// regex doesn't:
///   1. **Folder rename after-the-fact.** The user renamed
///      `~/Code/ccmac` to `~/Code/Pacer`. Both directories may still
///      exist (Claude Code's `~/.claude/projects/` keeps historical
///      JSONL keyed on the old absolute path). Only `~/Code/Pacer`
///      currently exists on disk, but its `.git/config` carries the
///      same origin URL as the historical activity at the old path.
///      We can't read `~/Code/ccmac/.git/config` (the directory is
///      gone), but we CAN read the new path and check whether any
///      OTHER known project path is "obviously the predecessor" by
///      looking at the basename of the historical path. (We don't
///      currently do that deeper inference — see "Deliberate
///      simplicity" below.)
///   2. **Sibling-directory worktrees.** `~/Code/repo` and
///      `~/Code/repo-feature-x` both exist on disk, both have a
///      `.git/config`, both point at the same origin. The scanner
///      surfaces this pair to the user with a one-click merge.
///
/// **Deliberate simplicity**: this is a *suggestion* engine, not an
/// authoritative path graph. We read `.git/config` files synchronously
/// during the suggest pass, time-bounded by a small budget, and skip
/// anything we can't read. The user always confirms before an alias
/// is written.
public enum ProjectGitOriginScanner {

    public struct Suggestion: Identifiable, Hashable, Sendable {
        /// Path the alias would map FROM. Heuristic: whichever side has
        /// fewer historical samples gets suggested as the source so
        /// merging produces the larger "canonical" view.
        public let suggestedSource: String
        /// Path the alias would map TO.
        public let suggestedCanonical: String
        /// The shared origin URL, shown to the user for context.
        public let originURL: String

        public var id: String {
            // Order the two paths so the same pair always gets the
            // same id even if we surface them with source/canonical
            // swapped — keeps the "dismissed" set stable across
            // launches.
            let pair = [suggestedSource, suggestedCanonical].sorted()
            return "\(pair[0])||\(pair[1])||\(originURL)"
        }
    }

    /// For every pair of `projectPaths` whose on-disk `.git/config`
    /// declares the same `remote.origin.url`, emit one suggestion.
    /// Skips:
    ///   - paths that don't currently exist on disk
    ///   - paths without a `.git/config`
    ///   - paths already mapped (the `existingAliasedSources` set)
    ///   - pairs where neither path can be read
    ///   - self-pairs (path == path)
    ///
    /// Suggestions are deduped: each "pair of paths sharing this
    /// origin" is reported once. Pair ordering picks the source as the
    /// alphabetically-later path to keep results deterministic — the
    /// canonical is whichever sorts earlier — but the user can edit
    /// before accepting.
    public static func suggest(
        projectPaths: [String],
        existingAliasedSources: Set<String> = []
    ) async -> [Suggestion] {
        // Group existing-on-disk paths by their git remote origin URL.
        // We read serially with a short budget (~50 paths × a single
        // small file read each = trivial); doing this on a background
        // task keeps the main thread free while the user opens
        // Settings.
        var byOrigin: [String: [String]] = [:]
        for path in projectPaths {
            if existingAliasedSources.contains(path) { continue }
            guard let origin = await readGitOrigin(at: path) else { continue }
            byOrigin[origin, default: []].append(path)
        }
        var out: [Suggestion] = []
        for (origin, paths) in byOrigin where paths.count >= 2 {
            // For each origin shared by 2+ paths, emit (n choose 2)
            // pairs. With 2 paths that's one suggestion. With 3+
            // (uncommon: a repo cloned three times) we surface them
            // all so the user can merge each pair individually.
            let sorted = paths.sorted()
            for i in 0..<sorted.count {
                for j in (i + 1)..<sorted.count {
                    let canonical = sorted[i]
                    let source = sorted[j]
                    out.append(Suggestion(
                        suggestedSource: source,
                        suggestedCanonical: canonical,
                        originURL: origin
                    ))
                }
            }
        }
        return out.sorted { $0.id < $1.id }
    }

    /// Read `<path>/.git/config` and parse out the `[remote "origin"]
    /// → url` line. Returns nil if the file is missing or doesn't have
    /// a remote.origin section.
    ///
    /// Handles three on-disk shapes:
    ///
    /// 1. Normal repo: `<path>/.git/` is a directory containing
    ///    `config`. Read it.
    ///
    /// 2. Git worktree (`git worktree add`): `<path>/.git` is a FILE
    ///    containing `gitdir: <abs-or-rel-path>`. The pointed-at
    ///    `gitdir` is `<main-repo>/.git/worktrees/<name>`; the
    ///    config we care about lives at `<main-repo>/.git/config`
    ///    (two directories above gitdir). Without this fallback,
    ///    worktree paths get nil origin URLs and never pair with
    ///    their main checkout for the sibling-merge pass.
    ///
    /// 3. Anything else: return nil. The user can still create the
    ///    alias manually.
    static func readGitOrigin(at projectPath: String) async -> String? {
        let gitURL = URL(fileURLWithPath: projectPath).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitURL.path, isDirectory: &isDir) else {
            return nil
        }
        let configURL: URL
        if isDir.boolValue {
            configURL = gitURL.appendingPathComponent("config")
        } else {
            // Worktree case: parse `.git` to find the gitdir
            // pointer, then derive the main repo's config path.
            guard let resolved = resolveWorktreeConfigURL(gitFileURL: gitURL) else {
                return nil
            }
            configURL = resolved
        }
        guard let data = try? Data(contentsOf: configURL),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return parseOriginURL(from: text)
    }

    /// Given a worktree's `.git` file URL, parse it for the
    /// `gitdir:` pointer and return the main repo's
    /// `<main-repo>/.git/config` URL. Supports both absolute and
    /// relative `gitdir` values (git emits absolute by default but
    /// relative is valid).
    private static func resolveWorktreeConfigURL(gitFileURL: URL) -> URL? {
        guard let text = try? String(contentsOf: gitFileURL, encoding: .utf8) else {
            return nil
        }
        var gitdir: String?
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("gitdir:") {
                gitdir = String(line.dropFirst("gitdir:".count))
                    .trimmingCharacters(in: .whitespaces)
                break
            }
        }
        guard let raw = gitdir, !raw.isEmpty else { return nil }
        let gitdirURL: URL
        if raw.hasPrefix("/") {
            gitdirURL = URL(fileURLWithPath: raw)
        } else {
            // Relative paths resolve against the directory holding
            // the `.git` file (i.e. the worktree dir).
            gitdirURL = URL(fileURLWithPath: raw,
                            relativeTo: gitFileURL.deletingLastPathComponent())
                .standardizedFileURL
        }
        // `<main>/.git/worktrees/<name>` → `<main>/.git/config`
        // i.e. two `..` then `config`.
        return gitdirURL
            .deletingLastPathComponent()       // .git/worktrees
            .deletingLastPathComponent()       // .git
            .appendingPathComponent("config")
    }

    /// Pure parser for testability. Walks the INI lines looking for
    /// `[remote "origin"]` and the first `url =` line under it.
    static func parseOriginURL(from text: String) -> String? {
        var inOrigin = false
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                // New section — track whether it's [remote "origin"].
                inOrigin = line == "[remote \"origin\"]"
                continue
            }
            guard inOrigin else { continue }
            if line.hasPrefix("url") {
                // Split on first `=` and trim; supports both `url=foo`
                // and `url = foo`.
                if let eq = line.firstIndex(of: "=") {
                    let value = line[line.index(after: eq)...]
                        .trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty { return value }
                }
            }
        }
        return nil
    }
}
