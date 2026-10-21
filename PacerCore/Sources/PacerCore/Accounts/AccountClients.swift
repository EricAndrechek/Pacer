import Foundation
import Observation

/// Which clients are on which account right now (#245). The design is in
/// `docs/multi-client-accounts.md`.
///
/// "Active" used to be one flag, `Account.isActive`: the CLI's login. But
/// several clients can be live on different accounts at once, even with a
/// switcher set to one account at a time. Claude Desktop bills its own login
/// (each install its own, #295), and a pinned config root bills the profile's.
/// So "active" is a set of (account, client) pairs, each with the evidence it
/// came from and when it was last seen.
///
/// | client | evidence | active while |
/// |---|---|---|
/// | CLI | the trail's open default-login span | it is the login (no timeout: it is what the next message bills) |
/// | each Desktop install | its session records' `lastActivityAt`, per account folder | 30 minutes after the newest |
/// | each pinned profile | its open trail span, and its transcripts' modification times | 30 minutes after its newest transcript write |
///
/// A value, built off the main actor by the scan and published to two
/// readers: `AccountClientsStore` for the HTTP API's background queue, and
/// `AccountClientsMonitor` for views.
public struct AccountClients: Sendable, Equatable {
    public enum Kind: String, Sendable, Codable, Equatable {
        case cli, desktop, profile
    }

    public struct Entry: Sendable, Equatable, Hashable, Codable {
        public let accountId: String
        public let kind: Kind
        /// Stable within a machine: `"cli"`, an install's data folder, a
        /// profile's config root.
        public let clientId: String
        /// "CLI", "Desktop", "Desktop · Work", "Profile · 1-work".
        public let label: String
        /// When the evidence last moved: the login's start, Desktop's newest
        /// record, the profile's newest transcript write.
        public let lastSeenAt: Date?
        /// When it stops counting as active. nil means for as long as the
        /// evidence holds, which is the CLI's login.
        public let activeUntil: Date?

        public init(accountId: String, kind: Kind, clientId: String, label: String,
                    lastSeenAt: Date?, activeUntil: Date?) {
            self.accountId = accountId
            self.kind = kind
            self.clientId = clientId
            self.label = label
            self.lastSeenAt = lastSeenAt
            self.activeUntil = activeUntil
        }

        public func isActive(at now: Date) -> Bool {
            activeUntil.map { now < $0 } ?? true
        }
    }

    /// Every client seen, active or not, CLI first, then by label.
    public let entries: [Entry]

    public init(entries: [Entry]) { self.entries = entries }

    public static let empty = AccountClients(entries: [])

    /// How long a Desktop install, or a pinned profile, counts as active on an
    /// account after its last activity. Owner decision (2026-10-20): long
    /// enough to cover a routine's gaps between turns, short enough that a
    /// Desktop left open on an idle account stops claiming it.
    public static let activeWindow: TimeInterval = 30 * 60

    /// What a profile is called: its folder, which a switcher names after the
    /// slot ("1-work").
    public static func profileLabel(root: String) -> String {
        "Profile · \(URL(fileURLWithPath: root).lastPathComponent)"
    }

    /// Build from the evidence. Pure, for tests.
    ///
    /// - `cliAccount` / `cliSince`: the trail's open default-login span.
    /// - `desktop`: `DesktopSessionDirectory.activity`, install → account →
    ///   newest record; `installLabels` names each install.
    /// - `profiles`: open pinned roots (root → account) and each root's newest
    ///   transcript write, when one is known.
    public static func build(
        cliAccount: String?, cliSince: Date?,
        desktop: [String: [String: Date]], installLabels: [String: String],
        profiles: [String: String], profileActivity: [String: Date]
    ) -> AccountClients {
        var out: [Entry] = []
        if let cliAccount {
            out.append(Entry(accountId: cliAccount, kind: .cli, clientId: "cli", label: "CLI",
                             lastSeenAt: cliSince, activeUntil: nil))
        }
        var rest: [Entry] = []
        for (install, accounts) in desktop {
            for (account, at) in accounts {
                rest.append(Entry(accountId: account, kind: .desktop, clientId: install,
                                  label: installLabels[install] ?? "Desktop",
                                  lastSeenAt: at, activeUntil: at.addingTimeInterval(activeWindow)))
            }
        }
        for (root, account) in profiles {
            let at = profileActivity[root]
            rest.append(Entry(accountId: account, kind: .profile, clientId: root,
                              label: profileLabel(root: root), lastSeenAt: at,
                              activeUntil: (at ?? .distantPast).addingTimeInterval(activeWindow)))
        }
        rest.sort { ($0.label, $0.accountId) < ($1.label, $1.accountId) }
        return AccountClients(entries: out + rest)
    }

