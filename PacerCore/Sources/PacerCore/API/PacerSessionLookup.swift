import Foundation
import SwiftData

/// What Pacer knows about one Claude Code session, keyed by the session id.
///
/// This exists so a script running *inside* a session can stop being told
/// things about itself. Claude Code puts `CLAUDE_CODE_SESSION_ID` into the
/// environment of every command it runs, and it is the same id that names the
/// transcript Pacer already parses — so a caller can hand it over and get back
/// the two facts it cannot determine on its own:
///
/// - **Which model it is running.** The pacing skill needs it to know whether a
///   per-model cap binds this agent at all, and nothing in the environment
///   says so.
/// - **Which account its work is billed to.** More direct than resolving a
///   config directory: this is the attribution Pacer actually recorded for
///   these turns, not an inference about a profile.
///
/// Both come from the newest recorded turn, so a session Pacer has not seen a
/// turn from yet is "not found" rather than a guess.
///
/// **A session is not one model.** This used to claim a subagent gets its own
/// session id and so gets an answer about itself. It does not. Claude Code
/// writes a subagent's turns to `<session>/subagents/agent-*.jsonl` under the
/// *parent's* session id — checked across every subagent transcript on this
/// machine, 2,156 of them, and all carrying the parent's id. So "the newest
/// turn" is whichever agent wrote last, and a Sonnet builder asking what it
/// runs was told "Fable", its orchestrator's model, and gated on a window
/// that does not bind it.
///
/// Nothing can be inferred to fix that: there is no per-agent model variable
/// in the environment a tool call inherits, and the session id is shared. So
/// `models` reports the set instead, and a caller that finds more than one
/// member knows its own identity is not knowable from here.
public struct PacerSessionLookup: Codable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let sessionId: String
    /// The model on the most recent real turn.
    ///
    /// Only as meaningful as `models` is short — with a fan-out running, this
    /// is whichever agent happened to write last. Prefer `models`.
    public let model: String?
    /// Every model this session has run recently, newest first.
    ///
    /// One member means the answer is unambiguous. More than one means the
    /// session is a parent and its subagents running different models at the
    /// same time, and no caller inside it can tell which one it is.
    public let models: [String]
    /// The account that turn was attributed to.
    public let accountId: String?
    /// The account this session's next turn bills to. See
    /// `PacerSessionBinding.current` for how it is decided.
    ///
    /// For a session on the default login, that login's current account. It
    /// differs from `accountId` after a `/login` switch until the session
    /// writes a turn and Pacer scans it. That can be never for a session
    /// sleeping in `pacer wait`, and pacing it on `accountId` waited out
    /// the old login's reset while the new one had headroom (#184).
    ///
    /// A session that bills an account of its own does not follow the CLI's
    /// switches (#211):
    /// - a Claude Desktop session bills Desktop's login;
    /// - a pinned profile's session bills that profile's login.
    ///
    /// And a session on the default login follows a switcher's switch but
    /// not a `/login` run elsewhere: where it may not have followed, the
    /// login it may still be on is in `mayStillBillAccountIds` (#357).
    public let currentAccountId: String?
    /// When the default login became `currentAccountId`: the last switch. A
    /// loop can compare it between reads to see a switch happen. Nil for a
    /// session bound to an account of its own, which no CLI switch moves.
    public let currentAccountSince: Date?
    public let projectPath: String?
    /// Last path component of `projectPath`, for display.
    public let project: String?
    public let lastActiveAt: Date?
    /// Accounts other than `currentAccountId` this session may still be
    /// billing, newest first (#357); absent when Pacer has no doubt.
    ///
    /// A session follows a login change a switcher makes. It does not follow a
    /// `/login` run in another session: it keeps the token it holds. So a
    /// session on the default login that was already running when the login
    /// moved in a way no switcher explains may still be on the login it had,
    /// and nothing Pacer can see says which. A gate judges it on all of them,
    /// the most constrained deciding. See `LoginSwitchEvidence`.
    public var mayStillBillAccountIds: [String]? = nil
    /// The newest login change behind `mayStillBillAccountIds`.
    public var mayStillBillSince: Date? = nil

    public func encodedJSON() throws -> String { try pacerAPIEncodedJSON(self) }

    /// The same answer, stamped at `now`. Served from `PacerAPISnapshot`,
    /// whose age travels in the response header instead.
    func rebased(to now: Date) -> Self {
        Self(schemaVersion: schemaVersion, generatedAt: now, sessionId: sessionId,
             model: model, models: models, accountId: accountId,
             currentAccountId: currentAccountId, currentAccountSince: currentAccountSince,
             projectPath: projectPath, project: project, lastActiveAt: lastActiveAt,
             mayStillBillAccountIds: mayStillBillAccountIds, mayStillBillSince: mayStillBillSince)
    }
}

