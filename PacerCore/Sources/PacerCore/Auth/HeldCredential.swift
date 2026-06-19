import Foundation
import Security

/// Pacer's own persisted copy of a working OAuth credential.
///
/// Why hold our own copy at all (vs. reading Claude's keychain / Desktop
/// store on every poll):
///   - **Fewer source reads.** Once we hold a valid token we poll the usage
///     endpoint without touching Claude's stores until the token nears
///     expiry — so a Desktop ~1-year token means we read its keychain item
///     about once a year, not every 5 minutes.
///   - **Survives logout/uninstall.** If the user signs out of Claude Code
///     or removes Claude Desktop, a still-valid held token keeps Pacer
///     working until it actually expires.
///   - **Enables a future phone view.** Holding the token is the prerequisite
///     for E2EE-syncing it to a Pacer iOS app (designed separately).
///
/// We store it in Pacer's OWN keychain item (app-private, not the shared
/// items we read from Claude), which the OS already encrypts at rest
/// (Secure-Enclave-protected on modern Macs) — so no home-grown crypto.
public protocol HeldCredentialStoring: Sendable {
    func load() -> OAuthCredential?
    func save(_ credential: OAuthCredential)
    func clear()
}

/// Production store: a generic-password item in Pacer's keychain. The app is
/// not sandboxed, so `SecItem` uses Pacer's default (app-private) access
/// group and reads silently — no prompt, since Pacer created the item. We
/// deliberately use `AfterFirstUnlock` (not a biometry/passcode gate) so the
/// background poller can read it without user interaction.
public struct KeychainCredentialStore: HeldCredentialStoring {
    public static let service = "com.ericandrechek.pacer.oauth.held"
    public static let account = "primary"

    public init() {}

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    public func load() -> OAuthCredential? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data
        else { return nil }
        return try? JSONDecoder().decode(OAuthCredential.self, from: data)
    }

    public func save(_ credential: OAuthCredential) {
        guard let data = try? JSONEncoder().encode(credential) else { return }
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    public func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// In-memory store. The default for `OAuthClient`, so tests and the Settings
/// probes never touch the real keychain; production opts into
/// `KeychainCredentialStore` at the poller's construction site.
public final class EphemeralCredentialStore: HeldCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credential: OAuthCredential?

    public init(_ credential: OAuthCredential? = nil) { self.credential = credential }

    public func load() -> OAuthCredential? {
        lock.lock(); defer { lock.unlock() }
        return credential
    }
    public func save(_ credential: OAuthCredential) {
        lock.lock(); self.credential = credential; lock.unlock()
    }
    public func clear() {
        lock.lock(); credential = nil; lock.unlock()
    }
}

/// In-memory record of access tokens the server has rejected (401), so the
/// resolver won't re-pick a revoked token within this process's lifetime — a
/// token that 401s won't become valid again. Lets resolution fall through to
/// the next-freshest candidate instead of wedging on a stale "freshest" pick.
/// Tokens are held in memory only and never logged.
public final class RejectedTokens: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: Set<String> = []

    public init() {}

    public func reject(_ token: String) {
        lock.lock(); tokens.insert(token); lock.unlock()
    }
    public func isRejected(_ token: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return tokens.contains(token)
    }
}
