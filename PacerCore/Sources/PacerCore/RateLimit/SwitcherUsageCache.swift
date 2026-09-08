import Foundation

/// Reads the usage an account switcher has *already fetched*, instead of
/// fetching it again.
///
/// **Why this exists.** Anthropic budgets the usage endpoint per token, and
/// `cswap` polls the same tokens Pacer does. Both were asking about the
/// signed-in account within seconds of each other and both were getting 429s —
/// visible from two sides: Pacer's log showed `rate-limited (429) — lane
/// cooling` on that one lane while five Claude Desktop lanes for the *other*
/// account, polled every fifty seconds, never failed once; and cswap's own
/// cache recorded `lastError: http-429` for the same account at the same time.
/// The account the user was actually signed into went twenty-six minutes
/// without a reading while the one they were not showed up every minute.
///
/// Two clients competing for one token's budget cannot be fixed by polling
/// harder or backing off politely — one of them has to stop asking. Pacer is
/// the one that can, because the answer is already on disk: cswap writes what
/// it fetched, for every account it manages, including the one that is not
/// signed in. Measured at the time of writing: cswap's copy for the starved
/// account was 30 seconds old against Pacer's 26 minutes.
///
/// This is the same bargain Pacer already takes with `sequence.json` for slot
/// order and aliases — read what the switcher knows rather than rediscover it.
///
/// **It is a supplement, never a replacement.** Pacer keeps its own polling:
/// the file is absent for anyone not running cswap, it can be stale or
/// truncated, and its shape is somebody else's to change. Every read is
/// tolerant, and a sample from here is only recorded when it is *newer* than
/// what Pacer already has for that account.
public enum SwitcherUsageCache {

    /// One account's most recent successful fetch.
    public struct Reading: Sendable, Equatable {
        public let organizationId: String
        public let fetchedAt: Date
        /// When cswap intends to poll this account next, and how often it
        /// polls. Published in the same file, which is what lets Pacer aim for
        /// the *gap* between cswap's requests instead of standing down and
        /// inheriting its cadence.
        public let nextPollAt: Date?
        public let pollInterval: TimeInterval?
        public let fiveHour: Window?
        public let sevenDay: Window?
        public let scoped: [ScopedWindow]

        /// The moment halfway between cswap's last poll and its next one.
        ///
        /// Polling there doubles how often the account is read — cswap's
        /// request and Pacer's alternate — while leaving the most possible room
        /// on either side of each, which is what keeps both under the token's
        /// budget. Nil when cswap has not published a schedule.
        public var interleavedPollAt: Date? {
            guard let nextPollAt, let pollInterval, pollInterval > 0 else { return nil }
            return nextPollAt.addingTimeInterval(-pollInterval / 2)
        }
    }

    public struct Window: Sendable, Equatable {
        public let percent: Double
        public let resetsAt: Date?
    }

    public struct ScopedWindow: Sendable, Equatable {
        public let name: String
        public let percent: Double
        public let resetsAt: Date?
    }

    /// `~/.claude-swap-backup/cache/usage.json`, unless overridden for tests.
    public static func defaultURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent(".claude-swap-backup")
            .appendingPathComponent("cache")
            .appendingPathComponent("usage.json")
    }

    /// Every account the switcher has a successful reading for.
    ///
    /// Returns `[]` for anything unexpected — absent file, unreadable JSON, a
    /// schema that has moved on. This is a bonus source; it must never be able
    /// to take Pacer down with it.
    public static func readings(at url: URL) -> [Reading] {
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let accounts = root["accounts"] as? [String: Any]
        else { return [] }

        var out: [Reading] = []
        for (_, raw) in accounts {
            guard let account = raw as? [String: Any],
                  let org = account["organizationUuid"] as? String, !org.isEmpty,
                  // `fetchedAt` is when the *successful* fetch happened, which
                  // is the timestamp the sample belongs at — not `lastAttemptAt`,
                  // which moves on a 429 that produced nothing.
                  let fetchedAt = account["fetchedAt"] as? Double, fetchedAt > 0,
                  let good = account["lastGood"] as? [String: Any]
            else { continue }
            let nextPoll = (account["nextPollAt"] as? Double).flatMap {
                $0 > 0 ? Date(timeIntervalSince1970: $0) : nil
            }
            let interval = (account["pollIntervalS"] as? Double).flatMap { $0 > 0 ? $0 : nil }
            out.append(Reading(
                organizationId: org,
                fetchedAt: Date(timeIntervalSince1970: fetchedAt),
                nextPollAt: nextPoll,
                pollInterval: interval,
                fiveHour: window(good["five_hour"]),
                sevenDay: window(good["seven_day"]),
                scoped: (good["scoped"] as? [[String: Any]] ?? []).compactMap(scopedWindow)))
        }
        return out.sorted { $0.organizationId < $1.organizationId }
    }

    private static func window(_ raw: Any?) -> Window? {
        guard let dict = raw as? [String: Any],
              let pct = dict["pct"] as? Double
        else { return nil }
        return Window(percent: pct, resetsAt: date(dict["resets_at"]))
    }

    private static func scopedWindow(_ dict: [String: Any]) -> ScopedWindow? {
        guard let name = dict["name"] as? String, !name.isEmpty,
              let pct = dict["pct"] as? Double
        else { return nil }
        return ScopedWindow(name: name, percent: pct, resetsAt: date(dict["resets_at"]))
    }

    /// ISO-8601 with fractional seconds, which is what the switcher writes
    /// (`2026-09-09T05:00:00.108134+00:00`). Tried without fractions too,
    /// because a format nobody here controls should not be assumed.
    private static func date(_ raw: Any?) -> Date? {
        guard let text = raw as? String, !text.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: text) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}
