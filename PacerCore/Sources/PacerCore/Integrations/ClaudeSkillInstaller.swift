import Foundation
import CryptoKit

/// Installs Pacer's Claude Code skill into the user's `~/.claude/skills/`.
///
/// The skill is a directory of Markdown + shell that teaches an agent to read
/// Pacer's local API and pace a long run against the rate-limit windows. It
/// ships *inside* `Pacer.app`, which is what makes "it updates when Pacer
/// updates" true: a Sparkle update replaces the bundled copy, and the next
/// launch re-syncs the installed one.
///
/// Three rules this type exists to keep:
///
/// - **Installing is a click, never a launch side effect.** `~/.claude` is the
///   user's own configuration, shared with every other tool they run. Pacer
///   writes into it when asked and not before.
/// - **A file the user edited is theirs.** The manifest records a hash of
///   every file as installed, so an auto-refresh can tell "Pacer's copy, one
///   version old" from "the user's copy, edited". It only overwrites the
///   former, and Settings offers to overwrite the latter explicitly.
/// - **Uninstall removes what we put there and nothing else.** It reads the
///   manifest and deletes those paths, then the now-empty directory. A blanket
///   `removeItem` on a path under `~/.claude` is exactly the wrong shape.
public struct ClaudeSkillInstaller: Sendable {

    /// Directory name under `~/.claude/skills/`, and the skill's `name:` in
    /// its own front matter. They must agree — Claude Code resolves a skill by
    /// its directory.
    public static let skillName = "pacer"

    /// Where the skill sits inside the app bundle's `Resources`.
    public static let bundledSubpath = "Skills/\(skillName)"

    /// The always-on half of the skill: a few lines a user imports into their
    /// own `CLAUDE.md` so an agent knows pacing exists *before* it decides
    /// whether to look for a skill.
    ///
    /// A skill loads when its description matches the work at hand, which is
    /// the right default and the wrong one for exactly this case — the moment
    /// pacing matters is a long autonomous run, which is when nothing is
    /// thinking about usage.
    public static let importFileName = "pacing.md"

    /// The line to paste. A *pointer*, never the content: the file it names
    /// ships inside the app and is replaced on every update, so what it says
    /// stays current without anyone re-pasting anything. Pasting the prose
    /// itself is how the instructions this replaced went stale.
    public static var claudeMdImportLine: String {
        "@~/.claude/skills/\(skillName)/\(importFileName)"
    }

    /// Records what was installed, so an update knows whether the files on
    /// disk are still ours. Lives inside the installed directory; hidden so it
    /// does not read as part of the skill.
    public static let manifestName = ".pacer-install.json"

    public struct Manifest: Codable, Sendable, Equatable {
        public let version: String
        /// Relative path → SHA-256 of the bytes Pacer wrote.
        public let files: [String: String]
    }

    public enum State: Equatable, Sendable {
        /// No bundled copy — a build without the resource, not a user state.
        case unavailable
        case notInstalled
        case upToDate
        /// Installed, unmodified, from an older Pacer.
        case outdated(installed: String)
        /// The user (or something else) changed a file. Never overwritten
        /// without an explicit click.
        case modified(installed: String)
        /// Something is at the install path that Pacer did not put there.
        case foreign
    }

    public struct Status: Equatable, Sendable {
        public let state: State
        public let bundledVersion: String
        public let destination: URL

        public init(state: State, bundledVersion: String, destination: URL) {
            self.state = state
            self.bundledVersion = bundledVersion
            self.destination = destination
        }

        public var isInstalled: Bool {
            switch state {
            case .notInstalled, .unavailable: return false
            default: return true
            }
        }

        /// Whether a refresh would do anything, ignoring locally-modified
        /// files (which a refresh deliberately leaves alone).
        public var needsRefresh: Bool {
            if case .outdated = state { return true }
            return false
        }
    }

    /// The bundled skill directory.
    public let source: URL
    /// Where it gets installed — `~/.claude/skills/pacer`.
    public let destination: URL
    /// Stamped into the manifest so "outdated" is a comparison, not a guess.
    public let version: String

    public init(source: URL, destination: URL, version: String) {
        self.source = source
        self.destination = destination
        self.version = version
    }

