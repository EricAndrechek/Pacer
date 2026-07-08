import Foundation

/// Errors from `OAuthClient.fetchUsage`. The poller switches on these
/// to decide whether to back off, log-and-continue, or surface "no
/// credentials" silently. Most cases are recoverable — only the
/// `keychainMalformed` and `responseSchemaMismatch` cases imply Pacer
/// needs a code change to keep working.
public enum OAuthClientError: Error, Sendable {
    /// No Claude Code login on this machine. Steady state for a fresh
    /// install before the user signs into Claude Code; not an error
    /// from the user's perspective.
    case credentialsNotFound
    /// User declined the macOS keychain access prompt, or the daemon
    /// has no UI to show it. Recoverable by foregrounding the app once.
    case keychainAccessDenied
    /// Claude Code's blob shape changed and our decoder doesn't know it.
    /// Investigate before suppressing.
    case keychainMalformed(String)
    /// Some other `SecItemCopyMatching` status. Carries the raw OSStatus.
    case keychainStatus(OSStatus)
    /// Token expired locally — `expiresAt` in the past. Skip the call
    /// (it would 401 anyway) and let Claude Code refresh on its own;
    /// our next read picks up the new token.
    case tokenExpired(at: Date)
    /// Server replied 401. Token may have rotated mid-flight; try again
    /// next poll. Distinct from `tokenExpired` because the server is
    /// authoritative — we may get 401 even when our local clock thinks
    /// the token is fine (clock skew, mid-rotation race).
    case unauthorized(body: String)
    /// Server replied 429. `retryAfter` is parsed from the
    /// `Retry-After` header (seconds-form OR HTTP-date form), or nil
    /// when absent. Poller picks the larger of this and its own backoff.
    case rateLimited(retryAfter: TimeInterval?)
    /// Any other non-2xx response. Status carried for log routing,
    /// body truncated for context.
    case http(status: Int, body: String)
    /// URLSession-level failure: DNS, connection refused, TLS, the
    /// request was cancelled (Task cancellation), etc.
    case transport(underlying: Error)
    /// Body was 2xx but didn't decode into the schema we expect.
    /// Likely an Anthropic-side change to the response shape.
    case responseSchemaMismatch(String)
}

/// Typed wrapper around `GET https://api.anthropic.com/api/oauth/usage`,
/// the undocumented endpoint Claude Code itself polls for the rate-limit
/// banner. Schema verified live against Claude Code 2.1.x and matches
/// what every community statusline tool consumes; if Anthropic moves
/// or removes it, the whole ecosystem breaks at once and we'll know.
///
/// Two injection points for tests:
///   - `keychain` — a `KeychainOAuth` whose `rawReader` returns canned data.
///   - `transport` — a closure that takes a `URLRequest` and returns
///     `(Data, HTTPURLResponse)`. Production uses `URLSession.shared`.
///
/// All work happens off the main actor — `URLSession.data(for:)` is
/// cooperative-task-cancellable, and `KeychainOAuth.read()` is a fast
/// synchronous SecItem call. The client is `Sendable` so the poller
/// actor can hold and call it without isolation hops.
/// One credential the poller could spend, tagged with where it came
/// from. `source` lets the poller prefer a primary-account token
/// (keychain / manual override) when deciding which lane establishes
/// the account the whole pool is guarded against.
public struct CredentialCandidate: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable, Codable {
        case override, keychain, held, desktop
    }
    public let credential: OAuthCredential
    public let source: Source
    public init(credential: OAuthCredential, source: Source) {
        self.credential = credential
        self.source = source
    }
}

public struct OAuthClient: Sendable {

    /// Anthropic's undocumented usage endpoint. Stable for ~a year;
    /// every community tool (claude-hud, ccstatusline, etc.) uses this
    /// exact URL.
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Beta-channel header Claude Code sends with its own requests.
    /// This version returns 200 against live accounts; older values may
    /// also work but we send what we know is current.
    public static let betaHeader = "oauth-2025-04-20"

