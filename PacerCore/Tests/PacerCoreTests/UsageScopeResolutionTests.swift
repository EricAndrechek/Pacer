import Foundation
import SwiftData
import Testing
@testable import PacerCore

// #324: a view that takes its scope as an input resolves whose limits it
// shows from that scope, never from the stored defaults. Fictional ids.

@Suite("Limit account resolution from a held scope")
@MainActor
struct UsageScopeResolutionTests {

    private func context(activeRow: String?) throws -> ModelContext {
        let context = ModelContext(try PacerStore.makeInMemoryContainer())
        if let activeRow {
            context.insert(Account(id: activeRow, organizationId: activeRow, displayName: "Row",
                                   isActive: true, firstSeenAt: Date(), lastSeenAt: Date()))
            try context.save()
        }
        return context
    }

    @Test("the held scope wins over the active login and the store")
    func scopeWins() throws {
        let c = try context(activeRow: "acct-row")
        #expect(UsageScope.resolveLimitAccountId(scope: "acct-b", active: "acct-a", in: c) == "acct-b")
    }

    @Test("all accounts resolves to the active login, then to the store's active row")
    func allAccountsFallsBack() throws {
        let c = try context(activeRow: "acct-row")
        #expect(UsageScope.resolveLimitAccountId(scope: nil, active: "acct-a", in: c) == "acct-a")
        #expect(UsageScope.resolveLimitAccountId(scope: nil, active: nil, in: c) == "acct-row")
        #expect(UsageScope.resolveLimitAccountId(scope: nil, active: nil, in: try context(activeRow: nil)) == nil)
    }
}
