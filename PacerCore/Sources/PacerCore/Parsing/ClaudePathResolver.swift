import Foundation

/// Resolves the on-disk locations Claude Code may write its session JSONL
/// files to. Replicates ccusage's `getClaudePaths()` algorithm exactly:
///
///   1. If `CLAUDE_CONFIG_DIR` is set, parse it as a comma-separated list.
///      Each path must contain a `projects/` subdirectory or it is invalid.
///      If the variable is set but no path is valid, throw — do NOT fall
///      back. ccusage chose this behavior so a misconfigured override
///      doesn't silently scan the legacy default and report wrong totals.
///   2. Otherwise, return the union of any of the following that exist
///      and contain a `projects/` subdirectory:
///        - `${XDG_CONFIG_HOME:-$HOME/.config}/claude`
///        - `$HOME/.claude`
///      Both paths are checked; ccusage and Pacer aggregate JSONL files
///      across them rather than picking one. Claude Code 1.0.30 changed
///      the default location undocumentedly, and 2.1.x still writes to
///      `~/.claude` on macOS in practice — the union is the only way to
///      stay correct across both layouts.
public struct ClaudePathResolver: @unchecked Sendable {
    // @unchecked: immutable value type; the only non-Sendable stored
    // member is `FileManager`, and `FileManager.default` is documented
    // thread-safe. Lets `ScanCoordinator`'s nonisolated init store it.


    public enum ResolutionError: Error, Sendable, Equatable {
        /// `CLAUDE_CONFIG_DIR` was set, but every comma-separated path was
        /// either missing or lacked a `projects/` subdirectory.
        case configDirOverrideHasNoValidPaths(rawValue: String)
    }

    /// One Claude Code data root. The `projectsDirectory` is what we glob
    /// `**/*.jsonl` against; the `root` is retained for diagnostics.
    public struct ResolvedRoot: Sendable, Equatable, Hashable {
        public let root: URL
        public let projectsDirectory: URL
        /// The project every turn under this root is counted as, in place of
        /// its `cwd`; nil (every ordinary root) keeps the `cwd`. Claude
        /// Desktop's agent-mode roots set it, because what they record as
        /// `cwd` is a sandbox name. See `DesktopSessionDirectory`.
        public let fixedProjectPath: String?

        public init(root: URL, projectsDirectory: URL, fixedProjectPath: String? = nil) {
            self.root = root
            self.projectsDirectory = projectsDirectory
            self.fixedProjectPath = fixedProjectPath
        }

        /// The `rootPath` `JSONLScanner` stamps on a turn read from `file`: the
        /// config root (not the `projects/` directory) of the root the file
        /// sits under, as `root.path` verbatim, because `AccountTrail` keys
        /// its pinned spans on that exact string.
        ///
        /// A bulk importer sees only file paths, so it has to rediscover which
        /// root each one belonged to; this is that join, kept here so it cannot
        /// drift from the line parser's. Containment is decided on
        /// `canonicalPathURL` paths plus a `/` boundary (so `projects-old` is
        /// not under `projects`), and the longest matching `projects/` wins
        /// when roots nest. nil when no root contains the file.
        public static func rootPath(forFile file: String, among roots: [ResolvedRoot]) -> String? {
            root(forFile: file, among: roots)?.root.path
        }

        /// The root `rootPath(forFile:among:)` names, whole, for a caller that
        /// also needs its `fixedProjectPath`.
        public static func root(forFile file: String, among roots: [ResolvedRoot]) -> ResolvedRoot? {
            let filePath = URL(fileURLWithPath: file).canonicalPathURL.path
            var best: (length: Int, root: ResolvedRoot)?
            for candidate in roots {
                let directory = candidate.projectsDirectory.canonicalPathURL.path
                let prefix = directory.hasSuffix("/") ? directory : directory + "/"
                guard filePath.hasPrefix(prefix),
                      best == nil || prefix.count > best!.length else { continue }
                best = (prefix.count, candidate)
            }
            return best?.root
        }