    /// We identify polling traffic honestly so Anthropic's logs can
    /// distinguish Pacer from first-party Claude Code. NOT impersonating
    /// claude-code/2.x — being identifiable matters more than being
    /// invisible if Anthropic ever audits ecosystem usage.
    public static let userAgent = "pacer/1.0 (+https://github.com/ericandrechek/pacer)"

    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let keychain: KeychainOAuth
    private let transport: Transport
    private let now: @Sendable () -> Date
    /// Optional manual access-token source. Default reads from the
    /// App Group UserDefaults entry that the Settings UI writes; tests
    /// inject a fixed closure. When this returns a non-empty value, the
    /// poller skips the keychain read entirely and uses the override
    /// directly — workaround for Claude Code 2.x not persisting
    /// refreshed tokens to the keychain (#6).
    private let tokenOverride: @Sendable () -> String?
    /// Claude Desktop credential source, consulted only when
    /// `desktopEnabled()` is true (the user opted in). Read-only.
    private let desktop: DesktopOAuth
    private let desktopEnabled: @Sendable () -> Bool
    /// Pacer's own persisted copy of a working token. Defaults to an
    /// in-memory store so tests and Settings probes never touch the real
    /// keychain; production passes `KeychainCredentialStore()` to persist.
    private let heldStore: HeldCredentialStoring
    /// Tokens the server has 401'd this process, so resolution won't re-pick
    /// a revoked one and instead falls through to the next-freshest.
    private let rejected: RejectedTokens
    /// Tracks Claude Desktop's token-file fingerprint so we re-read its
    /// keychain item — which can pop a macOS prompt "Always Allow" won't
    /// reliably silence — only when its tokens actually changed. See
    /// `DesktopReadGate`.
    private let desktopGate: DesktopReadGate
    /// Pacer's cached copy of Claude Desktop's `Claude Safe Storage` AES
    /// key. Since that key is stable for the life of the Desktop install,
    /// caching it lets `candidateCredentials` decrypt every future
    /// `config.json` change without re-reading the (prompt-risking)
    /// keychain item. See `KeychainDesktopKeyStore`.
    private let desktopKeyStore: DesktopKeyStoring

    /// How long before a held token's expiry we go back to the sources for a
    /// fresher one. Until then we serve the held copy without touching
    /// Claude's keychain / Desktop store at all.
    private static let refreshLeadTime: TimeInterval = 10 * 60

    public init(
        keychain: KeychainOAuth = KeychainOAuth(),
        transport: @escaping Transport = OAuthClient.defaultTransport,
        now: @escaping @Sendable () -> Date = { Date() },
        tokenOverride: @escaping @Sendable () -> String? = { PacerPreferences.oauthTokenOverride() },
        desktop: DesktopOAuth = DesktopOAuth(),
        desktopEnabled: @escaping @Sendable () -> Bool = { PacerPreferences.desktopCredentialsEnabled() },
        heldStore: HeldCredentialStoring = EphemeralCredentialStore(),
        rejected: RejectedTokens = RejectedTokens(),
        desktopGate: DesktopReadGate = DesktopReadGate(),
        desktopKeyStore: DesktopKeyStoring = EphemeralDesktopKeyStore()
    ) {
        self.keychain = keychain
        self.transport = transport
        self.now = now
        self.tokenOverride = tokenOverride
        self.desktop = desktop
        self.desktopEnabled = desktopEnabled
        self.heldStore = heldStore
        self.rejected = rejected
        self.desktopGate = desktopGate
        self.desktopKeyStore = desktopKeyStore
    }

    /// Production transport: `URLSession.shared.data(for:)` plus the
    /// HTTPURLResponse cast. Errors propagate as thrown.
    public static let defaultTransport: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            // Should be impossible against an `https://` URL, but typed
            // out so we never silently treat a non-HTTP response as
            // 200-OK.
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    /// One round-trip against `/api/oauth/usage` using the auto-resolved
    /// credential (manual override → keychain → held → opted-in Desktop,
    /// freshest wins). Used by the Settings probe and any single-token
    /// caller. The multi-token poller uses `candidateCredentials()` +
    /// `fetchUsage(using:)` instead so it controls which budget it spends.
    public func fetchUsage() async -> Result<RateLimitSnapshot, OAuthClientError> {
        let credential: OAuthCredential
        let fromHeldStore: Bool
        switch resolveCredential() {
        case .success(let resolution):
            credential = resolution.credential
            fromHeldStore = resolution.fromHeldStore
        case .failure(let error):
            return .failure(error)
        }
        let result = await performFetch(credential: credential)
        // Preserve the single-token path's behavior: a 401 on the held
        // copy drops it so the next poll re-derives from the sources.
        if case .failure(.unauthorized) = result, fromHeldStore {
            heldStore.clear()
        }
        return result
    }

