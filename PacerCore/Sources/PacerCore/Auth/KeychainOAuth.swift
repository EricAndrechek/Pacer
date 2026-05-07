import Foundation
import Security

/// One decoded copy of the OAuth credential blob Claude Code stores in
/// the user's login Keychain under service name `Claude Code-credentials`.
/// We only ever read this — Claude Code itself rotates and re-writes it.
///
/// The raw blob has additional fields (`refreshToken`, `scopes`, …) that
/// we deliberately don't surface; Pacer needs only the access token to
/// hit `/api/oauth/usage`. Keeping the surface small means a future
/// schema change in irrelevant fields can't break us.
public struct OAuthCredential: Sendable, Equatable {
    public let accessToken: String
    /// Server-side expiry. The endpoint will return 401 if we send an
    /// expired token, so we treat this as advisory — useful for skipping
    /// guaranteed-401 calls but trust the server for borderline cases.
    public let expiresAt: Date?
    /// Surfaced for diagnostics (`pro`, `max5x`, `max20x`, etc.). No
    /// behavior keys off it.
    public let subscriptionType: String?

    public init(accessToken: String, expiresAt: Date?, subscriptionType: String?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.subscriptionType = subscriptionType
    }
}

/// Errors that can come out of `KeychainOAuth.read()`. The poller
/// distinguishes these to decide what to log and whether to back off:
/// `notFound` is the steady state for a user who hasn't signed into
/// Claude Code (don't spam warnings); `accessDenied` is recoverable
/// only by the user clicking through the system prompt; `malformedJSON`
/// almost certainly means Claude Code changed its blob shape and we
/// need to update.
public enum KeychainOAuthError: Error, Sendable, Equatable {
    /// No `Claude Code-credentials` entry in the Keychain. Expected on
    /// a machine where Claude Code was never signed in.
    case notFound
    /// The user declined the system access prompt, or the daemon ran
    /// from a context where macOS refuses to show one
    /// (`errSecInteractionNotAllowed`). Surface to the UI as
    /// "Open Pacer and approve the keychain prompt to enable rate-limit
    /// polling."
    case accessDenied
    /// Item exists but the JSON didn't decode into the shape we expect.
    /// Almost always means Claude Code changed its blob format —
    /// investigate before suppressing.
    case malformedJSON(underlying: String)
    /// `SecItemCopyMatching` returned an OSStatus we don't have a
    /// specific case for. Carries the raw status so logs can route it.
    case unexpectedStatus(OSStatus)
}

/// Reads Claude Code's OAuth credential out of the macOS Keychain.
///
/// ## Why we use `SecItemCopyMatching` directly (not `/usr/bin/security`)
///
/// The reference-impl reference implementation shells out to
/// `/usr/bin/security find-generic-password` because Stream Deck plugins
/// run inside a third-party host process whose Keychain ACL identity is
/// the host, not the plugin — easier to let the system tool handle the
/// prompt than to wrangle access groups. Pacer is a first-party signed
/// `.app`, so `SecItemCopyMatching` triggers a user prompt naming
/// "Pacer" itself: cleaner UX, no subprocess, no exit-code parsing,
/// no PATH dependency. We follow Apple's recommended path.
///
/// ## First-run UX
///
/// The first call from a freshly-installed Pacer (or after the user
/// rotates their login keychain) will surface a system dialog:
/// *"Pacer wants to access 'Claude Code-credentials' in your keychain."*
/// "Always Allow" persists the grant; subsequent reads return silently.
///
/// Pacer.app and PacerDaemon are separate binaries with separate
/// signatures, so each gets its own ACL prompt. The app onboarding flow
/// is responsible for performing the first read in foreground (so the
/// prompt can appear); the daemon's first poll after that may *also*
/// prompt — or, if it runs from a non-interactive launch context, fail
/// with `accessDenied` until the user runs the app once. The poller
/// handles `accessDenied` as a soft failure (no rate-limit data, but
/// JSONL pipeline keeps working).
///
/// ## Test seam
///
/// Production wires `defaultRawReader`, which calls `SecItemCopyMatching`.
/// Tests inject a closure that returns prebaked Data (or a typed error)
/// — see `KeychainOAuthTests.swift`.
public struct KeychainOAuth: Sendable {

    /// Service name Claude Code writes its credential under, verified
    /// from `security find-generic-password -s "Claude Code-credentials"`
    /// on the user's machine. This string is also hardcoded in the
    /// reference-impl Go reference and in every community statusline tool;
    /// Anthropic has not changed it in ~a year.
    public static let serviceName = "Claude Code-credentials"

    /// The injection point. Returns the raw JSON blob bytes on success,
    /// or a typed error mapping known OSStatus values to our domain
    /// errors. Marked `@Sendable` because the poller actor calls it
    /// from a non-isolated context.
    public typealias RawReader = @Sendable () -> Result<Data, KeychainOAuthError>

