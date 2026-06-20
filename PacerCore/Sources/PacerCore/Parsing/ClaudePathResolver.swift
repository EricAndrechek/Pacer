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

    private func parseConfigDirOverride(_ raw: String) -> [ResolvedRoot] {
        var seen = Set<URL>()
        var results: [ResolvedRoot] = []
        for piece in raw.split(separator: ",", omittingEmptySubsequences: true) {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let url = URL(fileURLWithPath: trimmed).standardizedFileURL
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
            let standardized = candidate.standardizedFileURL
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
        return ResolvedRoot(root: root, projectsDirectory: projects)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
