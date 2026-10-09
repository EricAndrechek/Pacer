import Foundation
import SwiftData

public extension Account {

    /// What is known about an account before Pacer has read its usage: its
    /// identity, and whatever label the place it was seen in carried.
    ///
    /// Only fields `Account` already stores. A login is seen in Claude Code's
    /// own `oauthAccount` (org id, email, org name) or in cswap's roster (org
    /// id, email, slot); neither is a reason to keep anything new.
    struct Seed: Sendable, Equatable {
        public let id: String
        public let organizationId: String?
        public let emailAddress: String?
        public let organizationName: String?
        public let switcherSlot: Int?

        public init(
            id: String,
            organizationId: String?,
            emailAddress: String? = nil,
            organizationName: String? = nil,
            switcherSlot: Int? = nil
        ) {
            self.id = id
            self.organizationId = organizationId
            self.emailAddress = emailAddress
            self.organizationName = organizationName
            self.switcherSlot = switcherSlot
        }

        /// The account a config observation names.
        public init(_ observation: ActiveAccountObserver.Observation) {
            self.init(
                id: observation.accountKey,
                organizationId: observation.organizationId,
                emailAddress: observation.emailAddress,
                organizationName: observation.organizationName)
        }

        /// An account cswap's roster lists.
        public init(_ listed: SwitcherUsageCache.ListedAccount) {
            self.init(
                id: Account.key(forOrg: listed.organizationId),
                organizationId: listed.organizationId,
                emailAddress: listed.emailAddress,
                switcherSlot: listed.slot)
        }
    }

    /// Make sure `seed` has a row, creating it if it does not (#241).
    ///
    /// `Account` rows used to be created in exactly one place, `recordPoll` —
    /// so a login Pacer had never read usage for did not exist. The trail could
    /// accept the switch within a second, `setActiveAccount` would then flip
    /// every row inactive and find nothing to activate, and `UsageScope`
    /// (which only publishes ids the store knows) kept the dashboard on the
    /// account just left until a first reading landed. If that read was 429'd,
    /// the account stayed invisible.
    ///
    /// Strictly a create. An existing row is returned untouched: what it holds
    /// came from a poll, a rename or the observer, all of which know more than
    /// a sighting does. No readings are written — "no reading yet" is a real
    /// state the surfaces render, and a placeholder 0% would be a lie.
    ///
    /// Does not save; the caller owns the context and decides when.
    @discardableResult
    static func ensure(_ seed: Seed, in context: ModelContext, now: Date = Date()) -> (account: Account, created: Bool) {
        let id = seed.id
        var descriptor = FetchDescriptor<Account>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let existing = (try? context.fetch(descriptor))?.first {
            return (existing, false)
        }
        let account = Account(
            id: id,
            organizationId: seed.organizationId,
            displayName: Account.defaultName(forOrg: seed.organizationId, subscriptionType: nil),
            isActive: false,
            firstSeenAt: now,
            lastSeenAt: now,
            emailAddress: seed.emailAddress,
            organizationName: seed.organizationName)
        account.switcherSlot = seed.switcherSlot
        context.insert(account)
        return (account, true)
    }
}
