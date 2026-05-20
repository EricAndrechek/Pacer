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
/// ## Why we shell out to `/usr/bin/security` instead of `SecItemCopyMatching`
///
/// The Claude Code-credentials keychain item is written by Claude Code
/// (the Node.js CLI) and ends up with two ACL layers:
///   1. Application ACL — names which signed apps may read it.
///   2. Partition list — names which Team IDs the system trusts to
///      satisfy that ACL.
///
/// Claude Code creates the item with partition list `apple-tool:` only.
/// When Pacer (Team ID `YZXWMJ5VBY`) calls `SecItemCopyMatching`, the
/// application-ACL check passes once the user clicks "Always Allow",
/// but the partition-list check fails on every read — Pacer's Team ID
/// isn't in `apple-tool:`. Updating the partition list requires the
/// user's *login-keychain password*, not just a click on the prompt;
/// without that password, "Always Allow" only suppresses the prompt
/// for the current call. Result: a recurring prompt every poll cycle.
///
/// `/usr/bin/security` is an Apple-signed binary that's already in both
/// layers (it's the canonical `apple-tool:` partition member), so it
/// reads without prompting. This costs one ~10ms subprocess every 5
/// minutes — negligible — and works without asking the user to do
/// anything special.
///
/// ## First-run UX
///
/// Because `/usr/bin/security` is already trusted, there is no system
/// dialog on first read. Pacer can poll silently from launch.
///
/// ## Test seam
///
/// Production wires `defaultRawReader`, which shells out to
/// `/usr/bin/security find-generic-password -w`. Tests inject a closure
/// that returns prebaked Data (or a typed error) — see
/// `KeychainOAuthTests.swift`.
public struct KeychainOAuth: Sendable {

    /// Service name Claude Code writes its credential under, verified
    /// from `security find-generic-password -s "Claude Code-credentials"`
    /// on the user's machine. This string is also hardcoded in every
    /// community statusline tool; Anthropic has not changed it in ~a year.
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

    /// Production reader. Shells out to `/usr/bin/security
    /// find-generic-password -w` and returns the printed JSON blob.
    /// See the type doc for why we use the CLI instead of SecItem.
    ///
    /// We deliberately do NOT pin `-a <username>` — Claude Code stores
    /// the entry under the current user but the service name is unique
    /// on a normal install, and skipping `-a` keeps us robust to
    /// account-name edge cases (renamed accounts, multi-user setups).
    ///
    /// Exit-status mapping comes from the `security(1)` man page and
    /// confirmation from `SecBase.h`:
    ///   - 0  → success; stdout is the password blob plus a trailing newline
    ///   - 44 → `errSecItemNotFound` (-25300, masked to one byte)
    ///   - 36 → `errSecAuthFailed` (-25293, masked) — user cancelled
    ///   - 51 → `errSecInteractionNotAllowed` (-25308, masked) — non-UI context
    /// Anything else is surfaced raw via `.unexpectedStatus`.
    public static let defaultRawReader: RawReader = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", KeychainOAuth.serviceName,
            "-w",
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            // Couldn't even spawn — bad PATH, missing binary, sandbox
            // refusal. Carry the underlying CocoaError code so a log
            // reader can route it.
            let nsError = error as NSError
            return .failure(.unexpectedStatus(OSStatus(nsError.code)))
        }

        // The keychain is normally unlocked at login, so the subprocess
        // returns in well under a second. The timeout below is a safety
        // net for the pathological "locked keychain prompts modally"
        // case; without it, a single bad keychain state could wedge the
        // poller actor forever.
        let timeoutSeconds: TimeInterval = 5
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            group.leave()
        }
        if group.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            process.terminate()
            // Drain so the kernel doesn't hold the pipes open.
            _ = try? stdout.fileHandleForReading.readToEnd()
            _ = try? stderr.fileHandleForReading.readToEnd()
            return .failure(.accessDenied)
        }

        let status = process.terminationStatus
        switch status {
        case 0:
            let data = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
            return .success(data)
        case 44:
            return .failure(.notFound)
        case 36, 51, 128:
            return .failure(.accessDenied)
        default:
            return .failure(.unexpectedStatus(OSStatus(status)))
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
        // `security -w` emits the password followed by a newline; trim
        // it so JSON parse sees a clean object.
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
