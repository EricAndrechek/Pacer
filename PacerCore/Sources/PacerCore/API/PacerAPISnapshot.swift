import Foundation
import SwiftData

/// Everything the HTTP API's read endpoints answer from, built in one pass
/// off the request path.
///
/// **Why it exists (#191).** The server used to build each answer from the
/// store while the request waited, on the one queue every request shared. On
/// 2026-10-07, under heavy memory pressure, store reads took tens of seconds:
/// `/metrics` went from milliseconds to no answer at all, every request queued
/// behind it — `/healthz` included — and every session's `pace.sh` gate failed
/// open, so pacing vanished exactly when the machine was busiest. Answering
/// from a value built in the background means a slow store makes answers
/// *stale*, never *absent*, and how stale is on every answer.
///
/// Built by the same builders the endpoints called directly before, so a
/// cached answer and an on-demand one cannot disagree. Seconds-from-now
/// fields are rebased when served (`payload(account:at:)`, `metrics(...)`),
/// never trusted from build time.
public struct PacerAPISnapshot: Sendable {
    /// When the build started; every relative field inside was computed
    /// against this instant.
    public let builtAt: Date
    /// `/v1/snapshot` with no `?account=`, and the base `/metrics` renders.
    public let unscoped: PacerSnapshotPayload
    /// `/v1/snapshot?account=`, keyed by resolved rollup key: every account
    /// row, the unattributed bucket, and any account a pinned config root
    /// names — so every key `resolve(_:)` can return has a payload.
    public let byAccount: [String: PacerSnapshotPayload]
    /// `/v1/accounts`, and the ids `?account=` resolves against.
    public let accounts: PacerAccountList
    /// Today's per-model rows across every account (`pacer_model_*`).
    public let todayModels: [PacerDailyUsage.Row]
    /// Today's per-model rows for each row of `accounts`, keyed by rollup key
    /// (`AccountDailyAggregate.unattributedKey` for the unattributed row).
    public let todayModelsByAccount: [String: [PacerDailyUsage.Row]]
    /// Each real account's rate-limit windows (`pacer_rate_limit_*`).
    public let limits: [String: PacerSnapshotPayload.Limits]
    /// Open pinned config roots → the account signed into each, for
    /// `?config_dir=`.
    public let configRoots: [String: String]
    /// `/v1/session?id=` for every session seen within
    /// `PacerSessionLookupBuilder.snapshotWindow`, keyed by session id (#211).
    /// `pace.sh` asks this before every gate. Answered from the store, a stall
    /// cost each gate its 5 s timeout and then paced it on the wrong account.
    public let sessions: [String: PacerSessionLookup]

    public init(builtAt: Date, unscoped: PacerSnapshotPayload,
                byAccount: [String: PacerSnapshotPayload],
                accounts: PacerAccountList,
                todayModels: [PacerDailyUsage.Row],
                todayModelsByAccount: [String: [PacerDailyUsage.Row]],
                limits: [String: PacerSnapshotPayload.Limits],
                configRoots: [String: String],
                sessions: [String: PacerSessionLookup] = [:]) {
        self.builtAt = builtAt
        self.unscoped = unscoped
        self.byAccount = byAccount
        self.accounts = accounts
        self.todayModels = todayModels
        self.todayModelsByAccount = todayModelsByAccount
        self.limits = limits
        self.configRoots = configRoots
        self.sessions = sessions
    }

    // MARK: - Build

    /// Read the shared store once and assemble everything. Does every bit of
    /// store work the read endpoints used to do per request; call it from a
    /// background queue, never a request handler or the main actor.
    public nonisolated static func build(now: Date = Date()) throws -> PacerAPISnapshot {
        try build(container: PacerStore.sharedModelContainer(),
                  activeAccountId: UsageScope.storedActiveAccountId, now: now)
    }

