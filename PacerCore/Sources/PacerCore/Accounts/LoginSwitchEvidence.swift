import Foundation

/// Which default-login changes the running Claude Code sessions followed (#357).
///
/// **The gap.** A login change does not move every session. When an account
/// switcher swaps the login, sessions already running pick up the new
/// credential within about thirty seconds. When someone runs `/login` inside
/// one session, the *other* running sessions keep the token they hold and go
/// on billing the old account, sometimes for hours. The attribution trail
/// records only that the login moved, so Pacer stamped those sessions' turns
/// with the new login and gated them on its windows. Observed: an hour of
/// `GO, 2%` while the old account went from 66% to 87% of its 5-hour window.
///
/// Nothing in a transcript names the account a turn billed, and a token held
/// in another process's memory is not observable. What is observable is
/// whether a switcher *made* a change: it keeps its own record of every
/// switch. A change it explains is one the sessions followed; any other
/// change (a `/login`, a `/logout` and back, a tool Pacer does not know) is
/// one the sessions that were already running may not have followed.
///
/// Checked against the maintainer's machine, 2026-10-10 to 2026-11-05: of 110
/// default-login changes in the trail, a claude-swap switch explains 109. The
/// one it does not is the `/login` that #357 reports, and a session running
/// across it would have been in doubt for exactly the hour until the switch
/// away and back that moved the sessions, and at no other time.
///
/// **Enrichment only, like `ExternalAccountDirectory`.** No switcher means no
/// evidence, and every change counts as one sessions may not have followed:
/// the cautious reading, and the right one for someone who only ever uses
/// `/login`. The evidence never moves usage between accounts; it only decides
/// whether a gate may trust that a running session followed the login.
public struct LoginSwitchEvidence: Sendable, Equatable {
    /// One switch a switcher made: the login became `accountId` at `at`.
    public struct Switch: Sendable, Equatable {
        public let at: Date
        public let accountId: String

        public init(at: Date, accountId: String) {
            self.at = at
            self.accountId = accountId
        }
    }

    public let switches: [Switch]

    /// Whether a switcher is installed at all, as opposed to one whose log
    /// this could not read. A switcher that is there but yields no switches
    /// is the broken-parse case #382 counts; no switcher is the ordinary
    /// `/login`-only machine, where every change is rightly unexplained.
    public let switcherPresent: Bool

    public init(switches: [Switch], switcherPresent: Bool? = nil) {
        self.switches = switches
        self.switcherPresent = switcherPresent ?? !switches.isEmpty
    }

    public static let none = LoginSwitchEvidence(switches: [])

    /// How far the switcher's record may sit outside the span it explains.
    /// Pacer usually accepts a switch within a second of the switcher logging
    /// it, but a credential check can hold the change back, or backdate it,
    /// by a few minutes.
    public static let tolerance: TimeInterval = 180

    /// Whether a switcher explains `change`: it switched to `change.to` while
    /// `change.from` was the login, or within `tolerance` of either end. Pacer
    /// can be told of a switch late (busy, or relaunching); a switch to that
    /// account during the old span is still the switch the trail recorded.
    public func explains(_ change: AccountTrail.LoginChange) -> Bool {
        let earliest = change.fromSince.addingTimeInterval(-Self.tolerance)
        let latest = change.at.addingTimeInterval(Self.tolerance)
        return switches.contains { $0.accountId == change.to && $0.at >= earliest && $0.at <= latest }
    }

    /// Whether a switcher switched to `span`'s account when it began: a short
    /// span that is a switch away and back, not a refuted stale write. The
    /// round trip is how someone moves every session onto a login renewed by
    /// `/login`, so leaving it out would keep them in doubt after it.
    public func made(_ span: AccountTrail.Span) -> Bool {
        switches.contains { $0.accountId == span.accountId && abs($0.at.timeIntervalSince(span.startedAt)) <= Self.tolerance }
    }

    /// The default login's changes in `trail`, newest first, each with
    /// whether a switcher explains it.
    public func changes(in trail: AccountTrail) -> [(change: AccountTrail.LoginChange, followed: Bool)] {
        trail.defaultLoginChanges(keepingShort: made).reversed().map { ($0, explains($0)) }
    }
}

// MARK: - claude-swap

extension LoginSwitchEvidence {

    /// The folders claude-swap keeps its roster and log in: the macOS location
    /// and the XDG one, as `ExternalAccountDirectory` reads.
    static func claudeSwapDirectories(homeDirectory: URL) -> [URL] {
        [
            homeDirectory.appendingPathComponent(".claude-swap-backup"),
            homeDirectory.appendingPathComponent(".local/share/claude-swap"),
        ]
    }

    /// How much of the end of the log is read: about ten days of a busy
    /// machine's. Only changes within `PacerSessionBinding.loginChangeHorizon`
    /// are ever asked about.
    static let logTailBytes = 128 * 1024

