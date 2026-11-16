import Foundation
import Observation
import SwiftData

/// Says that a save just changed `Account` rows (#413).
///
/// Every writer of `Account` posts it **after its save**: the poll that caches
/// an account's latest readings and plan, the active-account switch, a rename,
/// the rows created on sight (a login, cswap's roster, Claude Desktop), and the
/// labels and slots the trail recorder fills in. A reader that hears it reads
/// the store at once, so a post before the save would be read as "nothing
/// changed" and then nothing would say otherwise.
///
/// A writer says only that it wrote, never what. Deciding whether anything a
/// surface shows moved is the reader's job (`AccountList.publish`), so a writer
/// that posts for a write nobody shows costs one small read, and one that
/// forgets to say what it wrote can only cause a read, never hide one.
public enum AccountWriteSignal {

    public static let name = Notification.Name("PacerAccountRowsDidChange")

    /// Post from any thread; it never waits on the main actor. `sender` is the
    /// writer, the notification's `object`, so a test can listen to its own.
    public static func post(from sender: AnyObject? = nil, center: NotificationCenter = .default) {
        center.post(name: name, object: sender)
    }
}

/// One account as the window shell and its toolbar list it: who it is, and
/// whether it is the signed-in login. Not its readings (`AccountLatestReadings`)
/// so the toolbar, which shows none, is not redrawn by every poll.
public struct AccountListEntry: Sendable, Equatable, Identifiable, AccountListOrdering {
    public let id: String
    /// `Account.label`, resolved when the row was read.
    public let label: String
    public let isActive: Bool
    public let switcherSlot: Int?

    public init(id: String, label: String, isActive: Bool, switcherSlot: Int? = nil) {
        self.id = id
        self.label = label
        self.isActive = isActive
        self.switcherSlot = switcherSlot
    }

    public init(_ account: Account) {
        self.init(id: account.id, label: account.label,
                  isActive: account.isActive, switcherSlot: account.switcherSlot)
    }
}

/// An account's latest readings, as the poller caches them on its row.
public struct AccountLatestReadings: Sendable, Equatable {
    public let fiveHourPct: Double?
    public let fiveHourResetsAt: Date?
    public let sevenDayPct: Double?
    public let sevenDayResetsAt: Date?
    /// The poll's `sampledAt`, which the live meter's value carries too
    /// (`LiveMeterReadout`): shown, through which number the title gives.
    public let polledAt: Date?

    public init(fiveHourPct: Double?, fiveHourResetsAt: Date?,
                sevenDayPct: Double?, sevenDayResetsAt: Date?, polledAt: Date?) {
        self.fiveHourPct = fiveHourPct
        self.fiveHourResetsAt = fiveHourResetsAt
        self.sevenDayPct = sevenDayPct
        self.sevenDayResetsAt = sevenDayResetsAt
        self.polledAt = polledAt
    }

    public init(_ account: Account) {
        self.init(fiveHourPct: account.latestFiveHourPct,
                  fiveHourResetsAt: account.latestFiveHourResetsAt,
                  sevenDayPct: account.latestSevenDayPct,
                  sevenDayResetsAt: account.latestSevenDayResetsAt,
                  polledAt: account.latestPolledAt)
    }
}

/// Every account, for the surfaces that stay mounted while the window is open:
/// the window shell's title ("5h 23% • 7d 41%") and the toolbar's account menu
/// (#413).
///
/// Both held a `@Query<Account>`. A `@Query` re-fetches on every save of its
/// context, whatever changed (AGENTS.md), and Pacer saves on every scan cycle,
/// every poll and every lane-meta write, so the shell's body ran and the
/// toolbar laid out again several times a minute, each after a fetch on the
/// main thread: the PACER-19 shape.
///
/// **Read off the main actor, on a signal.** Each `AccountWriteSignal` post
/// bumps `generation` and reads the rows again on a context of its own in a
/// detached task, coalesced (one read in flight, one more queued). Nothing
/// else reads: a save that touched no account is not a reason to.
///
/// **Published only when something shown moved.** `accounts` holds what the
/// toolbar shows and `readings` what the title adds, each replaced only when
/// it differs. `lastSeenAt`, the plan and the extra-usage cents are not held,
/// so a write of them alone redraws nothing; a poll moves `readings` (its
/// `polledAt` decides which number the title gives) and leaves the toolbar
/// alone.
///
/// **Same rows, same order as the `@Query`s it replaces.** `accounts` is in the
/// order an unsorted fetch returns, which is what the shell's "the first one"
/// fallback read; a menu sorts it with `Account.listOrder`, as before.
@MainActor
@Observable
public final class AccountList {

    public static let shared = AccountList(center: .default)

    /// Every account, in store order.
    public private(set) var accounts: [AccountListEntry] = []
    /// Each account's latest readings, by id.
    public private(set) var readings: [String: AccountLatestReadings] = [:]