    /// Test seam, and the real work: one short-lived context for the whole
    /// pass, created here so it never leaves the calling thread. `desktop` is
    /// what binds Claude Desktop's sessions to Desktop's account.
    nonisolated static func build(container: ModelContainer, activeAccountId: String?,
                                  desktop: DesktopSessionDirectory? = .shared,
                                  now: Date) throws -> PacerAPISnapshot {
        let context = ModelContext(container)
        let accounts = PacerAccountsBuilder.list(context: context, now: now)
        let configRoots = AccountParallelism.trail(context: context).openPinnedRoots

        let unscoped = PacerSnapshotBuilder.build(
            context: context, account: nil, activeAccountId: activeAccountId, now: now)

        // A payload for every key a request can resolve to, so a scoped
        // request never has to fall back to the store. The unattributed
        // bucket is always included: `?account=unattributed` resolves whether
        // or not it has usage, and answered with an empty payload before.
        var keys = Set(accounts.accounts.map(Self.rollupKey))
        keys.insert(AccountDailyAggregate.unattributedKey)
        keys.formUnion(configRoots.values)
        var byAccount: [String: PacerSnapshotPayload] = [:]
        for key in keys {
            byAccount[key] = PacerSnapshotBuilder.build(
                context: context, account: key, activeAccountId: activeAccountId, now: now)
        }

        // An account's windows are exactly its scoped payload's: the same
        // `limits(context:limitAccount:engineScope:now:)` call with the same
        // inputs. Reusing them saves `/metrics` a second read of every
        // account's rate-limit rows.
        var limits: [String: PacerSnapshotPayload.Limits] = [:]
        var todayByAccount: [String: [PacerDailyUsage.Row]] = [:]
        for row in accounts.accounts {
            let key = Self.rollupKey(row)
            todayByAccount[key] = PacerUsageBuilder.todayByModel(
                context: context, account: key, now: now)
            if !row.unattributed, let payload = byAccount[row.id] {
                limits[row.id] = payload.limits
            }
        }

        return PacerAPISnapshot(
            builtAt: now,
            unscoped: unscoped,
            byAccount: byAccount,
            accounts: accounts,
            todayModels: PacerUsageBuilder.todayByModel(context: context, account: nil, now: now),
            todayModelsByAccount: todayByAccount,
            limits: limits,
            configRoots: configRoots,
            sessions: PacerSessionLookupBuilder.live(
                context: context, storeURL: Self.fileURL(of: container),
                binding: .load(context: context, desktop: desktop), now: now))
    }

    /// The store's file, for the raw reads that skip SwiftData; nil for an
    /// in-memory store, which has none.
    static func fileURL(of container: ModelContainer) -> URL? {
        guard let configuration = container.configurations.first,
              !configuration.isStoredInMemoryOnly else { return nil }
        return configuration.url
    }

    /// The per-account rollup key for a list row: its id, except the
    /// unattributed row, whose public id is an alias for an untypeable key.
    static func rollupKey(_ row: PacerAccountList.Row) -> String {
        row.unattributed ? AccountDailyAggregate.unattributedKey : row.id
    }

    // MARK: - Serve

    /// Whole seconds between the build and `now`.
    public func ageSeconds(at now: Date) -> Int {
        PacerSnapshotPayload.seconds(from: builtAt, until: now)
    }

    /// `/v1/snapshot`'s answer at `now`. `account` is a resolved rollup key,
    /// nil for the unscoped payload; nil back means no payload for that key.
    public func payload(account: String?, at now: Date) -> PacerSnapshotPayload? {
        guard let account else { return unscoped.rebased(to: now) }
        return byAccount[account]?.rebased(to: now)
    }

    /// `/v1/session?id=`'s answer at `now`, or nil for a session the snapshot
    /// does not carry: older than its window, or not parsed yet. The caller
    /// asks the store then, as before.
    public func session(id: String, at now: Date) -> PacerSessionLookup? {
        sessions[id.trimmingCharacters(in: .whitespaces)]?.rebased(to: now)
    }

    /// `/v1/accounts`' answer at `now`.
    public func accountList(at now: Date) -> PacerAccountList {
        accounts.rebased(to: now)
    }

    /// `/metrics` at `now`.
    ///
    /// The same composition the endpoint did inline: today per model and per
    /// account for every login, and rate-limit windows for every login — or
    /// only `wanted`'s, which is how a client pinned to one profile asks for
    /// its own without knowing the account id. A scrape passes nil and gets
    /// them all, which is what a time-series database wants.
    public func metrics(account wanted: String?, now: Date,
                        version: String, build: String) -> PacerMetrics {
        let todayAccounts = accounts.accounts.map { row in
            PacerMetrics.AccountToday(account: row,
                                      models: todayModelsByAccount[Self.rollupKey(row)] ?? [])
        }
        // The unattributed bucket is skipped: it is a rollup key for turns
        // that predate the activation trail, not an account with windows.
        let accountLimits = accounts.accounts.compactMap { row -> PacerMetrics.AccountLimits? in
            guard !row.unattributed, wanted == nil || row.id == wanted,
                  let windows = limits[row.id] else { return nil }
            return PacerMetrics.AccountLimits(accountId: row.id, limits: windows.rebased(to: now))
        }
        return PacerMetrics(snapshot: unscoped.rebased(to: now), limits: accountLimits,
                            todayModels: todayModels, todayAccounts: todayAccounts,
                            version: version, build: build,
                            apiDataAgeSeconds: ageSeconds(at: now))
    }

    // MARK: - Resolve `?account=` / `?config_dir=`

