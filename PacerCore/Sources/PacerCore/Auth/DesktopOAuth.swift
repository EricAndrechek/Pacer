import Foundation
import CommonCrypto

/// Errors from `DesktopOAuth.read()`. Distinct from `KeychainOAuthError`
/// because the failure modes differ — Desktop stores its token encrypted,
/// so there's a decrypt step and a "no usable token in the cache" case.
public enum DesktopOAuthError: Error, Sendable, Equatable {
    /// No `~/Library/Application Support/Claude/config.json` — Claude
    /// Desktop isn't installed / has never signed in on this machine.
    case configNotFound
    /// Couldn't read the `Claude Safe Storage` AES key from the keychain
    /// (item absent / spawn failure / unexpected status).
    case keychainKeyUnavailable(OSStatus)
    /// The keychain approval was declined, or we ran in a non-UI context.
    /// Recoverable by approving the one-time prompt in the foreground app.
    case keychainAccessDenied
    /// The key read succeeded but decryption of every cache blob failed —
    /// almost certainly an Electron `safeStorage` format change worth
    /// investigating before suppressing.
    case decryptFailed(String)
    /// Decrypted fine, but no entry carried a `user:profile` token — which
    /// is the scope `/api/oauth/usage` requires. (A Desktop install that
    /// only ever did inference could in principle land here.)
    case noProfileToken
}

/// Reads Claude Desktop's OAuth credential out of its Electron
/// `safeStorage`-encrypted token cache, so Pacer keeps working for users
/// who use Claude Desktop / general chat rather than the Claude Code CLI.
///
/// ## Where it lives (verified live on macOS)
///
///   - Keychain item `Claude Safe Storage` / account `Claude Key` holds an
///     AES key (an ASCII base64 string, used as the PBKDF2 password as-is).
///   - `~/Library/Application Support/Claude/config.json` holds the
///     encrypted token cache under `oauth:tokenCache` (and `…CacheV2`),
///     each value being `base64("v10" + AES-128-CBC ciphertext)`.
///   - Decrypted, the cache is a dict keyed by
///     `<client_id>:<account>:<host>:<space-separated scopes>`; each value
///     is `{ token, refreshToken, expiresAt(ms), subscriptionType, … }`.
///     Entries whose scopes include `user:profile` work against
///     `/api/oauth/usage`; we pick the freshest such token.
///
/// ## safeStorage decryption (Chromium OSCrypt, macOS)
///
/// AES-128-CBC, key = PBKDF2-HMAC-SHA1(keychain-password, salt "saltysalt",
/// 1003 rounds, 16 bytes), IV = 16 × 0x20, PKCS#7 padding, after stripping
/// the 3-byte `v10` prefix. All constants are Chromium's.
///
/// ## Safety
///
/// Strictly read-only: Pacer never writes `config.json` and never refreshes
/// Desktop's token, so it can't rotate the shared refresh token or disturb
/// the Desktop session. Gated behind an explicit opt-in (the first read
/// triggers the one-time `Claude Safe Storage` keychain approval).
public struct DesktopOAuth: Sendable {

    public static let keychainService = "Claude Safe Storage"
    public static let keychainAccount = "Claude Key"

    /// Returns the safeStorage key password bytes (the ASCII base64 string,
    /// trailing newline stripped), or a typed error. Injected for tests.
    public typealias KeyReader = @Sendable () -> Result<Data, DesktopOAuthError>
    /// Returns the encrypted cache blobs from config.json, or nil when the
    /// config file is absent (Desktop not installed). An empty array means
    /// the file exists but carries no token cache. Injected for tests.
    public typealias CacheReader = @Sendable () -> [String]?

    private let keyReader: KeyReader
    private let cacheReader: CacheReader

    public init(
        keyReader: @escaping KeyReader = DesktopOAuth.defaultKeyReader,
        cacheReader: @escaping CacheReader = DesktopOAuth.defaultCacheReader
    ) {
        self.keyReader = keyReader
        self.cacheReader = cacheReader
    }

    // MARK: - Read

    /// Resolve the freshest `user:profile` credential from Claude Desktop.
    public func read() -> Result<OAuthCredential, DesktopOAuthError> {
        readAll().map { $0[0] }   // readAll guarantees a non-empty array on success
    }

    /// All `user:profile` credentials in the cache, freshest first. Lets the
    /// resolver fall through to the next-freshest if its first pick is
    /// rejected (the cache can hold several tokens at different expiries).
    public func readAll() -> Result<[OAuthCredential], DesktopOAuthError> {
        switch decryptedCache() {
        case .failure(let e):
            return .failure(e)
        case .success(let cache):
            let creds = Self.profileCredentials(cache: cache)
            return creds.isEmpty ? .failure(.noProfileToken) : .success(creds)
        }
    }

