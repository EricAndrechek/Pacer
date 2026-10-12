import Foundation

/// The `account` event `/v1/stream` pushes when the active login changes
/// (#192).
///
/// **When it fires.** The moment Pacer makes a different account the active
/// one — a `/login`, a cswap switch, a pick in Settings — which, with the
/// login watcher, is within about a second of the switch on disk. Only on a
/// change: never on connect, never when the same login is re-asserted. A
/// fresh `snapshot` event follows it as soon as one is built (usually well
/// under a second later), so a client can treat `account` as "drop what you
/// knew about the old login" and the next `snapshot` as "here is the new one".
///
/// **Shape** (`data:` is one JSON object, ISO-8601 dates, keys sorted):
///
///     event: account
///     data: {
///     data:   "activeAccountId" : "<Account.id>",
///     data:   "since" : "2026-10-09T12:00:00Z"
///     data: }
///
/// - `activeAccountId` — the same id `/v1/accounts` lists and `?account=`
///   takes. The account may have no rate-limit reading yet: a login Pacer has
///   never polled is activated before its first reading (#241), and its
///   windows are absent (not 0%) until that reading lands.
/// - `since` — when Pacer made it the active login.
///
/// Additive: a client that only knows `snapshot` events keeps working, since
/// SSE clients ignore event names they do not handle.
public struct PacerAccountChange: Codable, Sendable, Equatable {
    /// The SSE `event:` name.
    public static let eventName = "account"

    public let activeAccountId: String
    public let since: Date

    public init(activeAccountId: String, since: Date) {
        self.activeAccountId = activeAccountId
        self.since = since
    }

    /// Encoded the way every other API payload is (`pacerAPIEncodedJSON`).
    public func encodedJSON() throws -> String { try pacerAPIEncodedJSON(self) }

    /// Posted by `OAuthPoller` on its own executor the moment it makes a
    /// different account active, before anything waits on the main actor
    /// (#254). The stream used to learn of a switch only through
    /// `UsageScope`, a main-actor value, so the event queued behind every
    /// redraw the switch itself caused: 2.0 s on a real switch, against 0.4 s
    /// for the activation. `object` is the poller, so a test can listen to
    /// its own.
    public static let didActivate = Notification.Name("PacerActiveLoginDidChange")

    public func post(from sender: AnyObject?) {
        NotificationCenter.default.post(name: Self.didActivate, object: sender,
                                        userInfo: [Self.userInfoKey: self])
    }

    public init?(_ notification: Notification) {
        guard let change = notification.userInfo?[Self.userInfoKey] as? PacerAccountChange
        else { return nil }
        self = change
    }

    private static let userInfoKey = "change"

    /// Decides when an observed active-account value is a change worth an
    /// event. The scope mirror is *asserted*, not diffed
    /// (`UsageScope.republishActiveAccount`), so the same id is written again
    /// at every launch and reconcile, and nil means "not known yet" rather
    /// than "logged out". Neither is a change.
    public struct Detector: Sendable, Equatable {
        public private(set) var last: String?

        public init(last: String?) { self.last = last }

        /// The event for `observed`, or nil when nothing changed.
        public mutating func observe(_ observed: String?, since: Date) -> PacerAccountChange? {
            guard let observed, observed != last else { return nil }
            last = observed
            return PacerAccountChange(activeAccountId: observed, since: since)
        }
    }
}

/// Server-Sent Events framing for `/v1/stream`.
public enum PacerSSE {
    /// One event: `event:` line, one `data:` line per physical line of the
    /// payload (the SSE spec joins them back with newlines), blank line.
    public static func frame(event: String, data: String) -> String {
        var frame = "event: \(event)\n"
        for line in data.split(separator: "\n", omittingEmptySubsequences: false) {
            frame += "data: \(line)\n"
        }
        frame += "\n"
        return frame
    }
}