    /// Resolve a request's account parameters against this snapshot's account
    /// list and pinned roots, with the semantics the store-backed resolution
    /// has (`PacerAccountQuery.resolveFromStore`), unique prefixes included.
    public func resolve(_ query: [String: String]) -> PacerAccountQuery {
        PacerAccountQuery.resolve(query,
                                  account: { try resolve(account: $0) },
                                  configDir: { resolve(configDir: $0) })
    }

    func resolve(account raw: String) throws -> String {
        try PacerAccountsBuilder.resolve(parameter: raw, known: knownAccountIds)
    }

    func resolve(configDir raw: String) -> String? {
        PacerAccountsBuilder.resolve(configDir: raw, roots: configRoots)
    }

    /// What `PacerAccountsBuilder.knownAccountIds()` reads from the store:
    /// every `Account` row's id, sorted — which is every list row but the
    /// unattributed one.
    var knownAccountIds: [String] {
        accounts.accounts.filter { !$0.unattributed }.map(\.id).sorted()
    }
}

/// What a request's `?account=` / `?config_dir=` resolved to.
///
/// Absent means unscoped — the default, because a consumer that did not ask
/// to be scoped must not be. For the usage endpoints that is every account;
/// for `/v1/snapshot` it is every account's cost and tokens with the active
/// login's limits, which is what that payload has always meant. An id that
/// does not exist is a 400 naming the legal values rather than an empty 200,
/// which would look exactly like an account that simply had a quiet month.
public enum PacerAccountQuery: Sendable, Equatable {
    case all
    case scoped(String)
    /// Carries the response body for the 400.
    case rejected(String)

    /// The decision, independent of where the account list comes from.
    ///
    /// `?config_dir=` is the parallel-accounts case: a Claude Code session
    /// pinned to its own profile knows the directory it was handed and
    /// nothing else, and only Pacer knows whose login is in it. Resolving it
    /// is what stops such a session pacing against the *default* login's
    /// windows, which are a different account's entirely.
    ///
    /// A root Pacer has never seen a login in falls through to unscoped
    /// rather than erroring: a brand-new profile is a real state, and the
    /// active login is the right answer until something is observed in it.
    public static func resolve(_ query: [String: String],
                               account resolveAccount: (String) throws -> String,
                               configDir resolveConfigDir: (String) throws -> String?)
        -> PacerAccountQuery {
        if let dir = query["config_dir"], !dir.isEmpty {
            if let resolved = (try? resolveConfigDir(dir)) ?? nil {
                return .scoped(resolved)
            }
            if query["account"] == nil { return .all }
        }
        guard let raw = query["account"], !raw.isEmpty else { return .all }
        do {
            return .scoped(try resolveAccount(raw))
        } catch let PacerAccountsBuilder.ResolveError.unknownAccount(known) {
            return .rejected("Unknown account \"\(raw)\". Known: \(known.joined(separator: ", "))\n")
        } catch {
            return .rejected("Could not read accounts\n")
        }
    }

    /// Against the store: what an endpoint falls back to before the first
    /// snapshot exists.
    public static func resolveFromStore(_ query: [String: String]) -> PacerAccountQuery {
        resolve(query,
                account: { try PacerAccountsBuilder.resolve($0) },
                configDir: { try PacerAccountsBuilder.resolve(configDir: $0) })
    }
}

/// The latest `PacerAPISnapshot`, shared between the thread that builds it and
/// every request that reads it.
///
/// A lock, not an actor: a request handler is a plain GCD block that must not
/// suspend or hop, and a read here is a pointer copy under a lock held for
/// nanoseconds. Never holds the lock across a build — `store` takes a value
/// that was finished elsewhere, so a build stuck on a slow store cannot hold
/// up a single read.
public final class PacerAPISnapshotCache: @unchecked Sendable {
    private let condition = NSCondition()
    private var snapshot: PacerAPISnapshot?

    public init() {}

    /// The newest snapshot, or nil before the first build lands.
    public var current: PacerAPISnapshot? {
        condition.lock()
        defer { condition.unlock() }
        return snapshot
    }

    /// Swap in a finished snapshot and wake anything waiting for the first.
    public func store(_ new: PacerAPISnapshot) {
        condition.lock()
        snapshot = new
        condition.broadcast()
        condition.unlock()
    }

    /// Forget the snapshot — the API was switched off, and one kept until it
    /// is switched back on could be hours old.
    public func clear() {
        condition.lock()
        snapshot = nil
        condition.unlock()
    }

    /// The current snapshot, waiting up to `timeout` for the first one when
    /// there is none yet. Blocks the calling thread: only for a request
    /// worker on a cold start, never the listener's queue.
    public func current(waitingUpTo timeout: TimeInterval) -> PacerAPISnapshot? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while snapshot == nil {
            if !condition.wait(until: deadline) { break }
        }
        return snapshot
    }
}