    private let rawReader: RawReader

    public init(rawReader: @escaping RawReader = KeychainOAuth.defaultRawReader) {
        self.rawReader = rawReader
    }

    /// Production reader. Performs a synchronous `SecItemCopyMatching`
    /// against the user's login keychain. Safe to call from any thread —
    /// Apple documents `SecItemCopyMatching` as thread-safe. Blocks
    /// until the user dismisses the access prompt on first call from
    /// this binary; subsequent calls return immediately once the ACL
    /// is granted.
    public static let defaultRawReader: RawReader = {
        // We deliberately do NOT pin `kSecAttrAccount` — Claude Code
        // writes the entry under the current login user's username,
        // and `SecItemCopyMatching` matches on whatever attributes we
        // specify, ignoring others. Service name is enough to find a
        // single entry. (If two accounts ever existed under the same
        // service, we'd take the first; this would be Anthropic-side
        // behavior change worth investigating, not silently handling.)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainOAuth.serviceName,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                return .failure(.unexpectedStatus(status))
            }
            return .success(data)
        case errSecItemNotFound:
            return .failure(.notFound)
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled:
            return .failure(.accessDenied)
        default:
            return .failure(.unexpectedStatus(status))
        }
    }

    /// Read and decode the credential. Returns the typed value on
    /// success or one of `KeychainOAuthError`'s cases on failure.
    public func read() -> Result<OAuthCredential, KeychainOAuthError> {
        switch rawReader() {
        case .failure(let error):
            return .failure(error)
        case .success(let data):
            return decode(data)
        }
    }

    /// Throwing convenience for callers that prefer `try`. Equivalent
    /// to `read().get()`.
    public func readOrThrow() throws -> OAuthCredential {
        try read().get()
    }

    // MARK: - JSON decode
    //
    // The blob shape (verified live against Claude Code 2.1.x):
    //     { "claudeAiOauth": {
    //         "accessToken": "...",
    //         "expiresAt": 1759200000000,        // Unix ms, optional
    //         "subscriptionType": "max20x",      // optional
    //         "refreshToken": "...",             // ignored
    //         "scopes": [...]                    // ignored
    //     } }
    //
    // We tolerate missing `expiresAt`/`subscriptionType`; their absence
    // is benign on some account types. Missing `accessToken` is fatal —
    // the whole point of the read.

    private func decode(_ data: Data) -> Result<OAuthCredential, KeychainOAuthError> {
        // The keychain blob may have leading/trailing whitespace from
        // how `security -w` formats it; `SecItemCopyMatching` does not
        // add whitespace, but defensive trim is cheap.
        let trimmed = data.trimmedASCIIWhitespace()

        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: trimmed)
        } catch {
            return .failure(.malformedJSON(underlying: "JSON parse: \(error.localizedDescription)"))
        }

        guard let top = parsed as? [String: Any],
              let oauth = top["claudeAiOauth"] as? [String: Any] else {
            return .failure(.malformedJSON(underlying: "missing claudeAiOauth wrapper"))
        }

        guard let accessToken = oauth["accessToken"] as? String, !accessToken.isEmpty else {
            return .failure(.malformedJSON(underlying: "missing or empty accessToken"))
        }

        // expiresAt may be Int64 (Unix milliseconds, the documented form),
        // a JSON number wider than Int (NSNumber path), or a String on
        // some legacy account variants. Accept all three; ignore if
        // unparseable rather than failing — we can still hit the API
        // without it.
        var expiresAt: Date?
        if let ms = (oauth["expiresAt"] as? Int64)
            ?? (oauth["expiresAt"] as? NSNumber)?.int64Value
            ?? Int64((oauth["expiresAt"] as? String) ?? "") {
            if ms > 0 {
                expiresAt = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
            }
        }

        let subscriptionType = oauth["subscriptionType"] as? String

        return .success(OAuthCredential(
            accessToken: accessToken,
            expiresAt: expiresAt,
            subscriptionType: subscriptionType
        ))
    }
}

private extension Data {
    /// Strip leading/trailing 0x09/0x0A/0x0D/0x20 — the four ASCII
    /// whitespace bytes JSON parsers should already tolerate, but being
    /// defensive keeps a stray newline from the keychain tool from
    /// derailing decode.
    func trimmedASCIIWhitespace() -> Data {
        var start = startIndex
        var end = endIndex
        while start < end, Self.isASCIIWhitespace(self[start]) { start = self.index(after: start) }
        while end > start, Self.isASCIIWhitespace(self[self.index(before: end)]) { end = self.index(before: end) }
        return self[start..<end]
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x20
    }
}