    /// One round-trip using a SPECIFIC credential, bypassing resolution.
    /// The multi-token poller calls this per lane so it controls exactly
    /// which token — and thus which independent rate-limit budget — each
    /// poll spends. A 401 rejects the token process-wide (so lane
    /// selection won't re-pick it) but never touches the held store;
    /// lane lifecycle is the poller's job.
    public func fetchUsage(using credential: OAuthCredential) async -> Result<RateLimitSnapshot, OAuthClientError> {
        await performFetch(credential: credential)
    }

    /// The shared HTTP round-trip: build → send → status-branch → decode.
    /// On 401 it rejects the token; held-store cleanup is left to the
    /// caller so the specific-token path doesn't disturb resolution state.
    private func performFetch(credential: OAuthCredential) async -> Result<RateLimitSnapshot, OAuthClientError> {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        // Be explicit — the server defaults to JSON, but locking it in
        // makes proxies and CDNs less likely to vary the response.
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // URLSession.data is task-cancellable so a poller stop
        // propagates here cleanly.
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            return .failure(.transport(underlying: error))
        }

        let body = String(data: data, encoding: .utf8) ?? "<non-UTF8 body, \(data.count) bytes>"
        switch response.statusCode {
        case 200..<300:
            break // fall through to decode
        case 401:
            // This token is bad. Blocklist it so resolution / lane
            // selection falls through to the next candidate.
            rejected.reject(credential.accessToken)
            return .failure(.unauthorized(body: truncate(body, max: 200)))
        case 429:
            return .failure(.rateLimited(
                retryAfter: parseRetryAfter(response.value(forHTTPHeaderField: "Retry-After"))
            ))
        default:
            return .failure(.http(status: response.statusCode, body: truncate(body, max: 200)))
        }

        // Same-account guard input: the account this response belongs to.
        let orgId = response.value(forHTTPHeaderField: "anthropic-organization-id")

