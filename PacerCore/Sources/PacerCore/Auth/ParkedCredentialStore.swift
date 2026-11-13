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

    /// Guards `cache` and `failures`. Held only to copy them out or merge a
    /// discovery's results in, never across the keychain listing or a
    /// `security` run: Settings asks `switcherStatus()` and
    /// `resetFailures()`, and those must not wait for a discovery's
    /// subprocesses (up to 5 s each) to finish.
    private let lock = NSLock()
    private var cache: [String: (modified: Date?, credential: OAuthCredential?)] = [:]
    private var failures: [Kind: String] = [:]
    /// Bumped by `resetFailures()`, so a discovery whose reads were already
    /// under way does not latch a failure over the user's "try now".
    private var resetGeneration: UInt64 = 0
    /// Serialises discoveries, and is all that a discovery holds across its
    /// I/O. Two at once would read the same changed item twice, which on a
    /// keychain that prompts is two prompts, and the older one's merge could
    /// put back a cache entry the newer one had replaced. Only `credentials()`
    /// takes it, so nothing that just reads state ever waits on it.
    private let discovery = NSLock()

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
    ///
    /// In three steps, so `lock` is never held across I/O: copy the cache
    /// and the failure latch (under `lock`); list the keychain and read the
    /// changed items (outside it); merge the reads back (under `lock`).
    /// Discoveries are serialised by `discovery`, so nothing else changes the
    /// cache between this one's copy and its merge. `resetFailures()` can
    /// clear the latch meanwhile; `resetGeneration` accounts for that.
    public func credentials() -> [OAuthCredential] {
        discovery.lock(); defer { discovery.unlock() }
        let wantSwitcher = switcherEnabled()
        let listed = listItems().compactMap { item -> (Item, Kind)? in
            guard let kind = Self.kind(service: item.service, account: item.account),
                  kind != .switcher || wantSwitcher else { return nil }
            return (item, kind)
        }
        let (cached, failed, generation) = lock.withLock { (cache, failures, resetGeneration) }

        // What each item contributes, in listing order.
        enum Slot {
            /// Not read: unchanged, or its kind has failed. What the cache had.
            case held(OAuthCredential?)
            /// Read; nil when the item held no credential Pacer can use.
            case read(OAuthCredential?)
            case gone
            case failed(String)
        }
        var slots: [(item: Item, kind: Kind, slot: Slot)] = []
        var failedNow: [Kind: String] = [:]
        for (item, kind) in listed {
            let entry = cached[Self.cacheKey(item)]
            if let entry, entry.modified == item.modified, item.modified != nil {
                slots.append((item, kind, .held(entry.credential)))
                continue
            }
            // A kind that has failed is not read again this session, nor
            // after a failure earlier in this discovery; whatever it gave
            // before stays usable until it expires.
            if failed[kind] != nil || failedNow[kind] != nil {
                slots.append((item, kind, .held(entry?.credential)))
                continue
            }
            switch read(item) {
            case .data(let data):
                slots.append((item, kind, .read(try? KeychainOAuth(rawReader: { .success(data) }).read().get())))
            case .notFound:
                slots.append((item, kind, .gone))
            case .failed(let reason):
                failedNow[kind] = reason
                slots.append((item, kind, .failed(reason)))
            }
        }

        let (out, latched): ([OAuthCredential], [Kind: String]) = lock.withLock {
            // `resetFailures()` ran while this discovery was reading: the user
            // asked to try again after these reads began, so a failure among
            // them is not the answer to that, and must not latch over it. The
            // retry's own discovery reads again.
            let latch = resetGeneration == generation
            var out: [OAuthCredential] = []
            var seen = Set<String>()
            for (item, kind, slot) in slots {
                let key = Self.cacheKey(item)
                seen.insert(key)
                switch slot {
                case .held(let credential):
                    if let credential { out.append(credential) }
                case .read(let credential):
                    cache[key] = (item.modified, credential)
                    if let credential { out.append(credential) }
                case .gone:
                    cache[key] = nil
                case .failed(let reason):
                    if latch { failures[kind] = reason }
                    if let credential = cache[key]?.credential { out.append(credential) }
                }
            }
            // Forget items that are gone, so a re-created one is read afresh.
            cache = cache.filter { seen.contains($0.key) }
            return (out, latch ? failedNow : [:])
        }

        for (kind, reason) in latched.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            // Once per kind per session (the latch stops further reads), so
            // this is "this Mac's keychain read failed", classified to a
            // fixed word, never the reason text.
            CredentialTelemetry.note(kind == .switcher ? "switcher" : "profile",
                                     CredentialTelemetry.keychainKind(reason: reason))
            Log.write("ParkedCredentials",
                      "\(kind == .switcher ? "cswap's saved logins" : "profile credentials") "
                        + "could not be read (\(reason)); not reading them again this session")
        }
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
        resetGeneration &+= 1
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