/// Which account a session's next turn bills to, read once and shared by every
/// lookup in a pass, so a snapshot build answers all the live sessions from
/// one trail read.
///
/// The CLI's switches move only the sessions on the default login. Two kinds
/// bill an account of their own:
/// - **Claude Desktop's sessions** bill Desktop's login (#244). Desktop
///   records which, per session (`DesktopSessionDirectory`).
/// - **A pinned profile's sessions** (`cswap run`, `CLAUDE_CONFIG_DIR`) bill
///   that profile's login. A turn does not record its root, but it shows: the
///   turn carries an account the default login's trail would not have given it
///   at that instant.
///
/// Telling these apart matters because `pacer` gates on `currentAccountId`
/// (#184). Following the CLI's login, a Desktop routine was paced against the
/// CLI's windows.
struct PacerSessionBinding {
    let trail: AccountTrail
    /// `DesktopSessionDirectory.accounts`: recorded session → its account.
    let desktopAccounts: [String: String]
    /// The switches running sessions followed (#357).
    let switches: LoginSwitchEvidence
    /// The default login's changes, newest first, each with whether a
    /// switcher explains it. Worked out once per binding, not per session.
    let changes: [(change: AccountTrail.LoginChange, followed: Bool)]

    init(trail: AccountTrail, desktopAccounts: [String: String],
         switches: LoginSwitchEvidence = .none) {
        self.trail = trail
        self.desktopAccounts = desktopAccounts
        self.switches = switches
        changes = switches.changes(in: trail)
    }

    static func load(context: ModelContext,
                     desktop: DesktopSessionDirectory? = .shared,
                     switches: LoginSwitchEvidenceReader = .shared) -> PacerSessionBinding {
        PacerSessionBinding(trail: AccountParallelism.trail(context: context),
                            desktopAccounts: desktop?.accounts ?? [:],
                            switches: switches.current())
    }

    /// How far back a login change can leave a session in doubt (#357): the
    /// span of turns a lookup reads, so that a session's start is known for
    /// every change considered. A session older than that was running at
    /// every change inside it.
    static let loginChangeHorizon: TimeInterval = PacerSessionLookupBuilder.snapshotWindow

    /// Whether any default-login change inside the horizon went unexplained:
    /// when none did, no session can be in doubt and nothing more is read.
    func hasUnfollowedChange(now: Date) -> Bool {
        let horizon = now.addingTimeInterval(-Self.loginChangeHorizon)
        return changes.contains { !$0.followed && $0.change.at > horizon && $0.change.at <= now }
    }

    /// The accounts other than `current` a session on the default login may
    /// still be billing, and the newest change behind that, or nil (#357).
    ///
    /// `startedAt` is the session's first turn, nil when it may be older than
    /// the horizon. Walking back from the newest change made after it: a
    /// change a switcher explains is one the session followed, so it holds
    /// that login and nothing older matters; any other change leaves it
    /// possibly on the login before. The session that ran the `/login` is on
    /// the new one, but nothing tells it from the others, so it is in doubt
    /// with them and judged on both.
    func mayStillBill(startedAt: Date?, current: String?,
                      now: Date) -> (accounts: [String], since: Date)? {
        let horizon = now.addingTimeInterval(-Self.loginChangeHorizon)
        var others: [String] = []
        var since: Date?
        for (change, followed) in changes where change.at <= now {
            if change.at <= horizon { break }
            if let startedAt, change.at <= startedAt { break }
            if followed { break }
            since = since ?? change.at
            if change.from != current, !others.contains(change.from) { others.append(change.from) }
        }
        guard let since, !others.isEmpty else { return nil }
        return (others, since)
    }

