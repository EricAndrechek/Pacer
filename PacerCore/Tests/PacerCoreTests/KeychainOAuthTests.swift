import Foundation
import Testing
@testable import PacerCore

/// All tests inject a closure for `rawReader` rather than touching the
/// real keychain — Swift Testing runs in parallel and `SecItemCopyMatching`
/// against a real entry would prompt the user mid-test-suite.
@Suite struct KeychainOAuthTests {

    // MARK: - Decoding the blob

    @Test func decodesValidBlob() {
        let body = """
        {
          "claudeAiOauth": {
            "accessToken": "sk-ant-oat01-fake-token",
            "expiresAt": 1859200000000,
            "subscriptionType": "max20x",
            "refreshToken": "ignored",
            "scopes": ["user:profile"]
          }
        }
        """
        let reader = KeychainOAuth(rawReader: { .success(Data(body.utf8)) })

        guard case .success(let cred) = reader.read() else {
            Issue.record("expected success")
            return
        }
        #expect(cred.accessToken == "sk-ant-oat01-fake-token")
        #expect(cred.subscriptionType == "max20x")
        // 1859200000000 ms = 2028-12-...
        #expect(cred.expiresAt != nil)
        #expect(cred.expiresAt!.timeIntervalSince1970 == 1859200000.0)
    }

    @Test func decodesBlobWithoutOptionalFields() {
        // No expiresAt, no subscriptionType — both are tolerated.
        let body = #"{"claudeAiOauth":{"accessToken":"tok"}}"#
        let reader = KeychainOAuth(rawReader: { .success(Data(body.utf8)) })

        let result = reader.read()
        guard case .success(let cred) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(cred.accessToken == "tok")
        #expect(cred.expiresAt == nil)
        #expect(cred.subscriptionType == nil)
    }

    @Test func decodesExpiresAtAsString() {
        // Defensive parse: some legacy account variants store expiresAt
        // as a stringified milliseconds value rather than a number.
        let body = #"{"claudeAiOauth":{"accessToken":"tok","expiresAt":"1759200000000"}}"#
        let reader = KeychainOAuth(rawReader: { .success(Data(body.utf8)) })

        guard case .success(let cred) = reader.read() else {
            Issue.record("expected success")
            return
        }
        #expect(cred.expiresAt?.timeIntervalSince1970 == 1759200000.0)
    }

    @Test func tolerateLeadingTrailingWhitespace() {
        // The `security -w` CLI emits a trailing newline; SecItemCopyMatching
        // doesn't, but we trim defensively in case of injected/rawer paths.
        let body = "  \n  {\"claudeAiOauth\":{\"accessToken\":\"tok\"}}  \n  "
        let reader = KeychainOAuth(rawReader: { .success(Data(body.utf8)) })
        guard case .success = reader.read() else {
            Issue.record("expected success after whitespace trim")
            return
        }
    }

    // MARK: - Decoding failures

    @Test func rejectsMissingAccessToken() {
        let body = #"{"claudeAiOauth":{"subscriptionType":"pro"}}"#
        let reader = KeychainOAuth(rawReader: { .success(Data(body.utf8)) })
        guard case .failure(.malformedJSON) = reader.read() else {
            Issue.record("expected malformedJSON failure")
            return
        }
    }

    @Test func rejectsEmptyAccessToken() {
        let body = #"{"claudeAiOauth":{"accessToken":""}}"#
        let reader = KeychainOAuth(rawReader: { .success(Data(body.utf8)) })
        guard case .failure(.malformedJSON) = reader.read() else {
            Issue.record("expected malformedJSON failure for empty token")
            return
        }
    }

    @Test func rejectsMissingWrapper() {
        // Top level is object but lacks the `claudeAiOauth` envelope.
        let body = #"{"accessToken":"tok"}"#
        let reader = KeychainOAuth(rawReader: { .success(Data(body.utf8)) })
        guard case .failure(.malformedJSON) = reader.read() else {
            Issue.record("expected malformedJSON failure")
            return
        }
    }

    @Test func rejectsNonJSON() {
        let body = "this is not even json"
        let reader = KeychainOAuth(rawReader: { .success(Data(body.utf8)) })
        guard case .failure(.malformedJSON) = reader.read() else {
            Issue.record("expected malformedJSON failure for non-JSON input")
            return
        }
    }

    // MARK: - Error pass-through

    @Test func passesThroughNotFound() {
        let reader = KeychainOAuth(rawReader: { .failure(.notFound) })
        #expect(reader.read() == .failure(.notFound))
    }

