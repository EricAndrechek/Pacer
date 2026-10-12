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
    /// sleeping in `pace.sh wait`, and pacing it on `accountId` waited out
    /// the old login's reset while the new one had headroom (#184).
    ///
    /// A session that bills an account of its own does not follow the CLI's
    /// switches (#211):
    /// - a Claude Desktop session bills Desktop's login;
    /// - a pinned profile's session bills that profile's login.
    public let currentAccountId: String?
    /// When the default login became `currentAccountId`: the last switch. A
    /// loop can compare it between reads to see a switch happen. Nil for a
    /// session bound to an account of its own, which no CLI switch moves.
    public let currentAccountSince: Date?
    public let projectPath: String?
    /// Last path component of `projectPath`, for display.
    public let project: String?
    public let lastActiveAt: Date?

    public func encodedJSON() throws -> String { try pacerAPIEncodedJSON(self) }

    /// The same answer, stamped at `now`. Served from `PacerAPISnapshot`,
    /// whose age travels in the response header instead.
    func rebased(to now: Date) -> Self {
        Self(schemaVersion: schemaVersion, generatedAt: now, sessionId: sessionId,
             model: model, models: models, accountId: accountId,
             currentAccountId: currentAccountId, currentAccountSince: currentAccountSince,
             projectPath: projectPath, project: project, lastActiveAt: lastActiveAt)
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
/// Telling these apart matters because `pace.sh` gates on `currentAccountId`
/// (#184). Following the CLI's login, a Desktop routine was paced against the
/// CLI's windows.
struct PacerSessionBinding {
    let trail: AccountTrail
    /// `DesktopSessionDirectory.accounts`: recorded session → its account.
    let desktopAccounts: [String: String]

    static func load(context: ModelContext,
                     desktop: DesktopSessionDirectory? = .shared) -> PacerSessionBinding {
        PacerSessionBinding(trail: AccountParallelism.trail(context: context),
                            desktopAccounts: desktop?.accounts ?? [:])
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
    /// `pace.sh wait` asks again when it wakes, and that sleep can last a
    /// whole 5-hour window. An older id falls back to the store.
    public static let snapshotWindow: TimeInterval = 6 * 60 * 60

    /// Every session seen within `snapshotWindow`, answered by the same rule
    /// as `lookup(sessionId:)` (`answer(sessionId:turns:binding:now:)`), from
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
    nonisolated static func live(context: ModelContext, storeURL: URL?,
                                 binding: PacerSessionBinding,
                                 now: Date) -> [String: PacerSessionLookup] {
        let liveSince = now.addingTimeInterval(-snapshotWindow)
        if let storeURL,
           let rows = RawSessionTurnReader.turns(
               storeURL: storeURL, since: liveSince.addingTimeInterval(-concurrencyWindow)) {
            var bySession: [String: [PacerSessionTurn]] = [:]
            for (sessionId, turn) in rows where !sessionId.isEmpty {
                // Newest first already; the same cap the store fetch applies.
                if bySession[sessionId, default: []].count < lookupTurnLimit {
                    bySession[sessionId, default: []].append(turn)
                }
            }
            var out: [String: PacerSessionLookup] = [:]
            for (sessionId, turns) in bySession {
                guard let newest = turns.first, newest.sampledAt >= liveSince,
                      let found = answer(sessionId: sessionId, turns: turns,
                                         binding: binding, now: now) else { continue }
                out[sessionId] = found
            }
            return out
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
            sessions: rows.filter { account == nil || current($0) == account }.map { row in
                PacerSessionList.Row(
                    sessionId: row.sessionId,
                    accountId: row.accountId,
                    currentAccountId: current(row),
                    model: row.topModel.isEmpty ? nil : row.topModel,
                    projectPath: row.projectPath,
                    project: URL(fileURLWithPath: row.projectPath).lastPathComponent,
                    repository: origins[row.projectPath],
                    lastActiveAt: row.lastSeenAt,
                    activity: LiveSessionActivity.from(lastSeen: row.lastSeenAt, now: now).label)
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
        return answer(sessionId: trimmed, turns: turns, binding: binding, now: now)
    }

    /// Enough turns to see a fan-out, not so many that an on-demand API call
    /// walks a long session. A parent and its subagents interleave within
    /// seconds of each other, so the models in flight show up in the newest
    /// handful either way.
    static let lookupTurnLimit = 200

    /// The lookup's rule, over a session's newest turns (newest first, at most
    /// `lookupTurnLimit`). Both the store fetch and the snapshot's raw read
    /// feed it, so the two answers cannot drift apart.
    nonisolated static func answer(sessionId: String, turns: [PacerSessionTurn],
                                   binding: PacerSessionBinding,
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
            lastActiveAt: newest.sampledAt)
    }
}