    /// Read + decrypt + merge every cache blob into one dict. Shared by
    /// `read()` / `readAll()`.
    private func decryptedCache() -> Result<[String: Any], DesktopOAuthError> {
        guard let blobs = cacheReader() else { return .failure(.configNotFound) }
        if blobs.isEmpty { return .failure(.noProfileToken) }

        let keyPassword: Data
        switch keyReader() {
        case .success(let k): keyPassword = k
        case .failure(let e): return .failure(e)
        }

        var merged: [String: Any] = [:]
        var decryptedAny = false
        for blob in blobs {
            guard let plain = Self.decrypt(blobBase64: blob, keyPassword: keyPassword),
                  let obj = try? JSONSerialization.jsonObject(with: plain) as? [String: Any]
            else { continue }
            decryptedAny = true
            merged.merge(obj) { _, new in new }
        }
        guard decryptedAny else {
            return .failure(.decryptFailed("no cache blob decrypted to JSON"))
        }
        return .success(merged)
    }

    // MARK: - Selection (pure, unit-tested)

    /// All `user:profile`-scoped credentials, freshest first. Expiry isn't
    /// filtered here — `OAuthClient` is the single expiry authority and
    /// compares Desktop against the keychain token. Deterministic: sorted by
    /// expiry descending, ties broken by the (stable) cache key, so the same
    /// cache always yields the same order.
    static func profileCredentials(cache: [String: Any]) -> [OAuthCredential] {
        var rows: [(key: String, expiry: Date, cred: OAuthCredential)] = []
        for (key, value) in cache {
            guard key.contains("user:profile"),
                  let entry = value as? [String: Any],
                  let token = entry["token"] as? String, !token.isEmpty
            else { continue }
            let expiresAt = (entry["expiresAt"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            let cred = OAuthCredential(
                accessToken: token,
                expiresAt: expiresAt,
                refreshToken: entry["refreshToken"] as? String,
                subscriptionType: entry["subscriptionType"] as? String
            )
            // A missing expiry sorts as "never expires" so it leads.
            rows.append((key, expiresAt ?? .distantFuture, cred))
        }
        rows.sort { $0.expiry != $1.expiry ? $0.expiry > $1.expiry : $0.key < $1.key }
        return rows.map(\.cred)
    }

    /// Convenience: the single freshest `user:profile` credential. `nil` when
    /// no entry carries `user:profile`.
    static func freshestProfileCredential(cache: [String: Any]) -> OAuthCredential? {
        profileCredentials(cache: cache).first
    }

    // MARK: - Decryption (pure, unit-tested via round-trip)

    /// Decrypt one `base64("v10" + ciphertext)` blob. `nil` on any failure
    /// (bad base64, missing prefix, KDF/cipher error) so callers skip it.
    static func decrypt(blobBase64: String, keyPassword: Data) -> Data? {
        guard let raw = Data(base64Encoded: blobBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              raw.count > 3,
              raw.prefix(3) == Data("v10".utf8)
        else { return nil }
        let ciphertext = raw.subdata(in: 3..<raw.count)
        guard let key = pbkdf2SHA1(password: keyPassword, salt: Data("saltysalt".utf8),
                                   rounds: 1003, keyLength: kCCKeySizeAES128)
        else { return nil }
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        return aes128CBCDecrypt(ciphertext: ciphertext, key: key, iv: iv)
    }

    static func pbkdf2SHA1(password: Data, salt: Data, rounds: Int, keyLength: Int) -> Data? {
        var derived = Data(count: keyLength)
        let status = derived.withUnsafeMutableBytes { derivedPtr in
            salt.withUnsafeBytes { saltPtr in
                password.withUnsafeBytes { pwPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwPtr.bindMemory(to: Int8.self).baseAddress, password.count,
                        saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        UInt32(rounds),
                        derivedPtr.bindMemory(to: UInt8.self).baseAddress, keyLength
                    )
                }
            }
        }
        return status == kCCSuccess ? derived : nil
    }

    static func aes128CBCDecrypt(ciphertext: Data, key: Data, iv: Data) -> Data? {
        guard !ciphertext.isEmpty else { return nil }
        var out = Data(count: ciphertext.count + kCCBlockSizeAES128)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            ciphertext.withUnsafeBytes { ctPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            ctPtr.baseAddress, ciphertext.count,
                            outPtr.baseAddress, outPtr.count,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.removeSubrange(moved..<out.count)
        return out
    }

    // MARK: - Production readers

    /// Reads the AES key from `Claude Safe Storage` / `Claude Key` via the
    /// shared `security` CLI. The value is an ASCII base64 string used
    /// as-is as the PBKDF2 password; we only strip the trailing newline the
    /// CLI appends.
    public static let defaultKeyReader: KeyReader = {
        switch SecurityCLI.findGenericPassword(service: keychainService, account: keychainAccount) {
        case .success(var data):
            while let last = data.last, last == 0x0A || last == 0x0D { data.removeLast() }
            return .success(data)
        case .failure(.notFound):
            return .failure(.keychainKeyUnavailable(OSStatus(errSecItemNotFound)))
        case .failure(.accessDenied):
            return .failure(.keychainAccessDenied)
        case .failure(.spawn(let s)), .failure(.status(let s)):
            return .failure(.keychainKeyUnavailable(s))
        }
    }

    /// Reads `config.json` and returns its encrypted cache blobs. `nil`
    /// when the file is absent/unreadable (Desktop not installed); an empty
    /// array when present but carrying no `oauth:tokenCache*` field.
    public static let defaultCacheReader: CacheReader = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/config.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return ["oauth:tokenCache", "oauth:tokenCacheV2"].compactMap { obj[$0] as? String }
    }
}