    /// The switches in claude-swap's roster (`sequence.json`) and log.
    ///
    /// The log is the record: a `Switched from account N to M` line for every
    /// switch, local time to the millisecond, written as the switch lands.
    /// The roster maps a slot number to its org id. Its `activeAccountNumber`
    /// and `lastUpdated` are used only when the log has no switch lines at
    /// all (a format this does not know, or no log): `lastUpdated` moves for
    /// more than switches, so on its own it could explain a `/login` that
    /// happened to land near some other write.
    ///
    /// Slots are mapped with today's roster. A slot renumbered since a logged
    /// switch maps it to the wrong account, which can only make a change look
    /// unexplained: the cautious direction.
    static func parse(sequence: Data?, logTail: String?,
                      timeZone: TimeZone = .current) -> LoginSwitchEvidence {
        guard let sequence,
              let root = (try? JSONSerialization.jsonObject(with: sequence)) as? [String: Any],
              let accounts = root["accounts"] as? [String: Any] else {
            // A roster that is there but unreadable is a switcher this cannot
            // parse, which the audit (#382) must see; no roster is no switcher.
            return LoginSwitchEvidence(switches: [], switcherPresent: sequence != nil)
        }
        var slots: [Int: String] = [:]
        for (slot, raw) in accounts {
            guard let number = Int(slot), let fields = raw as? [String: Any],
                  let org = fields["organizationUuid"] as? String, !org.isEmpty else { continue }
            slots[number] = org
        }

        var switches: [Switch] = []
        if let logTail {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss,SSS"
            let marker = " - INFO - Switched from account "
            for line in logTail.split(separator: "\n") {
                guard let range = line.range(of: marker) else { continue }
                // "<from> to <to>", possibly followed by more words.
                let rest = line[range.upperBound...].split(separator: " ")
                guard rest.count >= 3, rest[1] == "to", let to = Int(rest[2]), let org = slots[to],
                      let at = formatter.date(from: String(line[..<range.lowerBound])) else { continue }
                switches.append(Switch(at: at, accountId: org))
            }
        }
        if switches.isEmpty, let active = root["activeAccountNumber"] as? Int, let org = slots[active],
           let stamp = root["lastUpdated"] as? String,
           let at = ISO8601DateFormatter().date(from: stamp) {
            switches.append(Switch(at: at, accountId: org))
        }
        return LoginSwitchEvidence(switches: switches, switcherPresent: true)
    }

    /// The end of `url`, at most `bytes` of it, cut to whole lines.
    static func tail(of url: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd() else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        return text
    }
}

/// Reads `LoginSwitchEvidence` and keeps it until the switcher's files change.
///
/// The API snapshot loads a session binding every few seconds; this costs it
/// two `stat`s unless claude-swap has written since the last look (its log
/// gains a usage line every five to ten minutes).
public final class LoginSwitchEvidenceReader: @unchecked Sendable {
    /// The process's reader, over the user's home. In a test process it reads
    /// nothing: the machine's real switcher must not decide a test.
    public static let shared = LoginSwitchEvidenceReader(
        homeDirectory: PacerPreferences.isTestProcess ? nil : FileManager.default.homeDirectoryForCurrentUser)

    private let homeDirectory: URL?
    private let lock = NSLock()
    private var signature: [String] = []
    private var cached = LoginSwitchEvidence.none

    public init(homeDirectory: URL?) {
        self.homeDirectory = homeDirectory
    }

    public func current() -> LoginSwitchEvidence {
        guard let homeDirectory else { return .none }
        let fm = FileManager.default
        guard let dir = LoginSwitchEvidence.claudeSwapDirectories(homeDirectory: homeDirectory)
            .first(where: { fm.fileExists(atPath: $0.appendingPathComponent("sequence.json").path) })
        else { return .none }
        let sequence = dir.appendingPathComponent("sequence.json")
        let log = dir.appendingPathComponent("claude-swap.log")
        func stamp(_ url: URL) -> String {
            var info = stat()
            guard stat(url.path, &info) == 0 else { return "-" }
            return "\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
        }
        let now = [dir.path, stamp(sequence), stamp(log)]
        return lock.withLock {
            if now == signature { return cached }
            cached = LoginSwitchEvidence.parse(
                sequence: fm.contents(atPath: sequence.path),
                logTail: LoginSwitchEvidence.tail(of: log, bytes: LoginSwitchEvidence.logTailBytes))
            signature = now
            return cached
        }
    }
}

// MARK: - Audit (#382)

/// Counts the default-login changes a switcher's log explains and the ones it
/// does not, so a log whose format or timezone handling changed shows up.
///
/// **Why.** Every rotation then looks unexplained, and sessions are judged on
/// the old, often nearly full, account and pause for nothing after each
/// switch. Replayed over a month, 109 of 110 changes were explained and the
/// one left was a real `/login`, so the healthy rate is near zero and a few a
/// day means the parse broke.
///
/// Each change is counted once: judged entries are kept in a file in the App
/// Group container, which also lets `pacer report` say so without asking the
/// app anything, and stops a relaunch counting them again. Entries carry a
/// time and a verdict, never an account.
public final class LoginChangeAudit: @unchecked Sendable {
    public struct Entry: Sendable, Equatable {
        public let at: Date
        public let explained: Bool
        public init(at: Date, explained: Bool) {
            self.at = at
            self.explained = explained
        }
    }

