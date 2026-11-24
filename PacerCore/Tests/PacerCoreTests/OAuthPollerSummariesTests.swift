import Foundation
import SwiftData
import Testing
@testable import PacerCore

// #417: `OAuthPoller.publishStatus` builds the switcher's account summaries on
// the poller, not inside `MainActor.run`. These pin that the off-main builder
// gives what the main-actor one gave, and that it needs no main actor at all.
// Fictional ids throughout.

private func makeContainer() throws -> ModelContainer {
    try ModelContainer(for: Schema(PacerStore.allModelTypes),
                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
}

private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

/// Five accounts that exercise every rule of the order: two slotted (out of
/// insertion order), one active by its row, one active only by the poller's
/// key, and two unslotted ones ordered by when they were polled.
@MainActor
private func seed(_ container: ModelContainer) throws {
    let context = ModelContext(container)
    func add(_ id: String, active: Bool = false, slot: Int? = nil, email: String? = nil,
             five: Double? = nil, seven: Double? = nil, cents: Int? = nil,
             polled: TimeInterval? = nil, plan: String? = "max", tier: String? = nil) {
        let a = Account(id: id, organizationId: "org-\(id)", displayName: "Claude account (max)",
                        isActive: active, firstSeenAt: t0, lastSeenAt: t0,
                        subscriptionType: plan, rateLimitTier: tier, emailAddress: email,
                        latestFiveHourPct: five, latestSevenDayPct: seven,
                        latestExtraUsageCents: cents,
                        latestPolledAt: polled.map { t0.addingTimeInterval($0) })
        a.switcherSlot = slot
        context.insert(a)
    }
    add("acme-old", polled: 10)
    add("acme-two", slot: 2, email: "two@example.com", five: 40, seven: 60, polled: 30)
    add("acme-new", five: 5, polled: 50, tier: "default_claude_max_20x")
    add("acme-one", slot: 1, five: 12, seven: 34, cents: 250, polled: 20)
    add("acme-active", active: true, email: "active@example.com", polled: 5)
    add("acme-key", polled: 1)
    try context.save()
}

/// The main-actor builder #417 replaced, verbatim, as the reference.
@MainActor
private func oldPath(_ container: ModelContainer, laneCounts: [String: Int],
                     activeKey: String?) -> [AccountStatusSummary] {
    let context = ModelContext(container)
    let rows = (try? context.fetch(FetchDescriptor<Account>())) ?? []
    return rows
        .map { a in
            AccountStatusSummary(
                id: a.id, organizationId: a.organizationId, displayName: a.label,
                isActive: a.isActive || a.id == activeKey,
                subscriptionType: a.subscriptionType, rateLimitTier: a.rateLimitTier,
                fiveHourPct: a.latestFiveHourPct, sevenDayPct: a.latestSevenDayPct,
                extraUsageCents: a.latestExtraUsageCents, lastPolledAt: a.latestPolledAt,
                laneCount: laneCounts[a.id] ?? 0, switcherSlot: a.switcherSlot)
        }
        .sorted { l, r in
            switch (l.switcherSlot, r.switcherSlot) {
            case let (a?, b?) where a != b: return a < b
            case (nil, _?): return false
            case (_?, nil): return true
            default: break
            }
            if l.isActive != r.isActive { return l.isActive }
            return (l.lastPolledAt ?? .distantPast) > (r.lastPolledAt ?? .distantPast)
        }
}

/// Synchronous, so it can ask `Thread` from inside a task.
private func onMainThread() -> Bool { Thread.isMainThread }

@Suite struct OAuthPollerSummariesTests {

    private let lanes = ["acme-one": 2, "acme-active": 3, "acme-new": 1]

    @Test("Off-main summaries match the main-actor builder they replace")
    func matchesOldPath() async throws {
        let container = try makeContainer()
        try await seed(container)
        for key in [nil, "acme-key", "acme-one"] as [String?] {
            let expected = await oldPath(container, laneCounts: lanes, activeKey: key)
            let built = OAuthPoller.accountSummaries(container: container, laneCounts: lanes,
                                                     activeKey: key)
            #expect(built == expected)
        }
    }

    @Test("Same rows, same order, by hand")
    func handChecked() async throws {
        let container = try makeContainer()
        try await seed(container)
        let built = OAuthPoller.accountSummaries(container: container, laneCounts: lanes,
                                                 activeKey: "acme-key")
        // Slots first in slot order; then the active ones (by row, by key),
        // newest poll first; then the rest, newest poll first.
        #expect(built.map(\.id) == ["acme-one", "acme-two", "acme-active", "acme-key",
                                    "acme-new", "acme-old"])
        let byId = Dictionary(uniqueKeysWithValues: built.map { ($0.id, $0) })
        let one = try #require(byId["acme-one"])
        #expect(one.organizationId == "org-acme-one")
        #expect(one.fiveHourPct == 12 && one.sevenDayPct == 34 && one.extraUsageCents == 250)
        #expect(one.laneCount == 2 && one.switcherSlot == 1 && !one.isActive)
        #expect(byId["acme-two"]?.displayName == "two@example.com")   // `label`, not `displayName`
        #expect(byId["acme-active"]?.isActive == true && byId["acme-active"]?.laneCount == 3)
        #expect(byId["acme-key"]?.isActive == true)                    // by the poller's key
        #expect(byId["acme-new"]?.rateLimitTier == "default_claude_max_20x")
        #expect(byId["acme-old"]?.laneCount == 0)
    }

    @Test("The builders need no main actor")
    func runsOffMain() async throws {
        let container = try makeContainer()
        try await seed(container)
        let expected = await oldPath(container, laneCounts: lanes, activeKey: nil)
        let lanes = self.lanes
        let (built, onMain) = await Task.detached {
            (OAuthPoller.accountSummaries(container: container, laneCounts: lanes, activeKey: nil),
             onMainThread())
        }.value
        #expect(!onMain)
        #expect(built == expected)

        // The two per-poll probes moved with it.
        let (newer, activity) = await Task.detached {
            (OAuthPoller.isNewerThanStored(t0, account: "acme-one", container: container),
             OAuthPoller.latestActivity(container: container))
        }.value
        #expect(newer)            // no stored sample yet
        #expect(activity == nil)  // no tokens or sessions yet
    }

    @Test("An empty store builds no summaries")
    func emptyStore() throws {
        let container = try makeContainer()
        #expect(OAuthPoller.accountSummaries(container: container, laneCounts: [:],
                                             activeKey: "acme-key").isEmpty)
    }
}
