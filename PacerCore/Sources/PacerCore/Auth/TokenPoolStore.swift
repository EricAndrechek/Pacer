import Foundation
import Security

/// One token Pacer has persisted for the account, with the source it
/// originally came from (so the Tokens UI still labels it correctly after
/// a restart, and the Desktop layered-read logic knows which cached
/// tokens are Desktop-origin).
public struct StoredToken: Codable, Sendable, Equatable {
    public let credential: OAuthCredential
    public let source: CredentialCandidate.Source
    public init(credential: OAuthCredential, source: CredentialCandidate.Source) {
        self.credential = credential
        self.source = source
    }
}

/// Persists the whole set of account tokens in Pacer's own keychain, so
/// the poller's lane pool survives a restart without re-reading Claude's
/// stores — a superset of the single-slot `HeldCredentialStoring`. Reads
/// are silent (Pacer's app-private item); the OS encrypts at rest.
public protocol TokenPoolStoring: Sendable {
    func loadAll() -> [StoredToken]
    func saveAll(_ tokens: [StoredToken])
    func clear()
}

/// Production pool store: one generic-password item holding a JSON array.
public struct KeychainTokenPoolStore: TokenPoolStoring {
    public static let service = "com.ericandrechek.pacer.oauth.pool"
    public static let account = "primary"

    public init() {}

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    public func loadAll() -> [StoredToken] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let tokens = try? JSONDecoder().decode([StoredToken].self, from: data)
        else { return [] }
        return tokens
    }

    public func saveAll(_ tokens: [StoredToken]) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
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

/// In-memory pool store — the default, so tests and Settings probes never
/// touch the real keychain; production opts into `KeychainTokenPoolStore`.
public final class EphemeralTokenPoolStore: TokenPoolStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [StoredToken]
    public init(_ tokens: [StoredToken] = []) { self.tokens = tokens }
    public func loadAll() -> [StoredToken] {
        lock.lock(); defer { lock.unlock() }; return tokens
    }
    public func saveAll(_ tokens: [StoredToken]) {
        lock.lock(); self.tokens = tokens; lock.unlock()
    }
    public func clear() {
        lock.lock(); tokens = []; lock.unlock()
    }
}

/// Persists Claude Desktop's `Claude Safe Storage` AES key in Pacer's own
/// keychain. That key is Chromium/Electron's OSCrypt key — generated once
/// per Desktop install and reused for its lifetime (token refreshes
/// re-encrypt with the SAME key), so caching it lets us decrypt every
/// future `config.json` change WITHOUT re-reading `Claude Safe Storage` —
/// which is the only step that can pop the macOS approval. We only go back
/// to the source key if our cached one fails to decrypt (a Desktop
/// reinstall rotated it).
///
/// This is a more sensitive secret than the tokens (it's long-lived and
/// can decrypt all of Desktop's safeStorage), so it lives in Pacer's
/// app-private, Secure-Enclave-protected keychain item like everything
/// else — a capability Pacer already exercises on demand, now persisted.
public protocol DesktopKeyStoring: Sendable {
    func load() -> Data?
    func save(_ key: Data)
    func clear()
}

public struct KeychainDesktopKeyStore: DesktopKeyStoring {
    public static let service = "com.ericandrechek.pacer.desktop.safestorage.key"
    public static let account = "primary"

    public init() {}

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    public func load() -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data
        else { return nil }
        return data
    }

    public func save(_ key: Data) {
        let update: [String: Any] = [kSecValueData as String: key]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = key
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    public func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

public final class EphemeralDesktopKeyStore: DesktopKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data?
    public init(_ key: Data? = nil) { self.key = key }
    public func load() -> Data? {
        lock.lock(); defer { lock.unlock() }; return key
    }
    public func save(_ key: Data) {
        lock.lock(); self.key = key; lock.unlock()
    }
    public func clear() {
        lock.lock(); key = nil; lock.unlock()
    }
}
