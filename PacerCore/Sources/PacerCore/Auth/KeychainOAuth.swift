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

/// Reads Claude Code's OAuth credential — from the macOS Keychain when
/// available, falling back to the on-disk `~/.claude/.credentials.json`
/// (the primary store on Linux/Windows, and the only readable source over
/// SSH on macOS, where the Keychain throws `errSecInteractionNotAllowed`).
/// Both carry the interactive `user:profile`-scoped token that
/// `/api/oauth/usage` requires; a `claude setup-token` value is
/// `user:inference`-only and would 401, so it is deliberately NOT a source.
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
    ///
    /// ## File fallback (step 3)
    ///
    /// After both keychain reads, we fall back to the on-disk
    /// `.credentials.json` (see `credentialsFileURLs`). That's the primary
    /// store on Linux/Windows and the only readable source over SSH on
    /// macOS, where the keychain returns `.accessDenied`. Claude Code
    /// writes the same `{"claudeAiOauth": …}` blob there, so decode is
    /// shared.
    public static let defaultRawReader: RawReader = {
        var lastKeychainError: KeychainOAuthError = .notFound
        // 1. Per-user keychain item (Claude Code 2.x).
        switch runSecurityCLI(args: [
            "find-generic-password",
            "-s", KeychainOAuth.serviceName,
            "-a", NSUserName(),
            "-w",
        ]) {
        case .success(let data):
            return .success(data)
        case .failure(let error):
            lastKeychainError = error
        }
        // 2. Legacy no-acct keychain item (older installs). Only worth a
        //    second subprocess when the per-user item was simply absent;
        //    an accessDenied/other error would just repeat.
        if case .notFound = lastKeychainError {
            switch runSecurityCLI(args: [
                "find-generic-password",
                "-s", KeychainOAuth.serviceName,
                "-w",
            ]) {
            case .success(let data):
                return .success(data)
            case .failure(let error):
                lastKeychainError = error
            }
        }
        // 3. On-disk `.credentials.json` fallback (Linux/Windows store,
        //    macOS-over-SSH escape hatch).
        if let data = readCredentialsFileData(urls: credentialsFileURLs()) {
            return .success(data)
        }
        // Nothing readable anywhere — surface the most informative keychain
        // error (`.notFound` on a clean machine, `.accessDenied` over SSH
        // with no file present).
        return .failure(lastKeychainError)
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

    // MARK: - On-disk credentials file fallback

    /// Candidate `.credentials.json` locations, in priority order. Mirrors
    /// `ClaudePathResolver`'s config-dir precedence but WITHOUT its
    /// `projects/` gate — a config dir can hold credentials before any
    /// session JSONL exists (a fresh login, or a chat-only / headless box
    /// that never ran the CLI's project loop):
    ///
    ///   1. `$CLAUDE_CONFIG_DIR` (comma-separated; each entry's file)
    ///   2. `${XDG_CONFIG_HOME:-$HOME/.config}/claude/.credentials.json`
    ///   3. `$HOME/.claude/.credentials.json`
    ///
    /// `internal` (not `private`) so `KeychainOAuthTests` can exercise the
    /// precedence with injected `environment` / `homeDirectory`.
    static func credentialsFileURLs(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        var dirs: [URL] = []
        if let raw = environment["CLAUDE_CONFIG_DIR"], !raw.isEmpty {
            for piece in raw.split(separator: ",", omittingEmptySubsequences: true) {
                let trimmed = piece.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    dirs.append(URL(fileURLWithPath: trimmed))
                }
            }
        } else {
            let xdgBase: URL
            if let raw = environment["XDG_CONFIG_HOME"], !raw.isEmpty {
                xdgBase = URL(fileURLWithPath: raw)
            } else {
                xdgBase = homeDirectory.appendingPathComponent(".config")
            }
            dirs.append(xdgBase.appendingPathComponent("claude"))
            dirs.append(homeDirectory.appendingPathComponent(".claude"))
        }

        var seen = Set<URL>()
        var urls: [URL] = []
        for dir in dirs {
            let url = dir.appendingPathComponent(".credentials.json").standardizedFileURL
            if seen.insert(url).inserted {
                urls.append(url)
            }
        }
        return urls
    }

    /// First readable, non-empty file from `urls`, as raw bytes. `nil`
    /// when none exist or are readable — the caller maps that back to the
    /// keychain error so a clean machine still reports `.notFound`.
    /// Deliberately tolerant: a missing candidate is normal (not every box
    /// has every layout), so we just try the next one.
    static func readCredentialsFileData(urls: [URL]) -> Data? {
        for url in urls {
            if let data = try? Data(contentsOf: url), !data.isEmpty {
                return data
            }
        }
        return nil
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
