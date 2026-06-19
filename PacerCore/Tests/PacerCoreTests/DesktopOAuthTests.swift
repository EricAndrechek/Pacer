import Foundation
import CommonCrypto
import CryptoKit
import Testing
@testable import PacerCore

/// Tests for the Claude Desktop credential source. The keychain key and the
/// config-file blobs are injected, so no real keychain/file access happens
/// (except the explicitly-gated live test at the bottom).
@Suite struct DesktopOAuthTests {

    // Any bytes work as the safeStorage "password" for round-trip tests —
    // the production value is an ASCII base64 string used as-is.
    private static let testKey = Data("pacer-test-safe-storage-key".utf8)
    private static let host = "https://api.anthropic.com"

    /// Mirror of `DesktopOAuth.decrypt`'s scheme, in the encrypt direction,
    /// so a round-trip proves the CommonCrypto wiring (PBKDF2 + AES-128-CBC
    /// + v10 prefix + PKCS#7) is correct.
    private func encryptV10(_ plaintext: Data, keyPassword: Data = testKey) -> String {
        let key = DesktopOAuth.pbkdf2SHA1(
            password: keyPassword, salt: Data("saltysalt".utf8),
            rounds: 1003, keyLength: kCCKeySizeAES128
        )!
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var out = Data(count: plaintext.count + kCCBlockSizeAES128)
        var moved = 0
        let status = out.withUnsafeMutableBytes { o in
            plaintext.withUnsafeBytes { p in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            k.baseAddress, key.count,
                            v.baseAddress,
                            p.baseAddress, plaintext.count,
                            o.baseAddress, o.count,
                            &moved
                        )
                    }
                }
            }
        }
        precondition(status == kCCSuccess)
        out.removeSubrange(moved..<out.count)
        return (Data("v10".utf8) + out).base64EncodedString()
    }

    private func key(client: String, scopes: String) -> String {
        "\(client):acct:\(Self.host):\(scopes)"
    }

    private func cacheData(_ entries: [(client: String, scopes: String, token: String, expiresMs: Int64)]) -> Data {
        var dict: [String: Any] = [:]
        for e in entries {
            dict[key(client: e.client, scopes: e.scopes)] = [
                "token": e.token,
                "refreshToken": "refresh-\(e.token)",
                "expiresAt": e.expiresMs,
                "subscriptionType": "max",
            ]
        }
        return try! JSONSerialization.data(withJSONObject: dict)
    }

    // MARK: - Decryption round-trip

    @Test func decryptRoundTrip() {
        let plain = Data(#"{"hello":"world","n":1}"#.utf8)
        let blob = encryptV10(plain)
        let out = DesktopOAuth.decrypt(blobBase64: blob, keyPassword: Self.testKey)
        #expect(out == plain)
    }

    @Test func decryptRejectsBadPrefixAndGarbage() {
        // Not base64 / no v10 prefix → nil, never a crash.
        #expect(DesktopOAuth.decrypt(blobBase64: "not base64!!", keyPassword: Self.testKey) == nil)
        let noPrefix = Data("hello".utf8).base64EncodedString()
        #expect(DesktopOAuth.decrypt(blobBase64: noPrefix, keyPassword: Self.testKey) == nil)
    }

    @Test func decryptWithWrongKeyDoesNotCrash() {
        let blob = encryptV10(Data(#"{"a":1}"#.utf8))
        // Wrong key → PKCS#7 unpad yields garbage or fails; must not crash.
        _ = DesktopOAuth.decrypt(blobBase64: blob, keyPassword: Data("different".utf8))
    }

    // MARK: - Freshest-profile selection

    @Test func picksFreshestProfileToken() {
        let cache = try! JSONSerialization.jsonObject(with: cacheData([
            (client: "a", scopes: "user:inference user:profile", token: "older", expiresMs: 1_000_000),
            (client: "b", scopes: "user:inference user:profile user:sessions:claude_code", token: "newer", expiresMs: 2_000_000),
        ])) as! [String: Any]
        let cred = DesktopOAuth.freshestProfileCredential(cache: cache)
        #expect(cred?.accessToken == "newer")
        #expect(cred?.refreshToken == "refresh-newer")
        #expect(cred?.expiresAt == Date(timeIntervalSince1970: 2000))
    }

    @Test func ignoresNonProfileScopes() {
        let cache = try! JSONSerialization.jsonObject(with: cacheData([
            (client: "a", scopes: "user:inference", token: "inference-only", expiresMs: 9_999_999),
        ])) as! [String: Any]
        #expect(DesktopOAuth.freshestProfileCredential(cache: cache) == nil)
    }

    @Test func skipsEntryMissingToken() {
        var dict: [String: Any] = [:]
        dict[key(client: "a", scopes: "user:profile")] = ["expiresAt": 5_000_000] // no token
        dict[key(client: "b", scopes: "user:profile")] = ["token": "good", "expiresAt": 1_000_000]
        let cred = DesktopOAuth.freshestProfileCredential(cache: dict)
        #expect(cred?.accessToken == "good")
    }

    // MARK: - read() orchestration (injected readers)

    private func desktop(
        cache: [(client: String, scopes: String, token: String, expiresMs: Int64)]?,
        keyResult: Result<Data, DesktopOAuthError> = .success(testKey)
    ) -> DesktopOAuth {
        // Precompute the encrypted blobs so the @Sendable readers capture
        // only Sendable values (no `self`).
        let blobs: [String]? = cache.map { [encryptV10(cacheData($0))] }
        return DesktopOAuth(
            keyReader: { keyResult },
            cacheReader: { blobs }
        )
    }

    @Test func readReturnsFreshestProfileCredential() {
        let d = desktop(cache: [
            (client: "a", scopes: "user:inference user:profile", token: "tok-new", expiresMs: 5_000_000),
            (client: "b", scopes: "user:inference", token: "tok-noprofile", expiresMs: 9_000_000),
        ])
        guard case .success(let cred) = d.read() else {
            Issue.record("expected success"); return
        }
        #expect(cred.accessToken == "tok-new")
    }

    @Test func readConfigNotFoundWhenCacheReaderNil() {
        let d = DesktopOAuth(keyReader: { .success(Self.testKey) }, cacheReader: { nil })
        #expect(d.read() == .failure(.configNotFound))
    }

    @Test func readNoProfileTokenWhenEmptyOrNoProfile() {
        // Empty blob list.
        let empty = DesktopOAuth(keyReader: { .success(Self.testKey) }, cacheReader: { [] })
        #expect(empty.read() == .failure(.noProfileToken))
        // Decryptable but no user:profile entry.
        let noProfile = desktop(cache: [
            (client: "a", scopes: "user:inference", token: "x", expiresMs: 1),
        ])
        #expect(noProfile.read() == .failure(.noProfileToken))
    }

    @Test func readPropagatesKeyFailure() {
        let d = desktop(cache: [(client: "a", scopes: "user:profile", token: "x", expiresMs: 1)],
                        keyResult: .failure(.keychainAccessDenied))
        #expect(d.read() == .failure(.keychainAccessDenied))
    }

    @Test func readDecryptFailedOnGarbageBlob() {
        let d = DesktopOAuth(keyReader: { .success(Self.testKey) }, cacheReader: { ["not-a-real-blob"] })
        #expect(d.read() == .failure(.decryptFailed("no cache blob decrypted to JSON")))
    }

    // MARK: - OAuthClient freshest-token-wins integration

    /// Build an OAuthClient whose transport reports utilization 11 when the
    /// Desktop token is used and 99 when the keychain token is used, so the
    /// parsed snapshot reveals which source won.
    private func integrationClient(
        keychainToken: String,
        keychainExpiry: Date?,
        desktopToken: String,
        desktopExpiryMs: Int64,
        desktopEnabled: Bool,
        now: Date
    ) -> OAuthClient {
        let kcBlob: [String: Any] = ["claudeAiOauth": [
            "accessToken": keychainToken,
            "expiresAt": Int64((keychainExpiry?.timeIntervalSince1970 ?? 0) * 1000),
            "subscriptionType": "max",
        ]]
        let kcData = try! JSONSerialization.data(withJSONObject: kcBlob)
        let kc = KeychainOAuth(rawReader: { .success(kcData) })
        let dt = desktop(cache: [(client: "a", scopes: "user:inference user:profile", token: desktopToken, expiresMs: desktopExpiryMs)])
        return OAuthClient(
            keychain: kc,
            transport: { req in
                let bearer = req.value(forHTTPHeaderField: "Authorization") ?? ""
                let util = bearer.contains(desktopToken) ? 11.0 : 99.0
                let body = "{\"five_hour\":{\"utilization\":\(util)}}"
                let resp = HTTPURLResponse(url: OAuthClient.endpoint, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
                return (Data(body.utf8), resp)
            },
            now: { now },
            tokenOverride: { nil },
            desktop: dt,
            desktopEnabled: { desktopEnabled }
        )
    }

    @Test func desktopUsedWhenKeychainExpired() async {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let c = integrationClient(
            keychainToken: "sk-ant-oat01-cc",
            keychainExpiry: now.addingTimeInterval(-3600),                 // expired
            desktopToken: "sk-ant-oat01-desktop",
            desktopExpiryMs: Int64(now.addingTimeInterval(3600).timeIntervalSince1970 * 1000), // fresh
            desktopEnabled: true,
            now: now
        )
        guard case .success(let snap) = await c.fetchUsage() else {
            Issue.record("expected success"); return
        }
        #expect(snap.fiveHour?.usedPercentage == 11.0)  // desktop token won
    }

    @Test func keychainUsedWhenFresherThanDesktop() async {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let c = integrationClient(
            keychainToken: "sk-ant-oat01-cc",
            keychainExpiry: now.addingTimeInterval(7200),                  // fresher
            desktopToken: "sk-ant-oat01-desktop",
            desktopExpiryMs: Int64(now.addingTimeInterval(1800).timeIntervalSince1970 * 1000), // fresh but sooner
            desktopEnabled: true,
            now: now
        )
        guard case .success(let snap) = await c.fetchUsage() else {
            Issue.record("expected success"); return
        }
        #expect(snap.fiveHour?.usedPercentage == 99.0)  // keychain token won (later expiry)
    }

    @Test func desktopIgnoredWhenDisabled() async {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        // Keychain expired, desktop fresh — but opt-in is off, so we must
        // NOT consult Desktop and instead report the expired keychain token.
        let c = integrationClient(
            keychainToken: "sk-ant-oat01-cc",
            keychainExpiry: now.addingTimeInterval(-3600),
            desktopToken: "sk-ant-oat01-desktop",
            desktopExpiryMs: Int64(now.addingTimeInterval(3600).timeIntervalSince1970 * 1000),
            desktopEnabled: false,
            now: now
        )
        guard case .failure(.tokenExpired) = await c.fetchUsage() else {
            Issue.record("expected tokenExpired (desktop disabled)"); return
        }
    }

    // MARK: - Live integration (gated)
    //
    // Set PACER_RUN_LIVE_DESKTOP_TEST=1 to decrypt the REAL Claude Desktop
    // cache. Prints the selected token's sha256 fingerprint so it can be
    // cross-checked against the Python harness output. Will trigger the
    // one-time "Claude Safe Storage" keychain approval if not yet granted.

    @Test func liveDesktopRead() {
        guard ProcessInfo.processInfo.environment["PACER_RUN_LIVE_DESKTOP_TEST"] == "1" else { return }
        switch DesktopOAuth().read() {
        case .success(let cred):
            let fp = SHA256.hash(data: Data(cred.accessToken.utf8))
                .prefix(4).map { String(format: "%02x", $0) }.joined()
            print("LIVE desktop token fp=\(fp) len=\(cred.accessToken.count) expiresAt=\(String(describing: cred.expiresAt))")
            #expect(cred.accessToken.hasPrefix("sk-ant-"))
        case .failure(let e):
            Issue.record("live desktop read failed: \(e)")
        }
    }
}
