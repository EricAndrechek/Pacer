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

    // MARK: - Held-store resolution

    final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    /// Keychain whose reads are counted, so a test can assert the fast path
    /// did NOT touch the source.
    private func countingKeychain(token: String?, expiry: Date?, counter: CallCounter) -> KeychainOAuth {
        if let token {
            let blob: [String: Any] = ["claudeAiOauth": [
                "accessToken": token,
                "expiresAt": Int64((expiry?.timeIntervalSince1970 ?? 0) * 1000),
                "subscriptionType": "max",
            ]]
            let data = try! JSONSerialization.data(withJSONObject: blob)
            return KeychainOAuth(rawReader: { counter.bump(); return .success(data) })
        }
        return KeychainOAuth(rawReader: { counter.bump(); return .failure(.notFound) })
    }

    /// OAuthClient wired with an injectable held store and a transport that
    /// maps each bearer token to a (status, utilization) so the test can tell
    /// which token was used and simulate 401s.
    private func resolvingClient(
        keychain: KeychainOAuth,
        desktop dt: DesktopOAuth? = nil,
        desktopEnabled: Bool = false,
        held: OAuthCredential? = nil,
        rejected: RejectedTokens = RejectedTokens(),
        now: Date,
        respond: @escaping @Sendable (String) -> (status: Int, util: Double)
    ) -> (OAuthClient, EphemeralCredentialStore) {
        let store = EphemeralCredentialStore(held)
        let desktopSource = dt ?? DesktopOAuth(keyReader: { .failure(.configNotFound) }, cacheReader: { nil })
        let client = OAuthClient(
            keychain: keychain,
            transport: { req in
                let bearer = (req.value(forHTTPHeaderField: "Authorization") ?? "")
                    .replacingOccurrences(of: "Bearer ", with: "")
                let (status, util) = respond(bearer)
                let body = "{\"five_hour\":{\"utilization\":\(util)}}"
                let resp = HTTPURLResponse(url: OAuthClient.endpoint, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
                return (Data(body.utf8), resp)
            },
            now: { now },
            tokenOverride: { nil },
            desktop: desktopSource,
            desktopEnabled: { desktopEnabled },
            heldStore: store,
            rejected: rejected
        )
        return (client, store)
    }

    @Test func heldTokenFastPathSkipsSources() async {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let counter = CallCounter()
        let held = OAuthCredential(accessToken: "held-tok", expiresAt: now.addingTimeInterval(3600), subscriptionType: "max")
        // Keychain has an even-fresher token, but the fast path must not look.
        let kc = countingKeychain(token: "cc-tok", expiry: now.addingTimeInterval(7200), counter: counter)
        let (client, _) = resolvingClient(keychain: kc, held: held, now: now) { tok in (200, tok == "held-tok" ? 11 : 99) }
        guard case .success(let snap) = await client.fetchUsage() else { Issue.record("expected success"); return }
        #expect(snap.fiveHour?.usedPercentage == 11)  // held token used
        #expect(counter.count == 0)                   // sources never read
    }

    @Test func slowPathPersistsResolvedToken() async {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let counter = CallCounter()
        let kc = countingKeychain(token: "cc-tok", expiry: now.addingTimeInterval(7200), counter: counter)
        let (client, store) = resolvingClient(keychain: kc, now: now) { _ in (200, 5) }  // no held token
        _ = await client.fetchUsage()
        #expect(counter.count == 1)                          // read sources
        #expect(store.load()?.accessToken == "cc-tok")       // cached the winner
    }

    @Test func nearExpiryRefreshesFromSource() async {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let counter = CallCounter()
        // Held expires in 2 min (< lead time) → must go back to the source.
        let held = OAuthCredential(accessToken: "old-held", expiresAt: now.addingTimeInterval(120), subscriptionType: "max")
        let kc = countingKeychain(token: "fresh-cc", expiry: now.addingTimeInterval(7200), counter: counter)
        let (client, store) = resolvingClient(keychain: kc, held: held, now: now) { tok in (200, tok == "fresh-cc" ? 7 : 99) }
        guard case .success(let snap) = await client.fetchUsage() else { Issue.record("expected success"); return }
        #expect(counter.count == 1)                          // re-read sources
        #expect(snap.fiveHour?.usedPercentage == 7)          // fresher source used
        #expect(store.load()?.accessToken == "fresh-cc")     // held replaced
    }

    @Test func heldTokenServesAsFallbackWhenSourcesLost() async {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let counter = CallCounter()
        // Held near-expiry (forces slow path), but sources are gone (logged
        // out). The still-valid held token must carry us.
        let held = OAuthCredential(accessToken: "held-tok", expiresAt: now.addingTimeInterval(120), subscriptionType: "max")
        let kc = countingKeychain(token: nil, expiry: nil, counter: counter)  // notFound
        let (client, _) = resolvingClient(keychain: kc, held: held, now: now) { tok in (200, tok == "held-tok" ? 22 : 0) }
        guard case .success(let snap) = await client.fetchUsage() else { Issue.record("expected success"); return }
        #expect(counter.count == 1)                          // tried sources, none
        #expect(snap.fiveHour?.usedPercentage == 22)         // fell back to held
    }

    @Test func rejectedTokenFallsThroughToNextCandidate() async {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let rejected = RejectedTokens()
        // Desktop holds the freshest token (bad) plus an older valid one.
        let dt = desktop(cache: [
            (client: "a", scopes: "user:inference user:profile", token: "bad-tok",
             expiresMs: Int64(now.addingTimeInterval(99_999).timeIntervalSince1970 * 1000)),
            (client: "b", scopes: "user:inference user:profile", token: "good-tok",
             expiresMs: Int64(now.addingTimeInterval(50_000).timeIntervalSince1970 * 1000)),
        ])
        let held = OAuthCredential(accessToken: "bad-tok", expiresAt: now.addingTimeInterval(99_999), subscriptionType: "max")
        let kc = countingKeychain(token: nil, expiry: nil, counter: CallCounter())
        let (client, store) = resolvingClient(
            keychain: kc, desktop: dt, desktopEnabled: true, held: held, rejected: rejected, now: now
        ) { tok in tok == "bad-tok" ? (401, 0) : (200, 13) }

        // Poll 1: uses the freshest (bad) held token → 401 → reject + clear.
        guard case .failure(.unauthorized) = await client.fetchUsage() else { Issue.record("expected 401"); return }
        #expect(rejected.isRejected("bad-tok"))
        #expect(store.load() == nil)

        // Poll 2: bad-tok excluded → falls through to good-tok → 200.
        guard case .success(let snap) = await client.fetchUsage() else { Issue.record("expected success"); return }
        #expect(snap.fiveHour?.usedPercentage == 13)
        #expect(store.load()?.accessToken == "good-tok")
    }

    // MARK: - Desktop read frequency (the "keeps asking for my password" bug)
    //
    // The Desktop `Claude Safe Storage` keychain read can pop a macOS prompt
    // that "Always Allow" won't reliably persist, so resolution must touch it
    // rarely. These pin the read count — counted via the keyReader, which is
    // exactly what triggers the prompt.

    /// Desktop source whose keychain key read is counted (each call is one
    /// approval-prompt opportunity), so a test can assert it was NOT touched.
    private func countingDesktop(
        cache: [(client: String, scopes: String, token: String, expiresMs: Int64)],
        counter: CallCounter
    ) -> DesktopOAuth {
        let blobs: [String]? = [encryptV10(cacheData(cache))]
        return DesktopOAuth(
            keyReader: { counter.bump(); return .success(Self.testKey) },
            cacheReader: { blobs }
        )
    }

    /// Like `countingDesktop`, but the cache entry carries NO `expiresAt`, so
    /// the resolved credential has `expiresAt == nil` — the case that never
    /// satisfies the held-token fast path and used to re-read every poll.
    private func countingDesktopNoExpiry(token: String, counter: CallCounter) -> DesktopOAuth {
        let dict: [String: Any] = [
            key(client: "a", scopes: "user:inference user:profile"): ["token": token, "refreshToken": "r"],
        ]
        let blob = encryptV10(try! JSONSerialization.data(withJSONObject: dict))
        return DesktopOAuth(
            keyReader: { counter.bump(); return .success(Self.testKey) },
            cacheReader: { [blob] }
        )
    }

    /// A still-valid held token (even one with no expiry) must be served
    /// without consulting Desktop — Desktop's keychain stays untouched.
    @Test func usableHeldTokenSkipsDesktopRead() async {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let counter = CallCounter()
        let held = OAuthCredential(accessToken: "desk-held", expiresAt: nil, subscriptionType: "max")
        let dt = countingDesktop(cache: [
            (client: "a", scopes: "user:inference user:profile", token: "desk-fresh",
             expiresMs: Int64(now.addingTimeInterval(9999).timeIntervalSince1970 * 1000)),
        ], counter: counter)
        let kc = countingKeychain(token: nil, expiry: nil, counter: CallCounter())  // notFound
        let (client, _) = resolvingClient(
            keychain: kc, desktop: dt, desktopEnabled: true, held: held, now: now
        ) { tok in (200, tok == "desk-held" ? 11 : 99) }
        guard case .success(let snap) = await client.fetchUsage() else { Issue.record("expected success"); return }
        #expect(snap.fiveHour?.usedPercentage == 11)  // held token used
        #expect(counter.count == 0)                   // Desktop keychain NOT read
    }

    /// The regression for "asks every few minutes": a Desktop token with no
    /// `expiresAt` is read once, cached, then served from the held store on
    /// subsequent polls — NOT re-read (re-prompted) every cycle.
    @Test func noExpiryDesktopTokenReadOnceNotEveryPoll() async {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let counter = CallCounter()
        let dt = countingDesktopNoExpiry(token: "desk-tok", counter: counter)
        let kc = countingKeychain(token: nil, expiry: nil, counter: CallCounter())  // Desktop-only user
        let (client, store) = resolvingClient(
            keychain: kc, desktop: dt, desktopEnabled: true, now: now
        ) { _ in (200, 5) }
        for _ in 0..<3 { _ = await client.fetchUsage() }  // three back-to-back polls
        #expect(counter.count == 1)                       // read once, then held serves
        #expect(store.load()?.accessToken == "desk-tok")  // cached
    }

    /// Even when nothing usable can be served — a Desktop token that 401s and
    /// is cleared from the held store each poll — we don't re-read (re-prompt
    /// on) Desktop's keychain while its token file is unchanged. We re-read
    /// only once the file changes (Desktop wrote a new token), and recover.
    @Test func revokedDesktopTokenDoesNotRePromptUntilCacheChanges() async {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let keyReads = CallCounter()
        let expiry = Int64(now.addingTimeInterval(9999).timeIntervalSince1970 * 1000)
        // A mutable encrypted-cache source: starts with a token the server 401s.
        let blobs = Box<[String]?>([encryptV10(cacheData([
            (client: "a", scopes: "user:inference user:profile", token: "bad-tok", expiresMs: expiry),
        ]))])
        let dt = DesktopOAuth(
            keyReader: { keyReads.bump(); return .success(Self.testKey) },
            cacheReader: { blobs.value }
        )
        let kc = countingKeychain(token: nil, expiry: nil, counter: CallCounter())  // notFound
        let store = EphemeralCredentialStore(nil)
        let client = OAuthClient(
            keychain: kc,
            transport: { req in
                let bearer = (req.value(forHTTPHeaderField: "Authorization") ?? "")
                    .replacingOccurrences(of: "Bearer ", with: "")
                let status = bearer == "bad-tok" ? 401 : 200
                let resp = HTTPURLResponse(url: OAuthClient.endpoint, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
                return (Data("{\"five_hour\":{\"utilization\":7}}".utf8), resp)
            },
            now: { now },
            tokenOverride: { nil },
            desktop: dt,
            desktopEnabled: { true },
            heldStore: store,
            rejected: RejectedTokens()
        )
        // Poll 1: reads Desktop → token 401s → rejected + held cleared.
        _ = await client.fetchUsage()
        #expect(keyReads.count == 1)
        // Polls 2–3: cache unchanged → no re-read, no re-prompt, even though
        // nothing usable can be served.
        _ = await client.fetchUsage()
        _ = await client.fetchUsage()
        #expect(keyReads.count == 1)
        // Desktop refreshes its token (the cache file changes) → we read again
        // and recover on the next poll.
        blobs.value = [encryptV10(cacheData([
            (client: "a", scopes: "user:inference user:profile", token: "good-tok", expiresMs: expiry),
        ]))]
        guard case .success(let snap) = await client.fetchUsage() else { Issue.record("expected success"); return }
        #expect(keyReads.count == 2)
        #expect(snap.fiveHour?.usedPercentage == 7)
        #expect(store.load()?.accessToken == "good-tok")
    }

    /// The reported bug, modelled directly: Claude Code's token is expired and
    /// never refreshed (issue #6), so resolution drops to the slow path every
    /// poll, and the Desktop read keeps failing (declined / 5s timeout) so no
    /// valid token is ever cached. The Desktop keychain must still be read only
    /// ONCE while its file is unchanged — not re-prompted on every poll.
    @Test func expiredKeychainTokenDoesNotRePromptDesktopEveryPoll() async {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let keyReads = CallCounter()
        let kc = countingKeychain(token: "cc-expired", expiry: now.addingTimeInterval(-3600), counter: CallCounter())
        let dt = DesktopOAuth(
            keyReader: { keyReads.bump(); return .failure(.keychainAccessDenied) },  // declined / timed out
            cacheReader: { ["unchanging-blob"] }
        )
        let (client, _) = resolvingClient(keychain: kc, desktop: dt, desktopEnabled: true, now: now) { _ in (200, 5) }
        for _ in 0..<4 { _ = await client.fetchUsage() }
        #expect(keyReads.count == 1)  // read once; not once per poll
    }

    /// A minimal thread-safe mutable holder for tests.
    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var v: T
        init(_ v: T) { self.v = v }
        var value: T {
            get { lock.lock(); defer { lock.unlock() }; return v }
            set { lock.lock(); v = newValue; lock.unlock() }
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
