import Foundation
import Observation
import SwiftData

/// What the menu's dropdown (`MenuStatusContent`) draws from the store, read
/// off the main thread and only when something it shows changed (#408).
///
/// The dropdown is hosted in an `NSMenuItem.view` whose controller is kept
/// between openings, so, like the label (PACER-19, `MenuBarLabelFeed`), it is
/// always mounted. It held today's two `@Query`s, which re-fetch on every save
/// of the store on the main thread; it loaded the scope's windows, the account
/// list, the parallelism mode and every grouped account's windows on the main
/// thread after each rate-limit write; and it fetched the account list again
/// on every `body`. The same class of hang as PACER-19, and AGENTS.md's rule
/// for always-mounted surfaces: no `@Query`, no fetch on the main thread.
///
/// Two halves, each with its own trigger, so neither re-reads for the other's
/// writes:
///
/// - **Today** (the Today row, and the spend the Outlook row weighs its range
///   against): the label's usage read (`MenuBarLabelFeed.readUsage`, today's
///   rows only), keyed on the local day, the spend scope and
///   `SampleWriteSignal`.
/// - **Limits** (every block the dropdown lists: whose windows, its name,
///   whether it is the signed-in login, and whether concurrent accounts get a
///   block each): keyed on `RateLimitWriteSignal`, the scope, the active
///   login, the active clients and the menu's openings. The openings are
///   there because the dropdown re-reads on every open (AGENTS.md, "The clock
///   is an input"): the names and the grouping used to be fetched on every
///   `body`, the one each opening runs included.
///
/// Every read runs on its own `ModelContext` in a detached task, one at a time
/// per half (`KeyedReadLane`), and its values are assigned in one main-actor
/// turn; a value equal to the one shown is not assigned, so a re-read that
/// found nothing new redraws nothing. Both halves are nil until their first
/// read lands, so the dropdown can say "—" for "not read yet" rather than
/// "$0.00"; the app reads both when it builds the menu, so the first opening
/// finds them read.
@MainActor
@Observable
public final class MenuDropdownFeed {

    // MARK: - Limits

    /// Everything the limits read depends on but the clients themselves,
    /// which `loadLimits` takes beside it.
    public struct LimitsKey: Hashable, Sendable {
        /// `RateLimitWriteSignal.generation`.
        public var writes: UInt64
        /// `UsageScope.accountId` and `.activeAccountId`, resolved in the read
        /// the way the label resolves them (`resolveLimitAccountId`), with the
        /// store's active row as the cold-start fallback.
        public var scope: String?
        public var active: String?
        /// `AccountClientsMonitor.generation`: moves whenever which clients
        /// are active does, including when a Desktop's 30 minutes run out
        /// with nothing written (#245). It stands in for the clients in the
        /// key, so a view keys on it without reading the clients in `body`,
        /// where they would redraw it on every scan cycle.
        public var clients: Int
        /// How many times the menu has opened: the dropdown re-reads on every
        /// open.
        public var opening: Int

        public init(writes: UInt64, scope: String?, active: String?, clients: Int, opening: Int) {
            self.writes = writes
            self.scope = scope
            self.active = active
            self.clients = clients
            self.opening = opening
        }
    }

    /// The accounts with an active client, each with the labels of its
    /// clients other than the CLI ("Desktop", "Work"); the CLI is said as
    /// "signed in". An account whose only client is the CLI maps to `[]`.
    public typealias ActiveClients = [String: [String]]

    public struct Limits: Sendable, Equatable {
        /// One account's block.
        public struct Block: Sendable, Equatable {
            /// Whose windows these are. Nil only with no account known yet.
            public var account: String?
            /// The account's short name; nil in the one-block layout for a
            /// single-account user, who has no question to answer.
            public var name: String?
            /// True: the login Claude Code is using ("signed in"). False: the
            /// one-block layout scoped to another login ("not signed in").
            /// Nil: neither is said.
            public var signedIn: Bool?
            /// Its other active clients, "Desktop · Work".
            public var clients: [String]
            public var readings: MenuBarWindowReadings

            public init(account: String?, name: String? = nil, signedIn: Bool? = nil,
                        clients: [String] = [], readings: MenuBarWindowReadings = MenuBarWindowReadings()) {
                self.account = account
                self.name = name
                self.signedIn = signedIn
                self.clients = clients
                self.readings = readings
            }
        }

