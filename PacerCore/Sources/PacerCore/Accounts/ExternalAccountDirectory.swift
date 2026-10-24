import Foundation

/// Human labels for accounts Pacer knows by org id but has never seen logged in.
///
/// Claude Code's `oauthAccount` names exactly one account — whoever is logged
/// in right now. Every *other* account Pacer has discovered (by polling a
/// second token) is therefore an org UUID with no name attached, and two
/// accounts on the same plan derive the identical placeholder. A switcher's
/// roster is the one place that information already exists, so we read it
/// rather than inventing a naming scheme or asking the user to type it twice.
///
/// **Strictly an enrichment.** Nothing depends on a switcher being installed:
/// no directory means accounts keep the labels they already had. And a
/// switcher's roster is never allowed to *establish* identity — it can only
/// attach a name to an org id Pacer resolved for itself from the API. A tool
/// mislabelling a slot can therefore make a label wrong, but never move usage
/// between accounts.
public struct ExternalAccountDirectory: Sendable {
    public struct Entry: Sendable, Equatable {
        /// The `organizationUuid` — matches `Account.id` exactly, which is
        /// what makes this a join rather than a guess.
        public let organizationId: String
        public let emailAddress: String?
        public let organizationName: String?
        /// The switcher's slot number — `cswap switch 2`, "Account 1".
        ///
        /// Borrowed for the same reason the alias is: it is a *choice* the user
        /// made (and can reorder with `cswap swap`/`cswap move`), so listing
        /// accounts in a different order than the tool they switch with is a
        /// small, constant friction.
        public let slot: Int?

        /// The nickname the user set with `cswap alias <n> <name>`.
        ///
        /// The only piece of the roster that is *chosen* rather than observed —
        /// everything else cswap stores (email, org uuid, org name) Pacer
        /// already sees for itself, and the org name is email-derived anyway.
        /// So this is the one field worth borrowing: someone who has already
        /// told their switcher these are "work" and "personal" should not have
        /// to tell Pacer too.
        public let alias: String?
        /// The tool's own slot/label for the account, for provenance in
        /// diagnostics (e.g. "cswap slot 2").
        public let source: String

        public init(organizationId: String, emailAddress: String?,
                    organizationName: String?, alias: String? = nil,
                    slot: Int? = nil, source: String) {
            self.organizationId = organizationId
            self.emailAddress = emailAddress
            self.organizationName = organizationName
            self.alias = alias
            self.slot = slot
            self.source = source
        }
    }

    /// Entries keyed by org id.
    public let entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Read every directory we know how to read. Today that is claude-swap;
    /// adding another is a new `load…` returning the same `Entry` shape.
    public static func discover(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ExternalAccountDirectory {
        var merged: [String: Entry] = [:]
        for entry in loadClaudeSwap(homeDirectory: homeDirectory) {
            // First writer wins, so a later directory can't silently rename
            // an account an earlier one already described.
            if merged[entry.organizationId] == nil {
                merged[entry.organizationId] = entry
            }
        }
        return ExternalAccountDirectory(entries: merged)
    }

    /// Per-account profile directories an external switcher has created —
    /// the ones a session pins `CLAUDE_CONFIG_DIR` to so a second account
    /// can run in parallel with the default login.
    ///
    /// These are outside `~/.claude` entirely, so `ClaudePathResolver` has no
    /// way to find them: it resolves roots from *Pacer's* environment, and
    /// Pacer is a background agent that never has `CLAUDE_CONFIG_DIR` set.
    /// The turns written there are consequently invisible — not
    /// misattributed, which would be worse, but absent, which is still a
    /// silent hole in someone's cost history.
    ///
    /// Only directories that already contain a `projects/` subdirectory are
    /// returned, matching what `ClaudePathResolver` requires of any root: a
    /// profile that exists but has never been used has nothing to scan and
    /// should not be presented as a root.
    public static func discoverProfileRoots(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [URL] {
        var out: [URL] = []
        var seen = Set<String>()
        for parent in profileSessionDirectories(homeDirectory: homeDirectory) {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: parent, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries.sorted(by: { $0.path < $1.path }) {
                var isDir: ObjCBool = false
                let projects = entry.appendingPathComponent("projects")
                guard fileManager.fileExists(atPath: projects.path, isDirectory: &isDir),
                      isDir.boolValue
                else { continue }
                let standardized = entry.canonicalPathURL
                guard seen.insert(standardized.path).inserted else { continue }
                out.append(standardized)
            }
        }
        return out
    }

    /// The folders a switcher keeps its session profiles in, one profile per
    /// subdirectory, whether or not they exist yet: claude-swap's macOS
    /// location and its XDG one, like `loadClaudeSwap`. No disk access.
    ///
    /// The scan watches the ones that exist, so a profile created while Pacer
    /// runs is heard on its first transcript write (#322).
    public static func profileSessionDirectories(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [
            homeDirectory.appendingPathComponent(".claude-swap-backup/sessions"),
            homeDirectory.appendingPathComponent(".local/share/claude-swap/sessions"),
        ].map(\.canonicalPathURL)
    }

    /// When a session profile's own history begins: the creation of its
    /// directory, which every transcript written under it postdates.
    ///
    /// The attribution trail starts a profile's first span here rather than
    /// at the moment Pacer first read its config (#322). A profile is found
    /// *after* its first turns are written — on that turn's write while Pacer
    /// runs, or at the next launch — and a span opened at the sighting left
    /// every turn before it unattributed, because a pinned root never falls
    /// back to the default login.
    ///
    /// nil when no such date belongs to this profile alone: its `projects/`
    /// is a symlink (claude-swap's `--share-history` points it at the default
    /// history), so the transcripts under it are the default login's as much
    /// as this profile's, and stretching the profile's span over them could
    /// only misattribute; or there is no `projects/`, or no date to read.
    public static func historyStart(ofProfile root: URL) -> Date? {
        let projects = root.appendingPathComponent("projects")
        guard let values = try? projects.resourceValues(forKeys: [.isSymbolicLinkKey]),
              values.isSymbolicLink != true
        else { return nil }
        return (try? root.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    /// claude-swap keeps its roster in `sequence.json` under its backup root.
    ///
    /// The macOS/Windows location is `~/.claude-swap-backup`; Linux/WSL
    /// follows XDG. Pacer is macOS-only, so the legacy path is the one that
    /// matters, but `XDG_DATA_HOME` is honoured anyway because it costs one
    /// extra candidate and silently reading the wrong file would be worse.
    static func loadClaudeSwap(homeDirectory: URL) -> [Entry] {
        let candidates = [
            homeDirectory.appendingPathComponent(".claude-swap-backup/sequence.json"),
            homeDirectory.appendingPathComponent(".local/share/claude-swap/sequence.json"),
        ]
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accounts = root["accounts"] as? [String: Any]
            else { continue }

            var result: [Entry] = []
            for (slot, raw) in accounts {
                guard let fields = raw as? [String: Any],
                      let org = fields["organizationUuid"] as? String,
                      !org.isEmpty
                else { continue }
                result.append(Entry(
                    organizationId: org,
                    emailAddress: (fields["email"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    organizationName: (fields["organizationName"] as? String)
                        .flatMap { $0.isEmpty ? nil : $0 },
                    alias: (fields["alias"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    slot: Int(slot),
                    source: "claude-swap slot \(slot)"
                ))
            }
            if !result.isEmpty { return result }
        }
        return []
    }
}
