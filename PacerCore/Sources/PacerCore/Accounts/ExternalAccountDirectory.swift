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
        /// The tool's own slot/label for the account, for provenance in
        /// diagnostics (e.g. "cswap slot 2").
        public let source: String

        public init(organizationId: String, emailAddress: String?,
                    organizationName: String?, source: String) {
            self.organizationId = organizationId
            self.emailAddress = emailAddress
            self.organizationName = organizationName
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
                    source: "claude-swap slot \(slot)"
                ))
            }
            if !result.isEmpty { return result }
        }
        return []
    }
}
