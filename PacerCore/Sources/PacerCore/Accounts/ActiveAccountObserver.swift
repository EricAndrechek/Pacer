import Foundation

/// Reads which account is currently logged in, for one Claude Code data root.
///
/// Claude Code records the logged-in identity in its global config under
/// `oauthAccount`, and rewrites that object whenever the login changes — a
/// `/login`, a `/logout` and back, or any external switcher swapping the
/// credential underneath it. Watching that one object is therefore enough to
/// notice a switch no matter what caused it, which is the whole point: Pacer
/// should not care which tool the user runs, or whether they run one at all.
///
/// It is deliberately **not** the keychain. The credential blob would tell us
/// a token changed but not whose it is — the account is only knowable by
/// resolving that token against the API, which is `OAuthPoller`'s job and
/// costs a request. `oauthAccount` already carries the org id that Claude
/// Code got from the same place, for free, with no network call and no
/// keychain prompt.
///
/// **Cost.** The config file is large (~180 KB on the maintainer's machine)
/// and this runs on the scan cadence, so every read is gated on the file's
/// modification date. A poll that finds an unchanged mtime does one `stat`
/// and no parse. That matters: a JSON parse of that file on every 20-second
/// cycle is exactly the kind of steady background work that turned into a
/// quarter of a CPU core the last time it went unmeasured.
public struct ActiveAccountObserver: @unchecked Sendable {
    // @unchecked for the same reason `ClaudePathResolver` is: immutable
    // value type whose only non-Sendable member is `FileManager`, and
    // `FileManager.default` is documented thread-safe.
    /// What one config file says about the account using it.
    public struct Observation: Sendable, Equatable {
        /// `oauthAccount.organizationUuid` — the same identifier
        /// `OAuthPoller` derives from the `anthropic-organization-id`
        /// header, and therefore the same value as `Account.id`.
        public let organizationId: String?
        /// `oauthAccount.accountUuid`. Not Pacer's identity key, but it
        /// distinguishes two accounts that somehow share an org.
        public let accountUuid: String?
        /// A human label straight from Claude Code, when present. Lets a
        /// first-run account show as an email rather than a UUID tail
        /// without any external tool being installed.
        public let emailAddress: String?
        public let organizationName: String?
        /// The root this observation came from; nil for the default login.
        public let rootPath: String?

        public init(
            organizationId: String?,
            accountUuid: String?,
            emailAddress: String?,
            organizationName: String?,
            rootPath: String?
        ) {
            self.organizationId = organizationId
            self.accountUuid = accountUuid
            self.emailAddress = emailAddress
            self.organizationName = organizationName
            self.rootPath = rootPath
        }

        /// The `Account.id` this observation implies.
        public var accountKey: String { Account.key(forOrg: organizationId) }
    }

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Candidate global-config locations for a data root, most specific
    /// first. Mirrors Claude Code's own resolution: a legacy
    /// `<root>/.config.json` wins if it exists, otherwise `.claude.json`
    /// — which for the *default* root sits at the home directory, not
    /// inside `~/.claude/`. That asymmetry is Claude Code's, not ours, and
    /// getting it wrong means reading a file that is never written.
    public func configCandidates(forRoot root: URL?, homeDirectory: URL) -> [URL] {
        if let root {
            return [
                root.appendingPathComponent(".config.json"),
                root.appendingPathComponent(".claude.json"),
            ]
        }
        return [
            homeDirectory.appendingPathComponent(".claude/.config.json"),
            homeDirectory.appendingPathComponent(".claude.json"),
        ]
    }

    /// The first candidate that exists, with its modification date.
    public func currentConfig(
        forRoot root: URL?,
        homeDirectory: URL
    ) -> (url: URL, modifiedAt: Date)? {
        for candidate in configCandidates(forRoot: root, homeDirectory: homeDirectory) {
            guard let attrs = try? fileManager.attributesOfItem(atPath: candidate.path),
                  let modified = attrs[.modificationDate] as? Date
            else { continue }
            return (candidate, modified)
        }
        return nil
    }

    /// Parse `oauthAccount` out of a config file.
    ///
    /// Returns nil when the file is unreadable, isn't JSON, or has no
    /// `oauthAccount` — all of which are ordinary states (a fresh install,
    /// a config being rewritten as we read it) and none of which should
    /// close the current activation. A switch is only ever recorded from a
    /// *successful* read of a *different* account; a failed read leaves the
    /// trail exactly as it was, so a transient blip can't manufacture a
    /// spurious account change and split a session in two.
    public func read(configAt url: URL, rootPath: String?) -> Observation? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["oauthAccount"] as? [String: Any]
        else { return nil }
        let org = oauth["organizationUuid"] as? String
        let account = oauth["accountUuid"] as? String
        // An object with neither identifier tells us nothing usable.
        guard org?.isEmpty == false || account?.isEmpty == false else { return nil }
        return Observation(
            organizationId: org?.isEmpty == true ? nil : org,
            accountUuid: account?.isEmpty == true ? nil : account,
            emailAddress: oauth["emailAddress"] as? String,
            organizationName: oauth["organizationName"] as? String,
            rootPath: rootPath
        )
    }
}