        // Decode. We tolerate either window being missing/null and
        // tolerate `resets_at: null`. Only a wholly-broken shape is a
        // hard failure.
        let snapshot: RateLimitSnapshot
        do {
            snapshot = try decode(body: data, sampledAt: now(), organizationId: orgId)
        } catch {
            return .failure(.responseSchemaMismatch(error.localizedDescription))
        }
        return .success(snapshot)
    }

    /// All usable (non-expired, non-rejected) candidate credentials for
    /// polling, de-duplicated by access token, freshest first, each
    /// tagged with its source. The multi-token poller unions these into
    /// its persistent lane set.
    ///
    /// Reads Claude Code's keychain (silent) and, for opted-in Claude
    /// Desktop, decrypts its token cache with our CACHED AES key — so no
    /// prompt-risking keychain read unless that key has gone stale (see
    /// `resolveDesktopTokens`). A manual override, when set, is the sole
    /// candidate.
    ///
    /// - Parameter cachedDesktopTokens: the Desktop-origin tokens the
    ///   caller (the poller) already holds, used only to decide the Desktop
    ///   escalation.
    public func candidateCredentials(cachedDesktopTokens: [OAuthCredential] = []) -> [CredentialCandidate] {
        // Manually-added tokens are no longer a "sole override" that
        // replaces auto-discovery — they live in the poller's pool as
        // `.override` lanes and are seeded from there, so here we only
        // gather the live sources and let them union into the pool.
        let referenceNow = now()
        let usable: (OAuthCredential) -> Bool = { [rejected] cred in
            !rejected.isRejected(cred.accessToken)
                && (cred.expiresAt == nil || cred.expiresAt! >= referenceNow)
        }
        var out: [CredentialCandidate] = []
        var seen = Set<String>()
        func add(_ cred: OAuthCredential, _ source: CredentialCandidate.Source) {
            guard usable(cred), !seen.contains(cred.accessToken) else { return }
            seen.insert(cred.accessToken)
            out.append(CredentialCandidate(credential: cred, source: source))
        }

        // Order matters for the source LABEL of a token that appears in
        // more than one place: a live source (Claude Code keychain /
        // Claude Desktop) wins over our held copy, so a token is shown by
        // where it actually lives. "Saved by Pacer" then surfaces only for
        // a genuine survivor — a token we still hold that no live source
        // has anymore (e.g. after logout) — which is exactly the case the
        // held store exists to cover.
        if case .success(let c) = keychain.read() { add(c, .keychain) }
        if desktopEnabled() {
            let (tokens, newKey) = resolveDesktopTokens(cachedDesktop: cachedDesktopTokens, now: referenceNow)
            if let newKey { desktopKeyStore.save(newKey) }
            for c in tokens { add(c, .desktop) }
        }
        if let held = heldStore.load() { add(held, .held) }

        // Freshest first (nil expiry sorts as "never expires" ⇒ leads);
        // ties broken by token so the ordering is deterministic.
        return out.sorted {
            let a = $0.credential.expiresAt ?? .distantFuture
            let b = $1.credential.expiresAt ?? .distantFuture
            return a != b ? a > b : $0.credential.accessToken < $1.credential.accessToken
        }
    }

    /// Resolve Claude Desktop's tokens with the layered fallback that keeps
    /// us off the `Claude Safe Storage` prompt:
    ///   1. Decrypt the current `config.json` with our **cached AES key**
    ///      (file read + AES only — no keychain, no prompt). Because the
    ///      key is stable for the install's life, this succeeds ~always and
    ///      also picks up any freshly-rotated tokens.
    ///   2. If the cached key can't decrypt it (⇒ the key rotated, e.g. a
    ///      Desktop reinstall) but we still hold working Desktop tokens,
    ///      keep using those and DEFER the prompt.
    ///   3. Only when the cached key is stale **and** no cached Desktop
    ///      token still works do we re-read `Claude Safe Storage` (the one
    ///      prompt-risking step), caching the fresh key.
    /// Returns the tokens plus a new key to persist (nil unless step 3 read
    /// one).
    private func resolveDesktopTokens(
        cachedDesktop: [OAuthCredential],
        now: Date
    ) -> (tokens: [OAuthCredential], newKey: Data?) {
        let working = { cachedDesktop.filter { $0.expiresAt == nil || $0.expiresAt! >= now } }
        guard let blobs = desktop.readCacheBlobs(), !blobs.isEmpty else {
            return (working(), nil)   // Desktop not installed — keep cached
        }
        // Layer 1: cached key (no prompt).
        if let cachedKey = desktopKeyStore.load() {
            let creds = desktop.profileCredentials(fromBlobs: blobs, keyPassword: cachedKey)
            if !creds.isEmpty { return (creds, nil) }
            // Layer 2: cached key stale, but working cached tokens remain.
            let stillWorking = working()
            if !stillWorking.isEmpty { return (stillWorking, nil) }
        }
        // Layer 3 (or first-ever read): the only prompt-risking step.
        guard case .success(let key) = desktop.readKey() else {
            return (working(), nil)
        }
        let creds = desktop.profileCredentials(fromBlobs: blobs, keyPassword: key)
        return creds.isEmpty ? (working(), nil) : (creds, key)
    }

    // MARK: - Credential resolution

    /// Resolve which token to send, and whether it came from our held store.
    ///
    /// Fast path: a comfortably-valid, non-rejected held token is used
    /// directly — no read of Claude's keychain / Desktop store. Slow path
    /// (no held token, near expiry, or rejected): gather candidates from the
    /// sources (Claude Code keychain + opted-in Desktop) plus the held token
    /// as a fallback, use the freshest non-expired non-rejected one, and
    /// cache it. So we touch Claude's stores about once per token lifetime,
    /// and a still-valid held token keeps us alive even if the user logged
    /// out of Claude Code / removed Desktop.
    private func resolveCredential() -> Result<(credential: OAuthCredential, fromHeldStore: Bool), OAuthClientError> {
        // Manual override wins outright and is never cached.
        if let override = tokenOverride() {
            return .success((OAuthCredential(accessToken: override, expiresAt: nil, subscriptionType: nil), false))
        }

        let referenceNow = now()
        let held = heldStore.load()

        // Fast path: a comfortably-valid held token is served directly,
        // without touching Claude's stores.
        if let held, !rejected.isRejected(held.accessToken),
           let expiresAt = held.expiresAt,
           expiresAt >= referenceNow.addingTimeInterval(Self.refreshLeadTime) {
            return .success((held, true))
        }

        // Slow path: read the sources. The Claude Code keychain read is
        // silent (apple-tool: partition), so we always do it; the held token
        // competes too, serving as the fallback when the sources are
        // unreadable (logged out / Desktop removed).
        var candidates: [OAuthCredential] = []
        var keychainError: OAuthClientError?
        switch keychain.read() {
        case .success(let c):                    candidates.append(c)
        case .failure(.notFound):                keychainError = .credentialsNotFound
        case .failure(.accessDenied):            keychainError = .keychainAccessDenied
        case .failure(.malformedJSON(let u)):    keychainError = .keychainMalformed(u)
        case .failure(.unexpectedStatus(let s)): keychainError = .keychainStatus(s)
        }
        if let held { candidates.append(held) }

        // Claude Desktop's `Claude Safe Storage` item is NOT in the
        // `apple-tool:` partition the `security` CLI reads silently, so each
        // read can pop a macOS approval prompt that "Always Allow" won't
        // reliably persist for a foreign app's item. The failure mode this
        // guards against: when Claude Code's token goes stale and isn't
        // refreshed into the keychain, resolution drops to this slow path on
        // EVERY poll — and reading Desktop here unconditionally re-prompts
        // every few minutes. Two conditions keep the read rare: (1) skip it
        // when we already hold a usable token, and (2) read only when
        // Desktop's token file has actually changed since we last read it —
        // re-reading an unchanged file just re-derives the same credential (or
        // re-fails the same way) and re-prompts for nothing. So we read once,
        // then stay quiet until Desktop writes a new token.
        let usable: (OAuthCredential) -> Bool = { [rejected] cred in
            !rejected.isRejected(cred.accessToken)
                && (cred.expiresAt == nil || cred.expiresAt! >= referenceNow)
        }
        if desktopEnabled(), !candidates.contains(where: usable) {
            let fingerprint = desktop.cacheFingerprint()
            if desktopGate.shouldRead(fingerprint: fingerprint) {
                desktopGate.record(fingerprint: fingerprint)
                if case .success(let creds) = desktop.readAll() {
                    candidates.append(contentsOf: creds)
                }
            }
        }

        let usableCandidates = candidates.filter(usable)
        // Deterministic freshest-wins: latest expiry, ties broken by token.
        let best = usableCandidates.sorted {
            let a = $0.expiresAt ?? .distantFuture
            let b = $1.expiresAt ?? .distantFuture
            return a != b ? a > b : $0.accessToken < $1.accessToken
        }.first

        if let best {
            if best.accessToken != held?.accessToken { heldStore.save(best) }
            return .success((best, best.accessToken == held?.accessToken))
        }
        if let newestExpiry = candidates.compactMap({ $0.expiresAt }).max() {
            // Everything readable is expired — report the latest expiry
            // (Claude Code refreshes its token on next use).
            return .failure(.tokenExpired(at: newestExpiry))
        }
        return .failure(keychainError ?? .credentialsNotFound)
    }

    // MARK: - Decode

    private struct DecodeError: Error { let detail: String }

    private func decode(body: Data, sampledAt: Date, organizationId: String? = nil) throws -> RateLimitSnapshot {
        guard let top = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw DecodeError(detail: "top level was not a JSON object")
        }
        // The endpoint also returns seven_day_opus, seven_day_sonnet,
        // and a handful of internal-codename fields we deliberately
        // ignore. `extra_usage` is the one extra field worth surfacing
        // — Max-plan users can exceed quota at metered rates and want
        // to see that spend.
        return RateLimitSnapshot(
            sampledAt: sampledAt,
            fiveHour: decodeWindow(top["five_hour"]),
            sevenDay: decodeWindow(top["seven_day"]),
            extraUsageCents: Self.decodeExtraUsage(top["extra_usage"]),
            organizationId: organizationId
        )
    }

    /// Parse `extra_usage`. Shape is undocumented — be tolerant. We
    /// accept:
    /// - a number (treated as cents, matching `usage_cents` convention)
    /// - a dict with `amount_cents` / `cents` (number, cents)
    /// - a dict with `amount` / `usd` (number, dollars → cents)
    /// Anything else returns nil, in which case the dashboard chip
    /// stays hidden. Defensive parse beats throwing a decode error
    /// for an optional field.
    static func decodeExtraUsage(_ raw: Any?) -> Int? {
        if let n = numericValue(raw) {
            return Int(n.rounded())
        }
        guard let dict = raw as? [String: Any] else { return nil }
        if let cents = numericValue(dict["amount_cents"]) ?? numericValue(dict["cents"]) {
            return Int(cents.rounded())
        }
        if let dollars = numericValue(dict["amount"]) ?? numericValue(dict["usd"]) {
            return Int((dollars * 100).rounded())
        }
        return nil
    }

    /// Coerce JSON numeric variants (`Double` / `Int` / `NSNumber`) to
    /// a single Double. Strings are deliberately not accepted —
    /// Anthropic's other numeric fields are emitted as numbers, so
    /// receiving a string is a schema change we want to surface as
    /// nil rather than silently parse.
    private static func numericValue(_ raw: Any?) -> Double? {
        if let v = raw as? Double { return v }
        if let v = raw as? Int { return Double(v) }
        if let v = raw as? NSNumber { return v.doubleValue }
        return nil
    }

    private func decodeWindow(_ raw: Any?) -> RateLimitWindow? {
        guard let dict = raw as? [String: Any] else { return nil }
        // Server documents `utilization` as a number 0–100. Accept
        // Double/Int/NSNumber. Anything else is a server-side schema
        // change worth surfacing — return nil so the caller treats
        // this window as "missing this poll" rather than persisting
        // a wrong value.
        let utilization: Double
        if let v = dict["utilization"] as? Double {
            utilization = v
        } else if let v = dict["utilization"] as? Int {
            utilization = Double(v)
        } else if let v = (dict["utilization"] as? NSNumber)?.doubleValue {
            utilization = v
        } else {
            return nil
        }

        // resets_at: ISO-8601, may be empty string or absent. Empty
        // and unparseable both map to nil.
        var resetsAt: Date?
        if let s = dict["resets_at"] as? String, !s.isEmpty {
            resetsAt = parseOAuthISO8601(s)
        }
        return RateLimitWindow(usedPercentage: utilization, resetsAt: resetsAt)
    }
}

