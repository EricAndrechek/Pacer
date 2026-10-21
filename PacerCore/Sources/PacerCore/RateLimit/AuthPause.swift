import Foundation

/// Whether an account's readings have stopped because its token expired while
/// it was idle (#198), so freshness can say why instead of a frozen "33m ago".
///
/// Pacer never refreshes a token (rotation would invalidate the one Claude
/// Code is using, and a switcher's copy), so an access token that expires
/// while nobody uses the account stays expired, the poller drops its lane,
/// and nothing new arrives until Claude Code next runs on that account and
/// refreshes it. That is accurate as "1 hr ago", but says nothing about why
/// or about when it ends.
///
/// Owner decision (2026-10-20): show it only when both hold. The token has
/// expired: no unexpired token for the account is left in the pool, and Pacer
/// did read it before (an account it never had a token for says "no reading
/// yet", as before). And the account is idle: nothing has used it since the
/// last reading, which has been quiet for `minimumQuiet`. A turn after the
/// reading means Claude Code is running and about to refresh the token, so
/// the pause is ending and there is nothing to say.
public enum AuthPause {
    public static let label = "auth paused"
    /// The reason, for a tooltip. Terse.
    public static let reason = "Token expired while the account was idle. Readings resume when it is next used."

    /// How long the last reading must have been quiet before the pause is
    /// worth saying: an expiry between two polls is not one.
    public static let minimumQuiet: TimeInterval = 10 * 60

    public static func isPaused(
        liveTokenCount: Int, lastReadingAt: Date?, lastActivityAt: Date?, now: Date
    ) -> Bool {
        guard liveTokenCount == 0, let reading = lastReadingAt else { return false }
        if let activity = lastActivityAt, activity > reading { return false }
        return now.timeIntervalSince(reading) >= minimumQuiet
    }
}

public extension TokenPoolStatus {
    /// How many unexpired tokens the pool holds for `accountId`. nil until the
    /// poller has published, when nothing can be said.
    func liveTokenCount(account accountId: String?, now: Date = Date()) -> Int? {
        guard hasLoaded, let accountId else { return nil }
        return lanes.filter {
            $0.accountKey == accountId && ($0.expiresAt.map { $0 > now } ?? true)
        }.count
    }

    /// `AuthPause.isPaused` for an account, from the pool as published.
    func isAuthPaused(account accountId: String?, lastReadingAt: Date?,
                      lastActivityAt: Date?, now: Date = Date()) -> Bool {
        guard let live = liveTokenCount(account: accountId, now: now) else { return false }
        return AuthPause.isPaused(liveTokenCount: live, lastReadingAt: lastReadingAt,
                                  lastActivityAt: lastActivityAt, now: now)
    }
}
