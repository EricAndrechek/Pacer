import Foundation
import Security

/// Claude Code credentials kept in the keychain for logins that are not the
/// signed-in one, read without ever prompting and without re-reading an item
/// that has not changed.
///
/// Two kinds, both labelled `.parked` in the lane pool:
/// - **Profile items**, `Claude Code-credentials-<suffix>`: what Claude Code
///   writes for a session pinned to its own `CLAUDE_CONFIG_DIR` (a switcher's
///   session mode).
/// - **Switcher items**, service `claude-swap`, account `account-<N>-<email>`:
///   the copy cswap keeps of every login it manages, and refreshes itself.
///   Pacer's own copy of a login's token dies when the token expires, about
///   8 hours after the switch away from it, because Pacer must never refresh
///   one (refreshing rotates it and signs the live session out). cswap's copy
///   stays live, so reading it keeps every account polled on its Claude Code
///   token (#170). cswap writes these with `/usr/bin/security`, and Pacer
///   reads with the same binary (`SecurityCLI`), so the read is silent.
///   Opt-out in Settings, because it is reading another tool's credentials.
///
/// **Never prompt twice.** Listing is attributes-only (`SecItemCopyMatching`
/// without data), which cannot prompt. A read happens only when an item's
/// modification date has moved since it was last read, so a quiet keychain
/// costs no subprocess at all, and a profile item holding a long-dead token is
/// read once, not on every discovery. Any failure other than "not found"
/// stops that kind being read for the rest of the session: a keychain that
/// wants a password asks once, not every few minutes, which is how the Claude
/// Desktop read went wrong for some users.
public final class ParkedCredentialStore: @unchecked Sendable {

    public static let shared = ParkedCredentialStore()

    public enum Kind: String, Sendable {
        case profile
        case switcher
    }

    public struct Item: Sendable, Equatable {
        public let service: String
        public let account: String?
        public let modified: Date?
        public init(service: String, account: String?, modified: Date?) {
            self.service = service
            self.account = account
            self.modified = modified
        }
    }

    public enum ReadOutcome: Sendable, Equatable {
        case data(Data)
        case notFound
        case failed(String)
    }

    /// What Settings shows about the switcher's saved logins.
    public struct SwitcherStatus: Sendable, Equatable {
        /// Saved logins found in the keychain (listing only, nothing read).
        public let saved: Int
        /// How many of those have given Pacer an unexpired token.
        public let usable: Int
        /// Set once a read has failed; reading is off for the session.
        public let failure: String?
    }

    public static let profileServicePrefix = "Claude Code-credentials-"
    public static let liveService = "Claude Code-credentials"
    public static let switcherService = "claude-swap"

    private let listItems: @Sendable () -> [Item]
    private let read: @Sendable (Item) -> ReadOutcome
    private let switcherEnabled: @Sendable () -> Bool
    private let now: @Sendable () -> Date

    private let lock = NSLock()
    private var cache: [String: (modified: Date?, credential: OAuthCredential?)] = [:]
    private var failures: [Kind: String] = [:]

    public init(
        listItems: @escaping @Sendable () -> [Item] = ParkedCredentialStore.keychainItems,
        read: @escaping @Sendable (Item) -> ReadOutcome = ParkedCredentialStore.securityRead,
        switcherEnabled: @escaping @Sendable () -> Bool = { PacerPreferences.switcherCredentialsEnabled() },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.listItems = listItems
        self.read = read
        self.switcherEnabled = switcherEnabled
        self.now = now
    }