    /// The account `sessionId`'s next turn bills to, and since when the
    /// default login has been on it (nil for a session bound to its own
    /// account), given the account and time of its newest turn.
    ///
    /// The pinned-profile test is inferential and has one blind spot: a
    /// profile signed into the same account the default login held at that
    /// instant looks like the default login, and follows a later CLI switch
    /// until its next turn shows otherwise.
    func current(sessionId: String, newestAccount: String?,
                 newestAt: Date) -> (accountId: String?, since: Date?) {
        if let desktop = desktopAccounts[sessionId] { return (desktop, nil) }
        if let newestAccount, trail.accountId(at: newestAt) != newestAccount {
            return (newestAccount, nil)
        }
        let login = trail.currentDefaultLogin
        return (login?.accountId ?? newestAccount, login?.startedAt)
    }
}

/// The columns a session lookup reads from one turn. The store fetch and the
/// snapshot's raw read (`RawSessionTurnReader`) both produce these, so the
/// rule over them is written once.
struct PacerSessionTurn: Sendable, Equatable {
    let sampledAt: Date
    let model: String
    let accountId: String?
    let projectPath: String?
}

/// Who else is spending this account's budget right now.
///
/// A rate-limit window is **account-wide**: every session signed into that
/// account draws from the same percentage. So a burn rate already includes
/// everyone — but an agent deciding whether to fan out needs to know how much
/// of that rate is its own, and a human wants to know where the rest is coming
/// from before killing something.
///
/// Deliberately *not* carrying a git branch. A branch is the most volatile
/// thing about a checkout — it changes without producing a turn for Pacer to
/// observe — so a stored one would be wrong more often than right. The path is
/// stable and identifies a worktree uniquely; a caller that wants the branch
/// can read it from that path at the moment it asks, which is the only time
/// the answer is true.
public struct PacerSessionList: Codable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let sessions: [Row]

    public struct Row: Codable, Sendable {
        public let sessionId: String
        /// The account its last turn was stamped with.
        public let accountId: String?
        /// For an active session, the login it bills to now (see
        /// `PacerSessionLookup.currentAccountId`); otherwise `accountId`.
        public let currentAccountId: String?
        public let model: String?
        public let projectPath: String?
        public let project: String?
        /// The project's git remote origin, when it has one — so two checkouts
        /// of the same repo are recognisable as such.
        public let repository: String?
        public let lastActiveAt: Date
        /// `active` (≤5 min), `recent` (≤1 h) or `idle`, the same thresholds
        /// the dashboard and menu bar use.
        public let activity: String
        /// For an active session, other accounts it may still be billing
        /// (`PacerSessionLookup.mayStillBillAccountIds`, #357).
        public var mayStillBillAccountIds: [String]? = nil
    }

    public func encodedJSON() throws -> String { try pacerAPIEncodedJSON(self) }
}

public enum PacerSessionLookupBuilder {

    /// How far back a turn still counts as "this session is running that
    /// model right now". Long enough to span a subagent that is thinking,
    /// short enough that a model used once an hour ago stops muddying the
    /// answer.
    static let concurrencyWindow: TimeInterval = 15 * 60

    public nonisolated static func lookup(sessionId: String,
                                          now: Date = Date()) throws -> PacerSessionLookup? {
        try lookup(container: PacerStore.sharedModelContainer(),
                   sessionId: sessionId, now: now)
    }

    /// How far back `PacerAPISnapshot` carries sessions for `/v1/session`.
    /// A session gating is active by definition, but one asleep in
    /// `pacer wait` asks again when it wakes, and that sleep can last a
    /// whole 5-hour window. An older id falls back to the store.
    public static let snapshotWindow: TimeInterval = 6 * 60 * 60

