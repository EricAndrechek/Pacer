import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// Which token lane took each rate-limit reading (#352): the lane's
/// fingerprint on every row the poll writes, kept through the archive and
/// back, nil where no lane of Pacer's took it.
@Suite("Reading lanes")
struct ReadingLaneTests {

    private static func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: RateLimitSample.self, UsageLimitSample.self, ExtraUsageSample.self,
            AccountUsageArchive.self, Account.self, ClaudeCodeMeta.self, TokenLaneMeta.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private static func client(token: String) -> OAuthClient {
        let blob = try! JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": [
                "accessToken": token,
                "expiresAt": Int64(Date().addingTimeInterval(3600).timeIntervalSince1970) * 1000,
            ] as [String: Any],
        ])
        let body = """
            {"five_hour":{"utilization":40.0,"resets_at":"2026-05-06T17:00:00Z"},
             "seven_day":{"utilization":12.5,"resets_at":"2026-05-13T00:00:00Z"},
             "limits":[{"kind":"weekly_scoped","group":"weekly","percent":7,"severity":"normal",
                        "resets_at":"2026-05-13T00:00:00Z",
                        "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}]}
            """
        return OAuthClient(keychain: KeychainOAuth(rawReader: { .success(blob) }),
                           transport: { _ in try HTTPOutcome.success(jsonBody: body).materialize() },
                           desktopEnabled: { false })
    }

    /// Every row a poll writes, fixed windows and scoped limits alike, names
    /// the token that took it, by the same fingerprint the Tokens table and
    /// `TokenLaneMeta` use. Never the token.
    @Test func aPolledReadingCarriesItsLane() async throws {
        let container = try Self.makeContainer()
        let poller = OAuthPoller(client: Self.client(token: "tok-lane-a"), container: container,
                                 configuration: .init(), clock: TestClock())
        _ = await poller.runOnce()

        let (fixed, scoped, metaIds) = try await MainActor.run {
            let context = ModelContext(container)
            return (try context.fetch(FetchDescriptor<RateLimitSample>()).map(\.laneId),
                    try context.fetch(FetchDescriptor<UsageLimitSample>()).map(\.laneId),
                    try context.fetch(FetchDescriptor<TokenLaneMeta>()).map(\.id))
        }
        let lane = OAuthPoller.laneId("tok-lane-a")
        #expect(lane.count == 12)
        #expect(fixed.count == 2 && fixed.allSatisfy { $0 == lane })
        #expect(scoped.count == 1 && scoped.allSatisfy { $0 == lane })
        #expect(metaIds.contains(lane))
        #expect(!(fixed + scoped).contains { $0?.contains("tok") == true })
    }

    /// A row written without one (every row from before this was recorded,
    /// and a reading lifted from the switcher's cache) has no lane, and
    /// nothing fills one in.
    @Test func rowsWithoutALaneStayWithout() {
        let r = RateLimitSample(sampledAt: Date(), window: RateLimitWindowName.sevenDay, usedPercentage: 1,
                                resetsAt: nil, source: RateLimitSource.cswap, accountId: "acct")
        let u = UsageLimitSample(sampledAt: Date(), identity: "weekly_scoped|Fable|", kind: "weekly_scoped",
                                 group: "weekly", label: "Fable", percent: 1, resetsAt: nil, severity: "normal",
                                 isActive: false, source: RateLimitSource.cswap, accountId: "acct")
        #expect(r.laneId == nil && u.laneId == nil)
    }

    /// Past the live window a row moves to the archive, and an archived row
    /// in the window comes back: the lane goes with it both ways, or the
    /// record would lose it after 35 days.
    @MainActor
    @Test func theLaneSurvivesTheArchiveAndComesBack() async throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let old = Date().addingTimeInterval(-100 * 86_400)
        context.insert(RateLimitSample(sampledAt: old, window: RateLimitWindowName.sevenDay, usedPercentage: 77,
                                       resetsAt: nil, source: RateLimitSource.oauth, accountId: "acct",
                                       laneId: "aaaaaaaaaaaa"))
        context.insert(UsageLimitSample(sampledAt: old, identity: "weekly_scoped|Fable|", kind: "weekly_scoped",
                                        group: "weekly", label: "Fable", percent: 40, resetsAt: nil,
                                        severity: "normal", isActive: true, modelDisplayName: "Fable",
                                        source: RateLimitSource.oauth, accountId: "acct",
                                        laneId: "bbbbbbbbbbbb"))
        try context.save()
        #expect(OAuthPoller.testEvictStaleLiveRows(context: context, accountId: "acct") == 2)
        try context.save()

        let archived = try context.fetch(FetchDescriptor<AccountUsageArchive>())
        #expect(Set(archived.compactMap(\.laneId)) == ["aaaaaaaaaaaa", "bbbbbbbbbbbb"])

        // Move them back inside the window, as a row archived by an earlier
        // build's switch would sit, and fold.
        let recent = Date().addingTimeInterval(-86_400)
        for row in archived { row.sampledAt = recent }
        context.insert(Account(id: "acct", organizationId: "acct", displayName: "A", isActive: true,
                               firstSeenAt: .distantPast, lastSeenAt: .distantPast))
        try context.save()
        await OAuthPoller.foldArchiveIntoLiveTables(container: container)

        let fresh = ModelContext(container)
        #expect(try fresh.fetch(FetchDescriptor<RateLimitSample>()).map(\.laneId) == ["aaaaaaaaaaaa"])
        #expect(try fresh.fetch(FetchDescriptor<UsageLimitSample>()).map(\.laneId) == ["bbbbbbbbbbbb"])
        #expect(try fresh.fetchCount(FetchDescriptor<AccountUsageArchive>()) == 0)
    }
}