    /// Which kind an item is, or nil if it is neither. `.prev` is the retained
    /// previous copy cswap keeps of a login; the current one is authoritative.
    public static func kind(service: String, account: String?) -> Kind? {
        if service == switcherService {
            guard let account, !account.hasSuffix(".prev"),
                  account.range(of: #"^account-\d+-.+"#, options: .regularExpression) != nil
            else { return nil }
            return .switcher
        }
        if service.hasPrefix(profileServicePrefix), service != liveService { return .profile }
        return nil
    }

    /// Every parked credential, reading only items that changed.
    public func credentials() -> [OAuthCredential] {
        lock.lock(); defer { lock.unlock() }
        let wantSwitcher = switcherEnabled()
        var out: [OAuthCredential] = []
        var seen = Set<String>()
        for item in listItems() {
            guard let kind = Self.kind(service: item.service, account: item.account),
                  kind != .switcher || wantSwitcher else { continue }
            let key = Self.cacheKey(item)
            seen.insert(key)
            if let cached = cache[key], cached.modified == item.modified, item.modified != nil {
                if let credential = cached.credential { out.append(credential) }
                continue
            }
            // A kind that has failed is not read again this session; whatever
            // it gave before stays usable until it expires.
            if failures[kind] != nil {
                if let credential = cache[key]?.credential { out.append(credential) }
                continue
            }
            switch read(item) {
            case .data(let data):
                let credential = try? KeychainOAuth(rawReader: { .success(data) }).read().get()
                cache[key] = (item.modified, credential)
                if let credential { out.append(credential) }
            case .notFound:
                cache[key] = nil
            case .failed(let reason):
                failures[kind] = reason
                Log.write("ParkedCredentials",
                          "\(kind == .switcher ? "cswap's saved logins" : "profile credentials") "
                            + "could not be read (\(reason)); not reading them again this session")
                if let credential = cache[key]?.credential { out.append(credential) }
            }
        }
        // Forget items that are gone, so a re-created one is read afresh.
        cache = cache.filter { seen.contains($0.key) }
        return out
    }

    /// The switcher's saved logins as Settings describes them. Lists the
    /// keychain (attributes only, cannot prompt); reads nothing.
    public func switcherStatus() -> SwitcherStatus {
        let items = listItems().filter {
            Self.kind(service: $0.service, account: $0.account) == .switcher
        }
        lock.lock(); defer { lock.unlock() }
        let reference = now()
        let usable = items.filter { item in
            guard let credential = cache[Self.cacheKey(item)]?.credential else { return false }
            return credential.expiresAt.map { $0 > reference } ?? true
        }.count
        return SwitcherStatus(saved: items.count, usable: usable, failure: failures[.switcher])
    }

    /// Clear a failure so the next discovery tries again: the user turned the
    /// setting off and on, which is them saying "try now".
    public func resetFailures() {
        lock.lock(); defer { lock.unlock() }
        failures.removeAll()
    }

    private static func cacheKey(_ item: Item) -> String {
        "\(item.service)\u{1}\(item.account ?? "")"
    }

    // MARK: - Keychain

    /// Service, account and modification date of every generic-password item.
    /// Attributes only: `kSecReturnData` is absent, so this cannot prompt.
    public static let keychainItems: @Sendable () -> [Item] = {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let rows = result as? [[String: Any]]
        else { return [] }
        return rows.compactMap { row in
            guard let service = row[kSecAttrService as String] as? String,
                  kind(service: service, account: row[kSecAttrAccount as String] as? String) != nil
            else { return nil }
            return Item(service: service,
                        account: row[kSecAttrAccount as String] as? String,
                        modified: row[kSecAttrModificationDate as String] as? Date)
        }
    }

    /// One item's secret through `/usr/bin/security`, the binary both Claude
    /// Code and cswap create these items with, so the read is silent.
    public static let securityRead: @Sendable (Item) -> ReadOutcome = { item in
        guard !PacerPreferences.isTestProcess else { return .notFound }
        switch SecurityCLI.findGenericPassword(service: item.service, account: item.account) {
        case .success(let data): return .data(data)
        case .failure(.notFound): return .notFound
        case .failure(.accessDenied): return .failed("access denied")
        case .failure(.spawn(let status)): return .failed("could not run security (\(status))")
        case .failure(.status(let status)): return .failed("security exited \(status)")
        }
    }
}