    /// The clients active on `accountId` at `now`, CLI first.
    public func active(on accountId: String, at now: Date) -> [Entry] {
        entries.filter { $0.accountId == accountId && $0.isActive(at: now) }
    }

    /// Every account with at least one active client.
    public func activeAccountIds(at now: Date) -> Set<String> {
        Set(entries.filter { $0.isActive(at: now) }.map(\.accountId))
    }

    /// The next instant an entry stops being active, after `now`: when a view
    /// showing these has to look again even though nothing was written.
    public func nextExpiry(after now: Date) -> Date? {
        entries.compactMap(\.activeUntil).filter { $0 > now }.min()
    }

    /// Which accounts the menu bar gives a group of their own, in `all`'s
    /// order, or nil for the single-group layout. Several accounts active at
    /// once bind at once, so more than one active account groups; concurrent
    /// profiles group every account, as they always did.
    public static func menuGroupAccounts(all: [String], concurrent: Bool,
                                         active: Set<String>) -> [String]? {
        guard concurrent || active.count > 1 else { return nil }
        return concurrent ? all : all.filter(active.contains)
    }

    /// What an alert calls an account: `base`, plus the clients on it when the
    /// CLI is not one of them ("work (Desktop · Work)"), so a banner about an
    /// account you are not signed into says where its usage comes from.
    public func alertLabel(_ base: String, account: String, at now: Date) -> String {
        let active = self.active(on: account, at: now)
        let others = active.filter { $0.kind != .cli }.map(\.label)
        guard !others.isEmpty, !active.contains(where: { $0.kind == .cli }) else { return base }
        return "\(base) (\(others.joined(separator: ", ")))"
    }

    /// The (account, client) pairs active at `now`, for telling whether the
    /// active set moved.
    public func activePairs(at now: Date) -> Set<String> {
        Set(entries.filter { $0.isActive(at: now) }.map { "\($0.accountId)|\($0.clientId)" })
    }
}

/// The latest `AccountClients`, for readers off the main actor (the HTTP API).
/// Written by the scan after each cycle; empty until the first one.
public enum AccountClientsStore {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var value = AccountClients.empty

    public static var current: AccountClients { lock.withLock { value } }

    /// Store `clients`; returns whether they differ from what was there.
    @discardableResult
    public static func publish(_ clients: AccountClients) -> Bool {
        lock.withLock {
            guard clients != value else { return false }
            value = clients
            return true
        }
    }

    /// Posted on the main queue when the set of active (account, client)
    /// pairs changes, including when a Desktop's 30 minutes run out. The
    /// HTTP stream turns it into a `clients` event.
    public static let didChange = Notification.Name("PacerAccountClientsDidChange")
}

/// The same for views (#245): observable, and it moves on its own when a
/// client's 30 minutes run out, so a view that reads it redraws then rather
/// than at the next scan, which on an idle machine is minutes away.
@MainActor
@Observable
public final class AccountClientsMonitor {
    public static let shared = AccountClientsMonitor()

    public private(set) var clients = AccountClients.empty
    /// The instant `clients` is judged at. Moves on every update and at each
    /// expiry; a read of `active(on:)` reads it, so an expiry redraws.
    public private(set) var now = Date()
    /// Bumped whenever what is active changes, for callers that key a reload
    /// on a value (the menu's `reloadKey`).
    public private(set) var generation = 0

    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private var lastPairs: Set<String> = []

    public init() {}

    public func update(_ next: AccountClients, at date: Date = Date()) {
        if next != clients { clients = next }
        settle(at: date)
    }

    /// The clients active on `accountId` now, CLI included.
    public func active(on accountId: String) -> [AccountClients.Entry] {
        clients.active(on: accountId, at: now)
    }

    /// Every account with an active client.
    public var activeAccountIds: Set<String> { clients.activeAccountIds(at: now) }

    private func settle(at date: Date) {
        now = date
        let pairs = clients.activePairs(at: date)
        if pairs != lastPairs {
            lastPairs = pairs
            generation &+= 1
            NotificationCenter.default.post(name: AccountClientsStore.didChange, object: nil)
        }
        expiry?.cancel()
        guard let next = clients.nextExpiry(after: date) else { return }
        expiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow + 1)))
            guard !Task.isCancelled, let self else { return }
            self.settle(at: Date())
        }
    }
}