// MARK: - Header parsing

/// Honors both forms RFC 7231 allows: integer-seconds and HTTP-date.
/// Returns nil for empty/unparseable values so the caller can fall
/// back to its own backoff schedule.
func parseRetryAfter(_ raw: String?) -> TimeInterval? {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
        return nil
    }
    if let seconds = Double(raw), seconds >= 0 {
        return seconds
    }
    // HTTP-date form: e.g. "Wed, 21 Oct 2026 07:28:00 GMT"
    if let date = httpDateFormatter.date(from: raw) {
        let interval = date.timeIntervalSinceNow
        return interval > 0 ? interval : 0
    }
    return nil
}

/// RFC 7231 IMF-fixdate. Locale-pinned to en_US_POSIX so a user with
/// a non-English locale doesn't break header parsing. `DateFormatter`
/// is now Sendable (Apple finalized this in macOS 14), so no unsafe
/// annotation needed.
private let httpDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "GMT")
    f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return f
}()

/// Two static ISO-8601 parsers, one with fractional seconds, one without.
/// `ISO8601DateFormatter` isn't Sendable but Apple documents `.date(from:)`
/// as thread-safe — same pattern as `ScanCoordinator.ISO8601DateFormatter.shared`.
/// Anthropic's `resets_at` has historically been the no-fractional shape
/// ("2026-05-06T17:30:00Z"); we try plain first, then fall back so a
/// future change to include milliseconds doesn't break parsing.
nonisolated(unsafe) private let plainISO8601: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()
nonisolated(unsafe) private let fractionalISO8601: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

func parseOAuthISO8601(_ s: String) -> Date? {
    plainISO8601.date(from: s) ?? fractionalISO8601.date(from: s)
}

private func truncate(_ s: String, max: Int) -> String {
    s.count <= max ? s : String(s.prefix(max)) + "..."
}
