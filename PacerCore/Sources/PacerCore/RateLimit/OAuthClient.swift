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

    public init(
        keychain: KeychainOAuth = KeychainOAuth(),
        transport: @escaping Transport = OAuthClient.defaultTransport,
        now: @escaping @Sendable () -> Date = { Date() },
        tokenOverride: @escaping @Sendable () -> String? = { PacerPreferences.oauthTokenOverride() }
    ) {
        self.keychain = keychain
        self.transport = transport
        self.now = now
        self.tokenOverride = tokenOverride
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

    /// One round-trip against `/api/oauth/usage`. Returns the typed
    /// snapshot or an `OAuthClientError`.
    public func fetchUsage() async -> Result<RateLimitSnapshot, OAuthClientError> {
        // Step 1: resolve the access token. Manual override (Settings
        // → Authentication) wins when present — we don't even read the
        // keychain, since the override exists exactly for cases where
        // the keychain copy is stale (#6). Otherwise: keychain read,
        // mapping its errors to ours so the caller switches on one
        // error type.
        let credential: OAuthCredential
        if let override = tokenOverride() {
            // Skip the expiresAt gate too — we have no local expiry
            // for an override, so the server is the only authority.
            // A stale override surfaces as `.unauthorized` on the next
            // poll, which the transition logger reports clearly.
            credential = OAuthCredential(
                accessToken: override,
                expiresAt: nil,
                subscriptionType: nil
            )
        } else {
            switch keychain.read() {
            case .success(let c):
                credential = c
            case .failure(.notFound):
                return .failure(.credentialsNotFound)
            case .failure(.accessDenied):
                return .failure(.keychainAccessDenied)
            case .failure(.malformedJSON(let underlying)):
                return .failure(.keychainMalformed(underlying))
            case .failure(.unexpectedStatus(let status)):
                return .failure(.keychainStatus(status))
            }

            // Step 2: skip-if-expired. Local clock gate to avoid a
            // guaranteed 401. Server is authoritative for borderline
            // cases (clock skew under a few minutes), so we check
            // strict expiry only.
            if let expiresAt = credential.expiresAt, expiresAt < now() {
                return .failure(.tokenExpired(at: expiresAt))
            }
        }

        // Step 3: build request.
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        // Be explicit — the server defaults to JSON, but locking it in
        // makes proxies and CDNs less likely to vary the response.
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // Step 4: send. URLSession.data is task-cancellable so a
        // poller stop propagates here cleanly.
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            return .failure(.transport(underlying: error))
        }

        // Step 5: status branching.
        let body = String(data: data, encoding: .utf8) ?? "<non-UTF8 body, \(data.count) bytes>"
        switch response.statusCode {
        case 200..<300:
            break // fall through to decode
        case 401:
            return .failure(.unauthorized(body: truncate(body, max: 200)))
        case 429:
            return .failure(.rateLimited(
                retryAfter: parseRetryAfter(response.value(forHTTPHeaderField: "Retry-After"))
            ))
        default:
            return .failure(.http(status: response.statusCode, body: truncate(body, max: 200)))
        }

        // Step 6: decode. We tolerate either window being missing/null
        // and tolerate `resets_at: null`. Only a wholly-broken shape is
        // a hard failure.
        let snapshot: RateLimitSnapshot
        do {
            snapshot = try decode(body: data, sampledAt: now())
        } catch {
            return .failure(.responseSchemaMismatch(error.localizedDescription))
        }
        return .success(snapshot)
    }

    // MARK: - Decode

    private struct DecodeError: Error { let detail: String }

    private func decode(body: Data, sampledAt: Date) throws -> RateLimitSnapshot {
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
            extraUsageCents: Self.decodeExtraUsage(top["extra_usage"])
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