    /// The real installer for a running app. `nil` when the bundle carries no
    /// skill, which is what a `swift build` of PacerCore alone looks like.
    public static func bundled(_ bundle: Bundle = .main,
                               home: URL? = nil) -> ClaudeSkillInstaller? {
        guard let resources = bundle.resourceURL else { return nil }
        let source = resources.appendingPathComponent(bundledSubpath, isDirectory: true)
        guard FileManager.default.fileExists(
            atPath: source.appendingPathComponent("SKILL.md").path) else { return nil }
        let root = home ?? FileManager.default.homeDirectoryForCurrentUser
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return ClaudeSkillInstaller(
            source: source,
            destination: root.appendingPathComponent(".claude/skills/\(skillName)", isDirectory: true),
            version: "\(short) (\(build))")
    }

    // MARK: - Status

    public func status() -> Status {
        let fm = FileManager.default
        guard sourceFiles() != nil else {
            return Status(state: .unavailable, bundledVersion: version, destination: destination)
        }
        guard fm.fileExists(atPath: destination.path) else {
            return Status(state: .notInstalled, bundledVersion: version, destination: destination)
        }
        guard let manifest = readManifest() else {
            // Something else owns this path — a hand-rolled skill of the same
            // name, most likely. Say so rather than clobbering it.
            return Status(state: .foreign, bundledVersion: version, destination: destination)
        }
        for (relative, expected) in manifest.files {
            guard let actual = hashOfInstalledFile(relative), actual == expected else {
                return Status(state: .modified(installed: manifest.version),
                              bundledVersion: version, destination: destination)
            }
        }
        return Status(state: manifest.version == version ? .upToDate
                        : .outdated(installed: manifest.version),
                      bundledVersion: version, destination: destination)
    }

    // MARK: - Mutations

    /// Copy every bundled file over, replacing what is there, and record what
    /// was written. Used by the install button and by "overwrite my changes".
    public func install() throws {
        guard let files = sourceFiles() else { throw Error.noBundledSkill }
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        var hashes: [String: String] = [:]
        for relative in files {
            let from = source.appendingPathComponent(relative)
            let to = destination.appendingPathComponent(relative)
            try fm.createDirectory(at: to.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            let data = try Data(contentsOf: from)
            try data.write(to: to, options: .atomic)
            // Xcode's resource copy does not reliably carry the executable
            // bit, and a skill whose script cannot be run is a puzzle rather
            // than an error message. Set it here from the file's own name.
            try fm.setAttributes([.posixPermissions: relative.hasSuffix(".sh") ? 0o755 : 0o644],
                                 ofItemAtPath: to.path)
            hashes[relative] = Self.hash(data)
        }
        try writeManifest(Manifest(version: version, files: hashes))
    }

    /// Remove exactly the files this installer wrote, then the directory if
    /// nothing else is left in it. Refuses a path with no manifest.
    public func uninstall() throws {
        guard let manifest = readManifest() else { throw Error.notOurs }
        let fm = FileManager.default
        for relative in manifest.files.keys {
            let path = destination.appendingPathComponent(relative)
            try? fm.removeItem(at: path)
        }
        try? fm.removeItem(at: destination.appendingPathComponent(Self.manifestName))
        // Only if the user has not left something of their own behind.
        if let remaining = try? fm.contentsOfDirectory(atPath: destination.path),
           remaining.isEmpty {
            try? fm.removeItem(at: destination)
        }
    }

    /// Re-sync an installed, unmodified skill after a Pacer update. Returns
    /// true when it actually wrote something.
    ///
    /// Deliberately narrow: it does nothing when the skill is absent (that is
    /// the user's choice), when a file was edited (that is the user's copy), or
    /// when the path belongs to something else.
    @discardableResult
    public func refreshIfInstalled() throws -> Bool {
        guard status().needsRefresh else { return false }
        try install()
        return true
    }

    public enum Error: Swift.Error, Sendable, Equatable {
        case noBundledSkill
        case notOurs
    }

    // MARK: - Files

    /// Relative paths of everything shipped, sorted. `nil` when the bundled
    /// directory is missing or empty. Hidden files are skipped so a stray
    /// `.DS_Store` never becomes part of the skill.
    func sourceFiles() -> [String]? {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles]) else { return nil }
        var out: [String] = []
        let prefix = source.standardizedFileURL.path
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix + "/") else { continue }
            out.append(String(path.dropFirst(prefix.count + 1)))
        }
        return out.isEmpty ? nil : out.sorted()
    }

    private func hashOfInstalledFile(_ relative: String) -> String? {
        guard let data = try? Data(contentsOf: destination.appendingPathComponent(relative))
        else { return nil }
        return Self.hash(data)
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func readManifest() -> Manifest? {
        guard let data = try? Data(contentsOf: destination.appendingPathComponent(Self.manifestName))
        else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    private func writeManifest(_ manifest: Manifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: destination.appendingPathComponent(Self.manifestName), options: .atomic)
    }
}
