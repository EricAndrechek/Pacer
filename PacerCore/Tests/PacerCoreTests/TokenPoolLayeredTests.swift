import Foundation
import CommonCrypto
import SwiftData
import Testing
@testable import PacerCore

/// Covers the persistent token pool + the layered Claude Desktop read
/// (cached-key fast path → cached tokens → Safe Storage only as a last
/// resort). The "did we read Safe Storage" question is answered by
/// counting `keyReader` calls.
@Suite struct TokenPoolLayeredTests {

    private static let testKey = Data("pacer-test-safe-storage-key".utf8)
    private static let host = "https://api.anthropic.com"
    private static var futureMs: Int64 { Int64(Date().addingTimeInterval(3600).timeIntervalSince1970) * 1000 }

    final class KeyReadCounter: @unchecked Sendable {
        private let lock = NSLock(); private var v = 0
        func bump() { lock.lock(); v += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return v }
    }

    /// Mirror of `DesktopOAuth.decrypt` in the encrypt direction.
    private func encryptV10(_ plaintext: Data, keyPassword: Data = testKey) -> String {
        let key = DesktopOAuth.pbkdf2SHA1(password: keyPassword, salt: Data("saltysalt".utf8),
                                          rounds: 1003, keyLength: kCCKeySizeAES128)!
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var out = Data(count: plaintext.count + kCCBlockSizeAES128)
        var moved = 0
        let status = out.withUnsafeMutableBytes { o in
            plaintext.withUnsafeBytes { p in key.withUnsafeBytes { k in iv.withUnsafeBytes { v in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        k.baseAddress, key.count, v.baseAddress, p.baseAddress, plaintext.count,
                        o.baseAddress, o.count, &moved)
            }}}
        }
        precondition(status == kCCSuccess)
        out.removeSubrange(moved..<out.count)
        return (Data("v10".utf8) + out).base64EncodedString()
    }

    /// A single `user:profile` cache blob for `token`, encrypted with `key`.
    private func blob(token: String, key: Data = testKey) -> String {
        let dict: [String: Any] = [
            "c1:acct:\(Self.host):user:profile": [
                "token": token, "refreshToken": "r-\(token)",
                "expiresAt": Self.futureMs, "subscriptionType": "max",
            ]
        ]
        return encryptV10(try! JSONSerialization.data(withJSONObject: dict), keyPassword: key)
    }

    private func desktopClient(
        cachedKey: Data?,
        blobKey: Data = testKey,
        keyReads: KeyReadCounter
    ) -> OAuthClient {
        OAuthClient(
            keychain: KeychainOAuth(rawReader: { .failure(.notFound) }),
            desktop: DesktopOAuth(
                keyReader: { keyReads.bump(); return .success(Self.testKey) },
                cacheReader: { [self.blob(token: "desk-live", key: blobKey)] }
            ),
            desktopEnabled: { true },
            desktopKeyStore: EphemeralDesktopKeyStore(cachedKey)
        )
    }

    // MARK: - Stores round-trip

    @Test func tokenPoolStoreRoundTrips() {
        let store = EphemeralTokenPoolStore()
        let toks = [
            StoredToken(credential: OAuthCredential(accessToken: "a", expiresAt: nil, subscriptionType: nil), source: .keychain),
            StoredToken(credential: OAuthCredential(accessToken: "b", expiresAt: nil, subscriptionType: nil), source: .desktop),
        ]
        store.saveAll(toks)
        #expect(store.loadAll() == toks)
        store.clear()
        #expect(store.loadAll().isEmpty)
    }

    // MARK: - Layered Desktop resolution

    @Test func cachedKeyDecryptsWithoutReadingSafeStorage() {
        let keyReads = KeyReadCounter()
        let client = desktopClient(cachedKey: Self.testKey, keyReads: keyReads)
        let cands = client.candidateCredentials()
        #expect(cands.contains { $0.credential.accessToken == "desk-live" && $0.source == .desktop })
        #expect(keyReads.count == 0)   // Layer 1: never touched Safe Storage
    }

    @Test func staleKeyKeepsWorkingCachedTokensAndDefersPrompt() {
        let keyReads = KeyReadCounter()
        // Cached key is WRONG for the blobs, but we hold a working cached token.
        let client = desktopClient(cachedKey: Data("wrong".utf8), blobKey: Self.testKey, keyReads: keyReads)
        let working = OAuthCredential(accessToken: "cached-desk", expiresAt: Date().addingTimeInterval(3600), subscriptionType: nil)
        let cands = client.candidateCredentials(cachedDesktopTokens: [working])
        #expect(cands.contains { $0.credential.accessToken == "cached-desk" })
        #expect(keyReads.count == 0)   // Layer 2: prompt deferred
    }

    @Test func staleKeyAndExpiredTokensReadsSafeStorageAndCachesKey() {
        let keyReads = KeyReadCounter()
        let store = EphemeralDesktopKeyStore(Data("wrong".utf8))
        let client = OAuthClient(
            keychain: KeychainOAuth(rawReader: { .failure(.notFound) }),
            desktop: DesktopOAuth(
                keyReader: { keyReads.bump(); return .success(Self.testKey) },
                cacheReader: { [self.blob(token: "desk-live")] }
            ),
            desktopEnabled: { true },
            desktopKeyStore: store
        )
        let expired = OAuthCredential(accessToken: "old", expiresAt: Date().addingTimeInterval(-100), subscriptionType: nil)
        let cands = client.candidateCredentials(cachedDesktopTokens: [expired])
        #expect(cands.contains { $0.credential.accessToken == "desk-live" })
        #expect(keyReads.count == 1)          // Layer 3: read exactly once
        #expect(store.load() == Self.testKey) // fresh key cached
    }

    @Test func firstEverReadReadsSafeStorageAndCachesKey() {
        let keyReads = KeyReadCounter()
        let store = EphemeralDesktopKeyStore(nil)   // never cached a key
        let client = OAuthClient(
            keychain: KeychainOAuth(rawReader: { .failure(.notFound) }),
            desktop: DesktopOAuth(
                keyReader: { keyReads.bump(); return .success(Self.testKey) },
                cacheReader: { [self.blob(token: "desk-live")] }
            ),
            desktopEnabled: { true },
            desktopKeyStore: store
        )
        _ = client.candidateCredentials()
        #expect(keyReads.count == 1)
        #expect(store.load() == Self.testKey)
    }

    // MARK: - Poller seeds from the persisted pool on restart

    @Test func pollerSeedsLanesFromPersistedPool() async throws {
        struct StubError: Error {}
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Heartbeat.self, TokenSample.self, DailyAggregate.self, ProjectDailyAggregate.self,
            RateLimitSample.self, SessionInfo.self, ClaudeCodeMeta.self, configurations: config
        )
        let pool = EphemeralTokenPoolStore([
            StoredToken(
                credential: OAuthCredential(accessToken: "seed-tok", expiresAt: Date().addingTimeInterval(3600), subscriptionType: nil),
                source: .desktop
            )
        ])
        // Client that discovers nothing new (no keychain, Desktop off) — so the
        // only lane can come from the seeded pool.
        let client = OAuthClient(
            keychain: KeychainOAuth(rawReader: { .failure(.notFound) }),
            transport: { _ in throw StubError() },
            desktopEnabled: { false }
        )
        let poller = OAuthPoller(client: client, container: container, configuration: .init(),
                                 clock: TestClock(), poolStore: pool)
        let outcome = await poller.runOnce()
        // A seeded lane exists and got polled (transport stub throws) — proving
        // the pool restored a lane without any source read.
        if case .transport = outcome {} else { Issue.record("expected transport from seeded lane, got \(outcome)") }
        #expect(await poller.snapshot().laneCount >= 1)
    }
}
