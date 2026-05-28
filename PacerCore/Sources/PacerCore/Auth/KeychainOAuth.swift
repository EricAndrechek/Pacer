import Foundation
import Security

/// One decoded copy of the OAuth credential blob Claude Code stores in
/// the user's login Keychain under service name `Claude Code-credentials`.
/// Claude Code itself writes the entry on interactive login; Pacer
/// reads it on every poll and (optionally, on the user's request) does
/// its own refresh via `OAuthClient.refresh` — see #6.
public struct OAuthCredential: Sendable, Equatable {
    public let accessToken: String
    /// Server-side expiry. The endpoint will return 401 if we send an
    /// expired token, so we treat this as advisory — useful for skipping
    /// guaranteed-401 calls but trust the server for borderline cases.
    public let expiresAt: Date?
    /// Used by `OAuthClient.refresh` to exchange for a new access
    /// token. Optional because some legacy blob shapes omitted it; if
    /// it's nil, refresh isn't possible and the user has to re-login.
    public let refreshToken: String?
    /// Surfaced for diagnostics (`pro`, `max5x`, `max20x`, etc.). No
    /// behavior keys off it.
    public let subscriptionType: String?

    public init(
        accessToken: String,
        expiresAt: Date?,
        refreshToken: String? = nil,
        subscriptionType: String?
    ) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.refreshToken = refreshToken
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
    /// ## Why we try `-a NSUserName()` first, then fall back to no-acct
    ///
    /// Claude Code 2.x writes a *new* `Claude Code-credentials` item with
    /// `acct` set to the macOS username (`NSUserName()`). Older installs
    /// (or `claude setup-token` paths) leave a separate item with the
    /// same service name and `acct = ""` — and on a machine that
    /// upgraded, both items coexist.
    ///
    /// `security find-generic-password -s X -w` (no `-a`) silently picks
    /// whichever item the keychain returns first — empirically the
    /// legacy `acct=""` one, which Claude Code 2.x no longer refreshes.
    /// The result is a token that expires ~8 hours after the *original*
    /// login and never updates again — exactly the stall behind #6.
    ///
    /// Strategy: try `-a NSUserName()` first; on errSecItemNotFound
    /// (status 44), fall back to no-acct so older Claude Code installs
    /// that never wrote the per-user item still work.
    ///
    /// Exit-status mapping comes from the `security(1)` man page and
    /// confirmation from `SecBase.h`:
    ///   - 0  → success; stdout is the password blob plus a trailing newline
    ///   - 44 → `errSecItemNotFound` (-25300, masked to one byte)
    ///   - 36 → `errSecAuthFailed` (-25293, masked) — user cancelled
    ///   - 51 → `errSecInteractionNotAllowed` (-25308, masked) — non-UI context
    /// Anything else is surfaced raw via `.unexpectedStatus`.
    public static let defaultRawReader: RawReader = {
        let userScopedResult = runSecurityCLI(args: [
            "find-generic-password",
            "-s", KeychainOAuth.serviceName,
            "-a", NSUserName(),
            "-w",
        ])
        if case .failure(.notFound) = userScopedResult {
            // Fall back to the legacy no-acct read for older Claude
            // Code installs that never wrote the per-user item.
            return runSecurityCLI(args: [
                "find-generic-password",
                "-s", KeychainOAuth.serviceName,
                "-w",
            ])
        }
        return userScopedResult
    }

    /// One-shot subprocess invocation with the 5-second timeout the
    /// production keychain workflow needs. Extracted so the per-user
    /// and legacy reads share identical error-handling.
    private static func runSecurityCLI(args: [String]) -> Result<Data, KeychainOAuthError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = args
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

        let refreshToken = (oauth["refreshToken"] as? String).flatMap {
            $0.isEmpty ? nil : $0
        }
        let subscriptionType = oauth["subscriptionType"] as? String

        return .success(OAuthCredential(
            accessToken: accessToken,
            expiresAt: expiresAt,
            refreshToken: refreshToken,
            subscriptionType: subscriptionType
        ))
    }

    /// Update the on-disk credential after a successful OAuth refresh.
    /// Reads the current blob, mutates the access token / refresh token
    /// / expiry, and writes the modified blob back via
    /// `security add-generic-password -U`. Other fields (scopes,
    /// subscriptionType, anything Claude Code adds we don't model)
    /// round-trip unchanged so we can't accidentally strip a field
    /// Claude Code relies on later.
    ///
    /// Writes are scoped to `acct=NSUserName()`, mirroring the read
    /// path. If the existing entry was a legacy `acct=""` item, we
    /// still write the per-user item — the next read picks it up
    /// thanks to the `-a $USER` first / fallback strategy.
    public func update(
        accessToken: String,
        refreshToken: String,
        expiresAt: Date
    ) -> Result<Void, KeychainOAuthError> {
        // 1. Pull the current blob so we preserve any fields we don't model.
        let raw: Data
        switch rawReader() {
        case .success(let data):
            raw = data
        case .failure(let err):
            return .failure(err)
        }
        let trimmed = raw.trimmedASCIIWhitespace()
        guard var top = (try? JSONSerialization.jsonObject(with: trimmed)) as? [String: Any],
              var oauth = top["claudeAiOauth"] as? [String: Any]
        else {
            return .failure(.malformedJSON(underlying: "couldn't decode existing blob for round-trip"))
        }

        // 2. Mutate just the three fields the refresh response gives us.
        // expiresAt is stored as Unix milliseconds — matches Claude Code's
        // own format (verified live).
        oauth["accessToken"] = accessToken
        oauth["refreshToken"] = refreshToken
        oauth["expiresAt"] = Int64(expiresAt.timeIntervalSince1970 * 1000)
        top["claudeAiOauth"] = oauth

        let updatedJSON: Data
        do {
            updatedJSON = try JSONSerialization.data(withJSONObject: top)
        } catch {
            return .failure(.malformedJSON(underlying: "re-serialize: \(error.localizedDescription)"))
        }

        // 3. Write back. `-U` updates an existing item or creates a new
        // one. We scope by `-a NSUserName()` so we match Claude Code 2.x's
        // per-user item rather than touching the legacy `acct=""` item.
        guard let jsonString = String(data: updatedJSON, encoding: .utf8) else {
            return .failure(.malformedJSON(underlying: "non-UTF8 serialized blob"))
        }
        return Self.runSecurityCLI(args: [
            "add-generic-password",
            "-U",                       // update if exists
            "-s", Self.serviceName,
            "-a", NSUserName(),
            "-w", jsonString,
        ]).map { _ in () }
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
