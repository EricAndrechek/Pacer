import Foundation

/// Which account the default login is, in a file the `pacer` command line can
/// read without asking Pacer anything (#343).
///
/// **Why a file.** `pacer status` is a file read that hundreds of subagents
/// call, and a verdict it serves was gated for one account. After a login
/// switch that verdict describes an account nobody is billing any more, and
/// for up to the verdict's shelf life (15 minutes) `status` kept serving it:
/// "GO" for an account at 7%, while the one now signed in sat at 95%. Asking
/// Pacer which account a caller is on would cost every `status` a round trip
/// (and, with the local API off, opening the store), which is exactly what
/// `status` exists not to do. So the app writes the answer down as it changes,
/// and a reader compares one small file against the account its verdict
/// recorded.
///
/// **What it says.** The attribution trail's default login: the same thing
/// `/v1/session` answers for a session on the default login and the same
/// thing the trail stamps turns with. Not `oauthAccount` in Claude Code's
/// config, which any process can write back stale (#149), and not the
/// poller's active account, which a pick in Settings can move without the
/// login moving.
///
/// **Who writes it.** Only the user's own app (`LaunchMode.isNormalLaunch`),
/// after the trail is saved, so a reader that sees a new account here finds
/// the same account in the store. A diagnostic run against a frozen copy of
/// `~/.claude`, or a test, must not tell the live command line the login moved.
public struct DefaultLoginMarker: Sendable, Equatable {
    /// The default login's account (`Account.id`).
    public let accountId: String
    /// When it became the default login: the trail span's start.
    public let since: Date
    /// When this process first wrote this account here. A reader uses it to
    /// tell "the login moved a moment ago and the API snapshot has not caught
    /// up" from a lasting disagreement, which waiting will not fix.
    public let changedAt: Date

    public init(accountId: String, since: Date, changedAt: Date) {
        self.accountId = accountId
        self.since = since
        self.changedAt = changedAt
    }

    public static let fileName = "default-login.json"

    /// The marker's place in the App Group container, for any process that
    /// can open the container (the app, the command line). Nil in a test
    /// process, which has no business reading the machine's real login.
    public static func fileURL() -> URL? {
        guard !PacerPreferences.isTestProcess else { return nil }
        return try? PacerStore.sharedContainerURL().appendingPathComponent(fileName)
    }

    /// Where the app writes it: the same file, for the user's own app only.
    public static func publishURL() -> URL? {
        LaunchMode.isNormalLaunch ? fileURL() : nil
    }

    nonisolated(unsafe) private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// One small JSON object. Ids are UUIDs and the stamps are ISO 8601, so
    /// nothing here needs escaping.
    public func encoded() -> Data {
        Data("""
        {"version": 1, "account": "\(accountId)", "since": "\(Self.stamp.string(from: since))", \
        "changedAt": "\(Self.stamp.string(from: changedAt))"}

        """.utf8)
    }

    /// The marker in `data`, or nil for anything else: a missing field, a
    /// file caught mid-write, a format this reader does not know.
    public static func decode(_ data: Data) -> DefaultLoginMarker? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let account = object["account"] as? String, !account.isEmpty,
              let sinceText = object["since"] as? String, let since = stamp.date(from: sinceText),
              let changedText = object["changedAt"] as? String, let changed = stamp.date(from: changedText)
        else { return nil }
        return DefaultLoginMarker(accountId: account, since: since, changedAt: changed)
    }

    public static func read(from url: URL?) -> DefaultLoginMarker? {
        guard let url, let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return decode(data)
    }
}

/// Writes `DefaultLoginMarker` when the default login changes.
///
/// Asserted, not diffed, at the first call of a process: a file left by an
/// earlier run, or edited, or written by a build that crashed before it could
/// update it, is replaced with what the trail says now. After that it writes
/// only when the account or its start moves, so a scan cycle costs a
/// comparison and nothing else.
public final class DefaultLoginMarkerPublisher: @unchecked Sendable {
    private let url: URL?
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var last: (accountId: String, since: Date)?
    private var lastChangedAt: Date?

    /// `url` nil writes nothing: tests, diagnostic launches.
    public init(url: URL? = DefaultLoginMarker.publishURL(), now: @escaping @Sendable () -> Date = Date.init) {
        self.url = url
        self.now = now
    }

    /// Record the default login. Nil (no open span, an empty trail) leaves the
    /// file as it is: "can't tell" never overwrites a known login.
    public func publish(_ login: AccountTrail.Span?) {
        guard let url, let login else { return }
        let marker: DefaultLoginMarker? = lock.withLock {
            if let last, last.accountId == login.accountId, last.since == login.startedAt { return nil }
            if last == nil, let onDisk = DefaultLoginMarker.read(from: url),
               onDisk.accountId == login.accountId {
                // A relaunch on the same login is not a login change.
                lastChangedAt = onDisk.changedAt
                if onDisk.since == login.startedAt {
                    last = (login.accountId, login.startedAt)
                    return nil
                }
            }
            // A start that moved with the account unchanged (a credential
            // correction backdating the span) is not a new login either:
            // keep when the account itself first appeared.
            let changedAt = (last == nil || last?.accountId == login.accountId ? lastChangedAt : nil) ?? now()
            last = (login.accountId, login.startedAt)
            lastChangedAt = changedAt
            return DefaultLoginMarker(accountId: login.accountId, since: login.startedAt, changedAt: changedAt)
        }
        guard let marker else { return }
        let tmp = url.appendingPathExtension("tmp.\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try marker.encoded().write(to: tmp)
            // rename(2): a reader sees the old marker or the new one, never half.
            if rename(tmp.path, url.path) != 0 {
                try? FileManager.default.removeItem(at: tmp)
                lock.withLock { last = nil }
            }
        } catch {
            lock.withLock { last = nil }
        }
    }
}