    /// Every session seen within `snapshotWindow`, answered by the same rule
    /// as `lookup(sessionId:)` (`answer(sessionId:turns:startedAt:binding:now:)`), from
    /// one read of the window's turns rather than one fetch per session.
    ///
    /// The read is raw SQLite (`RawSessionTurnReader`): through SwiftData it
    /// cost ~260 ms a build on a real store, and the snapshot is rebuilt every
    /// few seconds while anything is happening. When the raw read is not
    /// possible (an in-memory store) or fails, each session is fetched the
    /// ordinary way.
    ///
    /// The window read starts `concurrencyWindow` before `snapshotWindow`, so a
    /// session whose newest turn is at the window's edge still has every turn
    /// its `models` can count. Past that, a session's older turns cannot
    /// change its answer.
    /// Between commits to the store the answers are kept rather than read and
    /// grouped again (`LiveSessionCache`, #337); each is stamped `now`.
    nonisolated static func live(
        context: ModelContext, storeURL: URL?, binding: PacerSessionBinding, now: Date,
        cache: LiveSessionCache = .shared,
        compute: (_ rows: [(sessionId: String, turn: PacerSessionTurn)], _ liveSince: Date,
                  _ binding: PacerSessionBinding, _ now: Date) -> [String: PacerSessionLookup]
            = answers(rows:liveSince:binding:now:)
    ) -> [String: PacerSessionLookup] {
        let liveSince = now.addingTimeInterval(-snapshotWindow)
        if let storeURL,
           let kept = cache.answers(
               storeURL: storeURL, liveSince: liveSince,
               readSince: liveSince.addingTimeInterval(-concurrencyWindow),
               binding: binding,
               compute: { compute($0, liveSince, binding, now) }) {
            return kept.mapValues { $0.rebased(to: now) }
        }

        var descriptor = FetchDescriptor<AccountSessionInfo>(
            predicate: #Predicate { $0.lastSeenAt >= liveSince },
            sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)])
        descriptor.fetchLimit = 200
        var out: [String: PacerSessionLookup] = [:]
        for row in (try? context.fetch(descriptor)) ?? [] where out[row.sessionId] == nil {
            if let found = lookup(context: context, sessionId: row.sessionId,
                                  binding: binding, now: now) {
                out[row.sessionId] = found
            }
        }
        return out
    }

    /// The answer for every session in `rows` (newest first) whose newest
    /// turn is at or after `liveSince`.
    nonisolated static func answers(rows: [(sessionId: String, turn: PacerSessionTurn)],
                                    liveSince: Date, binding: PacerSessionBinding,
                                    now: Date) -> [String: PacerSessionLookup] {
        var bySession: [String: [PacerSessionTurn]] = [:]
        // Each session's oldest turn read, past the cap: when it first wrote.
        var earliest: [String: Date] = [:]
        for (sessionId, turn) in rows where !sessionId.isEmpty {
            // Newest first already; the same cap the store fetch applies.
            if bySession[sessionId, default: []].count < lookupTurnLimit {
                bySession[sessionId, default: []].append(turn)
            }
            earliest[sessionId] = turn.sampledAt
        }
        var out: [String: PacerSessionLookup] = [:]
        for (sessionId, turns) in bySession {
            // The read starts `concurrencyWindow` before `liveSince`; a first
            // turn in that margin may not be the session's first at all.
            let first = earliest[sessionId].flatMap { $0 >= liveSince ? $0 : nil }
            guard let newest = turns.first, newest.sampledAt >= liveSince,
                  let found = answer(sessionId: sessionId, turns: turns, startedAt: first,
                                     binding: binding, now: now) else { continue }
            out[sessionId] = found
        }
        return out
    }

    /// Every session seen within `withinSeconds`, newest first.
    ///
    /// Reads the per-account session table so each row can name the account
    /// whose budget it is drawing from; that table is only written for turns
    /// the activation trail could attribute, which is the same rule the
    /// per-account rollups follow.
    public nonisolated static func list(withinSeconds: TimeInterval = LiveSessionActivity.recentThreshold,
                                        account: String? = nil,
                                        now: Date = Date()) throws -> PacerSessionList {
        try list(container: PacerStore.sharedModelContainer(),
                 withinSeconds: withinSeconds, account: account, now: now)
    }

    nonisolated static func list(container: ModelContainer, withinSeconds: TimeInterval,
                                 account: String?, now: Date,
                                 desktop: DesktopSessionDirectory? = .shared) throws -> PacerSessionList {
        let context = ModelContext(container)
        let cutoff = now.addingTimeInterval(-max(0, withinSeconds))
        var descriptor = FetchDescriptor<AccountSessionInfo>(
            predicate: #Predicate { $0.lastSeenAt >= cutoff },
            sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)])
        descriptor.fetchLimit = 200
        let binding = PacerSessionBinding.load(context: context, desktop: desktop)
        // One row per session, its newest: a session that spans a switch has a
        // row for each login, and listed both (#190).
        var seen = Set<String>()
        let rows = ((try? context.fetch(descriptor)) ?? [])
            .filter { seen.insert($0.sessionId).inserted }
        func current(_ row: AccountSessionInfo) -> String {
            guard LiveSessionActivity.from(lastSeen: row.lastSeenAt, now: now) == .active
            else { return row.accountId }
            return binding.current(sessionId: row.sessionId, newestAccount: row.accountId,
                                   newestAt: row.lastSeenAt).accountId ?? row.accountId
        }
        // When each listed session first wrote, read only when a login change
        // no switcher explains could leave an active one in doubt (#357).
        var firstSeen: [String: Date] = [:]
        let inDoubt = binding.hasUnfollowedChange(now: now)
        if inDoubt {
            let ids = Set(rows.map(\.sessionId))
            var sessions = FetchDescriptor<SessionInfo>(predicate: #Predicate { $0.lastSeenAt >= cutoff })
            sessions.fetchLimit = 400
            for info in (try? context.fetch(sessions)) ?? [] where ids.contains(info.sessionId) {
                firstSeen[info.sessionId] = info.firstSeenAt
            }
        }
        func doubt(_ row: AccountSessionInfo) -> [String]? {
            guard inDoubt,
                  LiveSessionActivity.from(lastSeen: row.lastSeenAt, now: now) == .active else { return nil }
            let bound = binding.current(sessionId: row.sessionId, newestAccount: row.accountId,
                                        newestAt: row.lastSeenAt)
            guard bound.since != nil else { return nil }
            // Older than the horizon reads as "before every change in it", as
            // the session lookup reads it.
            let started = firstSeen[row.sessionId].flatMap {
                $0 >= now.addingTimeInterval(-PacerSessionLookupBuilder.snapshotWindow) ? $0 : nil
            }
            return binding.mayStillBill(startedAt: started, current: bound.accountId, now: now)?.accounts
        }

        // One lookup for every project involved, rather than one per session.
        let paths = Set(rows.map(\.projectPath))
        var origins: [String: String] = [:]
        for meta in (try? context.fetch(FetchDescriptor<ProjectMeta>())) ?? [] where
            paths.contains(meta.projectPath) {
            // `colorSeed` is the git remote *or* a canonical path — it exists to
            // be a stable colour input, not to identify a repo. Reporting the
            // fallback under a field called `repository` would hand a caller a
            // local directory and call it a remote, so only a real remote
            // qualifies: a URL with a scheme, or scp-style `user@host:path`.
            guard let seed = meta.colorSeed, !seed.hasPrefix("/") else { continue }
            let looksRemote = seed.contains("://")
                || (seed.contains("@") && seed.contains(":"))
            if looksRemote { origins[meta.projectPath] = seed }
        }

        return PacerSessionList(
            schemaVersion: 1,
            generatedAt: now,
            // A session that may still be billing `account` is drawing on its
            // budget too, so it is listed under it (#357).
            sessions: rows.filter { row in
                guard let account else { return true }
                return current(row) == account || doubt(row)?.contains(account) == true
            }.map { row in
                PacerSessionList.Row(
                    sessionId: row.sessionId,
                    accountId: row.accountId,
                    currentAccountId: current(row),
                    model: row.topModel.isEmpty ? nil : row.topModel,
                    projectPath: row.projectPath,
                    project: URL(fileURLWithPath: row.projectPath).lastPathComponent,
                    repository: origins[row.projectPath],
                    lastActiveAt: row.lastSeenAt,
                    activity: LiveSessionActivity.from(lastSeen: row.lastSeenAt, now: now).label,
                    mayStillBillAccountIds: doubt(row))
            })
    }

    nonisolated static func lookup(container: ModelContainer, sessionId: String,
                                   now: Date) throws -> PacerSessionLookup? {
        let context = ModelContext(container)
        return lookup(context: context, sessionId: sessionId,
                      binding: .load(context: context), now: now)
    }

    nonisolated static func lookup(context: ModelContext, sessionId: String,
                                   binding: PacerSessionBinding,
                                   now: Date) -> PacerSessionLookup? {
        let trimmed = sessionId.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Newest first, and a handful rather than one: the top row can be a
        // `<synthetic>` turn, Claude Code's sentinel for non-billable internal
        // traffic, which names no real model and is skipped everywhere else in
        // Pacer for exactly this reason.
        var descriptor = FetchDescriptor<TokenSample>(
            predicate: #Predicate { $0.sessionId == trimmed },
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)])
        descriptor.fetchLimit = lookupTurnLimit
        let turns = ((try? context.fetch(descriptor)) ?? []).map {
            PacerSessionTurn(sampledAt: $0.sampledAt, model: $0.model,
                             accountId: $0.accountId, projectPath: $0.projectPath)
        }
        // When it first wrote: the oldest of these unless the fetch was cut
        // off, and then asked for, but only when an unexplained login change
        // could put the session in doubt (#357).
        var startedAt = turns.count < lookupTurnLimit ? turns.last?.sampledAt : nil
        if startedAt == nil, !turns.isEmpty, binding.hasUnfollowedChange(now: now) {
            var first = FetchDescriptor<TokenSample>(
                predicate: #Predicate { $0.sessionId == trimmed },
                sortBy: [SortDescriptor(\.sampledAt)])
            first.fetchLimit = 1
            startedAt = (try? context.fetch(first))?.first?.sampledAt
        }
        // A first turn older than the window the snapshot reads is "older
        // than every change it asks about", as the snapshot says it.
        if let first = startedAt, first < now.addingTimeInterval(-snapshotWindow) { startedAt = nil }
        return answer(sessionId: trimmed, turns: turns, startedAt: startedAt, binding: binding, now: now)
    }

    /// Enough turns to see a fan-out, not so many that an on-demand API call
    /// walks a long session. A parent and its subagents interleave within
    /// seconds of each other, so the models in flight show up in the newest
    /// handful either way.
    static let lookupTurnLimit = 200

    /// The lookup's rule, over a session's newest turns (newest first, at most
    /// `lookupTurnLimit`). Both the store fetch and the snapshot's raw read
    /// feed it, so the two answers cannot drift apart.
    ///
    /// `startedAt` is the session's first turn where the turns read reach it,
    /// nil where it may be older (see `PacerSessionBinding.mayStillBill`).
    nonisolated static func answer(sessionId: String, turns: [PacerSessionTurn],
                                   startedAt: Date?, binding: PacerSessionBinding,
                                   now: Date) -> PacerSessionLookup? {
        guard let newest = turns.first else { return nil }

        // Distinct models on recent turns, newest first. `<synthetic>` is
        // Claude Code's sentinel for non-billable internal traffic, which
        // names no real model and is skipped everywhere else in Pacer.
        let cutoff = newest.sampledAt.addingTimeInterval(-concurrencyWindow)
        var seen = Set<String>()
        var models: [String] = []
        for turn in turns where turn.sampledAt >= cutoff {
            guard turn.model != JSONLLineParser.syntheticModelSentinel,
                  !turn.model.isEmpty else { continue }
            if seen.insert(turn.model).inserted { models.append(turn.model) }
        }
        let path = newest.projectPath
        let current = binding.current(sessionId: sessionId, newestAccount: newest.accountId,
                                      newestAt: newest.sampledAt)
        // Only a session on the default login (one with a `since`) follows,
        // or fails to follow, its changes.
        let doubt = current.since == nil ? nil
            : binding.mayStillBill(startedAt: startedAt, current: current.accountId, now: now)
        return PacerSessionLookup(
            schemaVersion: 1,
            generatedAt: now,
            sessionId: sessionId,
            model: models.first,
            models: models,
            accountId: newest.accountId,
            currentAccountId: current.accountId,
            currentAccountSince: current.since,
            projectPath: path,
            project: path.map { URL(fileURLWithPath: $0).lastPathComponent },
            lastActiveAt: newest.sampledAt,
            mayStillBillAccountIds: doubt?.accounts,
            mayStillBillSince: doubt?.since)
    }
}