        /// The project a turn read from this root is counted as: the fixed one
        /// when the root has one, else its `cwd` canonicalized. One rule for
        /// the line parser and the bulk importer, so the two cannot disagree.
        public func projectPath(forCwd cwd: String?, aliases: [String: String]) -> String? {
            if let fixedProjectPath {
                return ProjectPathCanonicalizer.canonicalize(fixedProjectPath, aliases: aliases)
            }
            return cwd.map { ProjectPathCanonicalizer.canonicalize($0, aliases: aliases) }
        }
    }

    private let environment: [String: String]
    private let homeDirectory: URL
    private let fileManager: FileManager

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
    }

    /// The data root whose global config names the default login: the first
    /// `CLAUDE_CONFIG_DIR` entry when it is set, nil for the home layout
    /// (`~/.claude.json`). The attribution trail reads that config and the
    /// login watcher watches it, so both take it from here and cannot
    /// disagree about which file is the login.
    ///
    /// No `projects/` requirement, unlike `resolve()`: a login exists before
    /// any transcript does.
    public var loginConfigRoot: URL? {
        guard let raw = environment["CLAUDE_CONFIG_DIR"], !raw.isEmpty else { return nil }
        let first = raw.split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return first.map { URL(fileURLWithPath: $0).canonicalPathURL }
    }

    public func resolve() throws -> [ResolvedRoot] {
        if let raw = environment["CLAUDE_CONFIG_DIR"], !raw.isEmpty {
            let valid = parseConfigDirOverride(raw)
            if valid.isEmpty {
                throw ResolutionError.configDirOverrideHasNoValidPaths(rawValue: raw)
            }
            return valid
        }
        return defaultRoots()
    }

    /// Validate roots discovered by some means other than the environment —
    /// today, an external switcher's per-account session profiles.
    ///
    /// Pacer is a background agent and never has `CLAUDE_CONFIG_DIR` set, so
    /// `resolve()` structurally cannot see a profile a *terminal* pinned. It
    /// applies the same `projects/` requirement as every other root and
    /// silently drops anything that fails, because a discovered path is a
    /// guess about another tool's layout and must never be able to break the
    /// scan.
    public func resolveAdditional(_ roots: [URL]) -> [ResolvedRoot] {
        var seen = Set<URL>()
        var results: [ResolvedRoot] = []
        for url in roots {
            let standardized = url.canonicalPathURL
            guard seen.insert(standardized).inserted else { continue }
            if let resolved = try? validate(root: standardized) {
                results.append(resolved)
            }
        }
        return results
    }

    private func parseConfigDirOverride(_ raw: String) -> [ResolvedRoot] {
        var seen = Set<URL>()
        var results: [ResolvedRoot] = []
        for piece in raw.split(separator: ",", omittingEmptySubsequences: true) {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let url = URL(fileURLWithPath: trimmed).canonicalPathURL
            guard !seen.contains(url) else { continue }
            seen.insert(url)
            if let resolved = try? validate(root: url) {
                results.append(resolved)
            }
        }
        return results
    }

    private func defaultRoots() -> [ResolvedRoot] {
        var seen = Set<URL>()
        var results: [ResolvedRoot] = []

        let xdgBase: URL
        if let raw = environment["XDG_CONFIG_HOME"], !raw.isEmpty {
            xdgBase = URL(fileURLWithPath: raw)
        } else {
            xdgBase = homeDirectory.appendingPathComponent(".config")
        }
        let candidates = [
            xdgBase.appendingPathComponent("claude"),
            homeDirectory.appendingPathComponent(".claude"),
        ]

        for candidate in candidates {
            let standardized = candidate.canonicalPathURL
            guard !seen.contains(standardized) else { continue }
            seen.insert(standardized)
            if let resolved = try? validate(root: standardized) {
                results.append(resolved)
            }
        }
        return results
    }

    private func validate(root: URL) throws -> ResolvedRoot {
        // Both the root and a `projects/` subdir must exist as directories.
        // ccusage requires this so a bare `~/.claude` containing only a
        // settings.json doesn't get walked to no effect.
        guard isDirectory(root) else {
            throw NSError(domain: "PacerCore", code: 1)
        }
        let projects = root.appendingPathComponent("projects")
        guard isDirectory(projects) else {
            throw NSError(domain: "PacerCore", code: 2)
        }
        return ResolvedRoot(root: root.canonicalPathURL,
                            projectsDirectory: projects.canonicalPathURL)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
