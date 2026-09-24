import Foundation

/// What the credential Claude Code actually bills says about who is signed in.
///
/// Attribution used to take its answer from one place: `oauthAccount` in
/// `~/.claude.json`. That object is not a record of the login. It is part of a
/// config file that *every* Claude Code process sharing the default root
/// rewrites wholesale — a long-lived session that started under another
/// account, or Claude Desktop's embedded Claude Code running a scheduled task
/// on its own login, writes back *its* `oauthAccount` without touching the
/// keychain. The CLI keeps billing the keychain credential; the file now names
/// a different account; and every turn from then on was attributed to an
/// account that was not serving a single request (observed: seven live
/// sessions counted against an account whose five-hour window read 0%, while
/// the signed-in account climbed past 50%).
///
/// The keychain credential is the thing that is billed, and `OAuthPoller`
/// already learns which org it belongs to from the usage response. This type
/// carries that fact from the poller to the attribution trail.
public struct SignedInCredentialReading: Sendable, Equatable {
    /// The account (`Account.id`) the keychain's current token resolved to,
    /// or nil when the keychain holds a token that has not been resolved yet —
    /// the state right after a real switch, before its first poll.
    public let accountKey: String?
    /// The last time the keychain was actually read and still held the token
    /// this reading describes. A reading only speaks for the keychain as of
    /// this instant; anything written after it is unverified.
    public let readAt: Date
    /// The first keychain read of the current unbroken run of `accountKey`.
    /// Between `since` and `readAt` every read found this account's token,
    /// so a trail entry claiming another account inside that interval is
    /// contradicted by the credential itself.
    public let since: Date

    public init(accountKey: String?, readAt: Date, since: Date) {
        self.accountKey = accountKey
        self.readAt = readAt
        self.since = since
    }
}

/// Thread-safe hand-off of the latest `SignedInCredentialReading`.
///
/// Written by `OAuthPoller` (its own actor) and read by the scan loop
/// (`@ScanActor`) once per cycle. A lock rather than an actor hop, because the
/// read sits on the scan's hot path and an actor hop there is the kind of cost
/// AGENTS.md warns about; the critical section is a struct copy.
public final class SignedInCredentialMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var reading: SignedInCredentialReading?

    public init() {}

    public var current: SignedInCredentialReading? {
        lock.lock(); defer { lock.unlock() }
        return reading
    }

    /// Record a keychain read. Keeps `since` while the account is unchanged,
    /// restarts it when the account changes (or becomes unknown).
    ///
    /// A read older than the one already held is ignored, so a slow poll that
    /// resolves a token after a newer discovery cannot rewind the reading.
    public func publish(accountKey: String?, readAt: Date) {
        lock.lock(); defer { lock.unlock() }
        if let prior = reading {
            if readAt < prior.readAt { return }
            if let accountKey, prior.accountKey == accountKey {
                reading = SignedInCredentialReading(
                    accountKey: accountKey, readAt: readAt, since: prior.since)
                return
            }
        }
        reading = SignedInCredentialReading(accountKey: accountKey, readAt: readAt, since: readAt)
    }
}