    @Test func passesThroughAccessDenied() {
        let reader = KeychainOAuth(rawReader: { .failure(.accessDenied) })
        #expect(reader.read() == .failure(.accessDenied))
    }

    @Test func throwingApiSurfacesError() {
        let reader = KeychainOAuth(rawReader: { .failure(.notFound) })
        #expect(throws: KeychainOAuthError.notFound) {
            try reader.readOrThrow()
        }
    }

    // MARK: - On-disk credentials file fallback

    @Test func credentialsFileURLsDefaultPrecedence() {
        // No env overrides: XDG default (~/.config/claude) then ~/.claude,
        // each pointing at `.credentials.json`.
        let home = URL(fileURLWithPath: "/Users/test")
        let urls = KeychainOAuth.credentialsFileURLs(environment: [:], homeDirectory: home)
        #expect(urls.map(\.path) == [
            "/Users/test/.config/claude/.credentials.json",
            "/Users/test/.claude/.credentials.json",
        ])
    }

    @Test func credentialsFileURLsHonorsXDGConfigHome() {
        let home = URL(fileURLWithPath: "/Users/test")
        let urls = KeychainOAuth.credentialsFileURLs(
            environment: ["XDG_CONFIG_HOME": "/xdg"],
            homeDirectory: home
        )
        #expect(urls.map(\.path) == [
            "/xdg/claude/.credentials.json",
            "/Users/test/.claude/.credentials.json",
        ])
    }

    @Test func credentialsFileURLsHonorsConfigDirOverride() {
        // CLAUDE_CONFIG_DIR is exclusive (mirrors ClaudePathResolver): the
        // XDG/~/.claude defaults are NOT appended. Comma-separated, trimmed,
        // deduped. The file lives directly under each listed dir.
        let home = URL(fileURLWithPath: "/Users/test")
        let urls = KeychainOAuth.credentialsFileURLs(
            environment: ["CLAUDE_CONFIG_DIR": " /a , /b , /a "],
            homeDirectory: home
        )
        #expect(urls.map(\.path) == [
            "/a/.credentials.json",
            "/b/.credentials.json",
        ])
    }

    @Test func readCredentialsFileDataReturnsFirstReadable() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pacer-cred-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let missing = dir.appendingPathComponent("missing.json")
        let empty = dir.appendingPathComponent("empty.json")
        let real = dir.appendingPathComponent("real.json")
        try Data().write(to: empty)
        let blob = #"{"claudeAiOauth":{"accessToken":"tok"}}"#
        try Data(blob.utf8).write(to: real)

        // First candidate missing, second empty (skipped), third is real.
        let data = KeychainOAuth.readCredentialsFileData(urls: [missing, empty, real])
        #expect(data == Data(blob.utf8))

        // None readable → nil.
        #expect(KeychainOAuth.readCredentialsFileData(urls: [missing]) == nil)
    }

    @Test func fileFallbackBlobDecodesLikeKeychain() {
        // A `.credentials.json` blob has the same `claudeAiOauth` wrapper as
        // the keychain item, so the shared decode path handles it. Simulate
        // the file-fallback raw reader returning that blob.
        let blob = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-file","scopes":["user:inference","user:profile"]}}"#
        let reader = KeychainOAuth(rawReader: { .success(Data(blob.utf8)) })
        guard case .success(let cred) = reader.read() else {
            Issue.record("expected success decoding a file-shaped blob")
            return
        }
        #expect(cred.accessToken == "sk-ant-oat01-file")
    }

    // MARK: - Live integration (gated)
    //
    // Set `PACER_RUN_LIVE_KEYCHAIN_TEST=1` to actually call SecItem
    // against the real keychain. WILL prompt the user if the calling
    // binary doesn't have an existing ACL grant; otherwise verifies the
    // production reader returns a token whose access string is the
    // expected Anthropic shape.

    @Test func liveKeychainRead() async throws {
        guard ProcessInfo.processInfo.environment["PACER_RUN_LIVE_KEYCHAIN_TEST"] == "1" else {
            return
        }
        let reader = KeychainOAuth()
        let result = reader.read()
        switch result {
        case .success(let cred):
            #expect(!cred.accessToken.isEmpty)
            #expect(cred.accessToken.hasPrefix("sk-ant-"))
        case .failure(.notFound):
            Issue.record("keychain entry not present — sign into Claude Code first")
        case .failure(.accessDenied):
            Issue.record("user denied keychain access — re-run and approve the prompt")
        case .failure(let other):
            Issue.record("unexpected failure: \(other)")
        }
    }
}