    /// The process's audit. Inert in a test process, like the marker.
    public static let shared = LoginChangeAudit(url: LaunchMode.isNormalLaunch ? fileURL() : nil)

    public static let fileName = "login-changes.json"

    /// For the command line as well as the app.
    public static func fileURL() -> URL? {
        guard !PacerPreferences.isTestProcess else { return nil }
        return try? PacerStore.sharedContainerURL().appendingPathComponent(fileName)
    }

    /// How far back a change is judged, and how long `pacer report` looks.
    public static let window: TimeInterval = 24 * 3600

    /// A change is judged only once it is this old. Pacer can see the login
    /// move before the switcher's log line is readable, and judging at once
    /// would call that race a parse failure.
    public static let grace: TimeInterval = 120

    /// `pacer report` says something from this many unexplained changes.
    public static let noteThreshold = 2

    private let url: URL?
    private let add: @Sendable (String, Int) -> Void
    private let lock = NSLock()
    private var entries: [Entry]?

    /// `url` nil keeps the tally in memory only.
    public init(url: URL?, add: @escaping @Sendable (String, Int) -> Void = { TelemetryCounters.add($0, $1) }) {
        self.url = url
        self.add = add
    }

    /// Judge the changes in `changes` (newest first, as `LoginSwitchEvidence.changes`
    /// returns them) that are new since the last call. Counts each once, logs
    /// each unexplained one, and returns how many unexplained there were in
    /// the last day. Nothing is judged when no switcher is present: there is
    /// no log to disagree with.
    @discardableResult
    public func observe(_ changes: [(change: AccountTrail.LoginChange, followed: Bool)],
                        switcherPresent: Bool, now: Date) -> Int {
        guard switcherPresent else { return 0 }
        var fresh: [Entry] = []
        let unexplainedToday: Int = lock.withLock {
            var known = entries ?? Self.read(from: url)
            let seen = Set(known.map { Self.key($0.at) })
            for (change, followed) in changes {
                guard change.at > now.addingTimeInterval(-Self.window),
                      change.at <= now.addingTimeInterval(-Self.grace),
                      !seen.contains(Self.key(change.at)) else { continue }
                fresh.append(Entry(at: change.at, explained: followed))
            }
            let before = known.count
            known.append(contentsOf: fresh)
            known = known.filter { $0.at > now.addingTimeInterval(-2 * Self.window) }
            entries = known
            if known.count != before || !fresh.isEmpty { Self.write(known, to: url) }
            return Self.unexplained(in: known, now: now)
        }
        let explained = fresh.filter(\.explained).count
        if explained > 0 { add("accounts.login_change.explained", explained) }
        if fresh.count > explained { add("accounts.login_change.unexplained", fresh.count - explained) }
        for _ in 0..<(fresh.count - explained) {
            Log.write("LoginSwitch", "unexplained default-login change; \(unexplainedToday) today")
        }
        return unexplainedToday
    }

    /// Unexplained changes in the last day.
    public static func unexplained(in entries: [Entry], now: Date) -> Int {
        entries.filter { !$0.explained && $0.at > now.addingTimeInterval(-window) && $0.at <= now }.count
    }

    /// The one line `pacer report` adds, or nil below the threshold.
    public static func reportNote(unexplained count: Int) -> String? {
        count >= noteThreshold
            ? "note: \(count) login changes today had no switch behind them — check the switcher's log"
            : nil
    }

    private static func key(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    nonisolated(unsafe) private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// The file's entries; empty for a missing or unreadable one.
    public static func read(from url: URL?) -> [Entry] {
        guard let url, let data = FileManager.default.contents(atPath: url.path),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["changes"] as? [[String: Any]] else { return [] }
        return list.compactMap {
            guard let text = $0["at"] as? String, let at = stamp.date(from: text),
                  let explained = $0["explained"] as? Bool else { return nil }
            return Entry(at: at, explained: explained)
        }
    }

    private static func write(_ entries: [Entry], to url: URL?) {
        guard let url else { return }
        let list = entries.map { "{\"at\": \"\(stamp.string(from: $0.at))\", \"explained\": \($0.explained)}" }
        let body = "{\"version\": 1, \"changes\": [\(list.joined(separator: ", "))]}\n"
        let tmp = url.appendingPathExtension("tmp.\(ProcessInfo.processInfo.processIdentifier)")
        guard (try? Data(body.utf8).write(to: tmp)) != nil else { return }
        // rename(2): a reader sees the old file or the new one, never half.
        if rename(tmp.path, url.path) != 0 { try? FileManager.default.removeItem(at: tmp) }
    }
}