    /// Bumped on **every** `AccountWriteSignal` post. A counter, for the reason
    /// `RateLimitWriteSignal.generation` gives: two writes in the same instant
    /// are two writes, and a timestamp would collapse them.
    public private(set) var generation: UInt64 = 0
    /// The `generation` the published values were read at. Equal to
    /// `generation` once every signalled write has been read.
    public private(set) var loadedGeneration: UInt64 = 0

    @ObservationIgnored private var container: ModelContainer?
    /// Registered once and never removed: the block holds the list weakly.
    @ObservationIgnored private var observer: (any NSObjectProtocol)?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var pending = false
    /// Bumped by `start` and `stop`, so a read that straddles one is dropped.
    @ObservationIgnored private var epoch: UInt64 = 0

    /// `center` is the default one in the app; a test passes its own so it can
    /// post without reaching anything else listening.
    init(center: NotificationCenter) {
        // `queue: nil`: the block runs on the posting thread. A writer on the
        // poller or the scan actor must not wait for the main thread to take
        // the note (`queue: .main` would make it), so off main it only hops.
        observer = center.addObserver(forName: AccountWriteSignal.name, object: nil, queue: nil) {
            [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.noteWrite() }
            } else {
                Task { @MainActor [weak self] in self?.noteWrite() }
            }
        }
    }

    // MARK: - Lifecycle

    /// Read from `container`, now and on every signal. Idempotent per
    /// container, so the app's launch and the window can both call it.
    public func start(container: ModelContainer) {
        guard container !== self.container else { return }
        stop()
        self.container = container
        refresh()
    }

    /// Stop reading and forget what was read.
    public func stop() {
        container = nil
        epoch &+= 1
        pending = false
        loading = nil
        if !accounts.isEmpty { accounts = [] }
        if !readings.isEmpty { readings = [:] }
    }

    /// Record a write and read it.
    func noteWrite() {
        generation &+= 1
        refresh()
    }

    /// Ask for a read. Coalesced: a request while one runs becomes one more
    /// after it.
    private func refresh() {
        guard let container else { return }
        pending = true
        guard loading == nil else { return }
        let started = epoch
        loading = Task { @MainActor [weak self] in
            await self?.drain(container, epoch: started)
        }
    }

    private func drain(_ container: ModelContainer, epoch started: UInt64) async {
        while pending, started == epoch {
            pending = false
            let wanted = generation
            let read = await Task.detached(priority: .userInitiated) {
                Self.read(container)
            }.value
            // Still wanted? A restart means another store; drop it.
            guard started == epoch else { return }
            // A write landed while this read ran, and the read may predate
            // it. The next pass reads again straight away; publishing this
            // one first would redraw for a value about to be replaced.
            if pending { continue }
            if let read { publish(read) }
            loadedGeneration = wanted
        }
        if started == epoch { loading = nil }
    }

    /// Test seam: returns once no read is in flight or queued.
    func settled() async {
        while let task = loading { await task.value }
    }

    // MARK: - Read

    struct Snapshot: Sendable, Equatable {
        let accounts: [AccountListEntry]
        let readings: [String: AccountLatestReadings]
    }

    /// Every account, on a context of its own. Pure reads; safe off the main
    /// actor. Nil when the store cannot answer (a schema without `Account`, a
    /// failed fetch), which keeps what is shown rather than blanking it.
    nonisolated static func read(_ container: ModelContainer) -> Snapshot? {
        let context = ModelContext(container)
        let names = Set(container.schema.entities.map(\.name))
        guard names.contains(Schema.entityName(for: Account.self)),
              let rows = try? context.fetch(FetchDescriptor<Account>()) else { return nil }
        return Snapshot(
            accounts: rows.map(AccountListEntry.init),
            readings: Dictionary(rows.map { ($0.id, AccountLatestReadings($0)) },
                                 uniquingKeysWith: { first, _ in first }))
    }

    /// Replace each half only when it differs. An `@Observable` assignment
    /// notifies whether or not the value changed, so the comparison is what
    /// keeps an unshown write from redrawing anything.
    private func publish(_ read: Snapshot) {
        if read.accounts != accounts { accounts = read.accounts }
        if read.readings != readings { readings = read.readings }
    }

    // MARK: - Lookups

    /// The account `id` names, if it is listed.
    public func entry(id: String?) -> AccountListEntry? {
        guard let id else { return nil }
        return accounts.first { $0.id == id }
    }

    /// The account the window's limits are for: the one `limitAccountId`
    /// names (`UsageScope.limitAccountId`), else the signed-in login, else the
    /// first listed, which on a single-account install is the only one.
    public func limitAccount(_ limitAccountId: String?) -> AccountListEntry? {
        entry(id: limitAccountId) ?? accounts.first { $0.isActive } ?? accounts.first
    }
}