        /// One block per account when accounts run at the same time, else
        /// the scope's one block.
        public var grouped: Bool
        public var blocks: [Block]

        public init(grouped: Bool, blocks: [Block]) {
            self.grouped = grouped
            self.blocks = blocks
        }
    }

    // MARK: - State

    /// Today's rows for the spend scope. Nil until the first read lands.
    public private(set) var today: MenuBarLabelFeed.Usage?
    /// The blocks. Nil until the first read lands.
    public private(set) var limits: Limits?

    @ObservationIgnored private let todayLane = KeyedReadLane<MenuBarLabelFeed.UsageKey, MenuBarLabelFeed.Usage>()
    @ObservationIgnored private let limitsLane = KeyedReadLane<LimitsKey, Limits>()

    /// Reads each half has started. Diagnostic: nothing draws them.
    public var todayReads: Int { todayLane.reads }
    public var limitsReads: Int { limitsLane.reads }

    public init() {}

    /// Make `today` `key`'s, unless it already is. The key's `today` should
    /// be true and its `model` false: the dropdown shows no model.
    public func loadToday(_ key: MenuBarLabelFeed.UsageKey, from container: ModelContainer) async {
        await todayLane.load(key, read: { key in
            MenuBarLabelFeed.readUsage(key, in: ModelContext(container))
        }, apply: { [self] value in
            if value != today { today = value }
        })
    }

    /// Make `limits` `key`'s, unless it already is. `clients` are the active
    /// clients as of the key's `clients` generation.
    public func loadLimits(_ key: LimitsKey, clients: ActiveClients, from container: ModelContainer,
                           homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) async {
        await limitsLane.load(key, read: { key in
            Self.readLimits(key, clients: clients, in: ModelContext(container), homeDirectory: homeDirectory)
        }, apply: { [self] value in
            if value != limits { limits = value }
        })
    }

    // MARK: - Reads

    /// The dropdown's blocks.
    ///
    /// Concurrent accounts get a block each; sequential ones do not. When two
    /// accounts run at the same time both caps bind at once, and showing one
    /// is showing half. Used one at a time, the ordinary switcher case, only
    /// one binds, and a second block is noise in a menu that has to stay
    /// glanceable. The mode is decided from facts, not a heuristic: a
    /// session-mode config root, or activation spans that genuinely overlap
    /// (`AccountParallelism`). Several clients on several accounts at once is
    /// the same thing (#245): Desktop running a routine on one account while
    /// the CLI is on another binds both, so the menu groups whenever more than
    /// one account is active, and shows the active ones.
    ///
    /// Otherwise the one block is the scope's account, or the signed-in one
    /// when the scope is "all accounts", named when there is more than one
    /// account: the menu bar is read without opening the app, so a percentage
    /// with no owner is a number you cannot act on.
    ///
    /// `homeDirectory` is where `AccountParallelism` looks for session-mode
    /// profile roots; a test passes an empty one.
    public nonisolated static func readLimits(
        _ key: LimitsKey, clients: ActiveClients, in context: ModelContext,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Limits {
        let all = ((try? context.fetch(FetchDescriptor<Account>())) ?? []).sorted(by: Account.listOrder)
        // One account is `.single` without looking further; `mode` would
        // fetch the table again to find that out.
        let concurrent = all.count > 1
            && AccountParallelism.mode(context: context, homeDirectory: homeDirectory) == .concurrent
        if let grouped = AccountClients.menuGroupAccounts(
            all: all.map(\.id), concurrent: concurrent, active: Set(clients.keys)) {
            return Limits(grouped: true, blocks: all.filter { grouped.contains($0.id) }.map { account in
                Limits.Block(account: account.id, name: account.shortLabel,
                             signedIn: account.isActive ? true : nil,
                             clients: clients[account.id] ?? [],
                             readings: MenuBarWindowReadings.read(context, account: account.id))
            })
        }
        let shown = UsageScope.resolveLimitAccountId(scope: key.scope, active: key.active, in: context)
        let name = all.count > 1 ? all.first { $0.id == shown }?.shortLabel : nil
        let signedIn = shown.map { id in all.first(where: \.isActive)?.id == id } ?? true
        return Limits(grouped: false, blocks: [
            Limits.Block(account: shown, name: name, signedIn: name == nil ? nil : signedIn,
                         readings: MenuBarWindowReadings.read(context, account: shown)),
        ])
    }
}
