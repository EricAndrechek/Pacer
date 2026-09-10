import Foundation
import SwiftData
import Testing
@testable import PacerCore

@Suite struct OAuthPollerTests {

    // MARK: - Helpers

    private static func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: Heartbeat.self,
            TokenSample.self,
            DailyAggregate.self,
            ProjectDailyAggregate.self,
            RateLimitSample.self,
            ExtraUsageSample.self,
            UsageLimitSample.self,
            SessionInfo.self,
            ClaudeCodeMeta.self,
            TokenLaneMeta.self,
            Account.self,
            AccountUsageArchive.self,
            configurations: config
        )
    }

    /// Builds an `OAuthClient` whose transport returns a fixed sequence of
    /// HTTP results (last entry repeated), keyed off a single keychain
    /// token. Desktop is disabled so tests never touch the real machine.
    private static func sequencedClient(
        _ outcomes: [HTTPOutcome],
        keychainBlob: Data? = nil
    ) -> OAuthClient {
        let blob = keychainBlob ?? Self.defaultKeychainBlob()
        let kc = KeychainOAuth(rawReader: { .success(blob) })
        let counter = AtomicCounter()
        let outcomes = outcomes
        let transport: OAuthClient.Transport = { _ in
            let i = counter.next()
            return try outcomes[min(i, outcomes.count - 1)].materialize()
        }
        return OAuthClient(keychain: kc, transport: transport, desktopEnabled: { false })
    }

    private static func defaultKeychainBlob() -> Data { keychainBlob(token: "tok") }

    private static func keychainBlob(token: String) -> Data {
        let body: [String: Any] = [
            "claudeAiOauth": [
                "accessToken": token,
                "expiresAt": Int64(Date().addingTimeInterval(3600).timeIntervalSince1970) * 1000,
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    /// Sendable summary so we don't ferry `@Model` instances across actors.
    private static func fetchSampleSummaries(
        in container: ModelContainer
    ) async throws -> [(window: String, usedPercentage: Double, hasResetsAt: Bool, source: String, accountId: String?)] {
        try await MainActor.run {
            let context = ModelContext(container)
            let rows = try context.fetch(FetchDescriptor<RateLimitSample>())
            return rows.map {
                (window: $0.window, usedPercentage: $0.usedPercentage,
                 hasResetsAt: $0.resetsAt != nil, source: $0.source, accountId: $0.accountId)
            }
        }
    }

    /// Sendable scoped-limit summary for cross-actor assertions.
    private static func fetchScopedSummaries(
        in container: ModelContainer
    ) async throws -> [(identity: String, percent: Double, accountId: String?)] {
        try await MainActor.run {
            let context = ModelContext(container)
            return try context.fetch(FetchDescriptor<UsageLimitSample>()).map {
                (identity: $0.identity, percent: $0.percent, accountId: $0.accountId)
            }
        }
    }

    /// Sendable account summary for cross-actor assertions.
    struct AccountRow: Sendable { let id: String; let isActive: Bool; let latestFiveHourPct: Double? }

    private static func fetchAccounts(in container: ModelContainer) async throws -> [AccountRow] {
        try await MainActor.run {
            let context = ModelContext(container)
            return try context.fetch(FetchDescriptor<Account>()).map {
                AccountRow(id: $0.id, isActive: $0.isActive, latestFiveHourPct: $0.latestFiveHourPct)
            }
        }
    }

    // MARK: - Persistence on success

    @Test func successPersistsBothWindows() async throws {
        let container = try Self.makeContainer()
        let client = Self.sequencedClient([.success(jsonBody: """
            {"five_hour":{"utilization":40.0,"resets_at":"2026-05-06T17:00:00Z"},
             "seven_day":{"utilization":12.5,"resets_at":"2026-05-13T00:00:00Z"}}
        """)])
        let poller = OAuthPoller(
            client: client,
            container: container,
            configuration: .init(),
            clock: TestClock()
        )

        let outcome = await poller.runOnce()
        if case .success(let fh, let sd) = outcome {
            #expect(fh == 40.0)
            #expect(sd == 12.5)
        } else {
            Issue.record("expected success outcome, got \(outcome)")
        }

        let rows = try await Self.fetchSampleSummaries(in: container)
        #expect(rows.count == 2)
        let byWindow = Dictionary(grouping: rows, by: { $0.window })
        #expect(byWindow["five_hour"]?.first?.usedPercentage == 40.0)
        #expect(byWindow["seven_day"]?.first?.usedPercentage == 12.5)
        #expect(rows.allSatisfy { $0.source == "oauth" })
    }

    @Test func successPersistsSingleWindow() async throws {
        let container = try Self.makeContainer()
        let client = Self.sequencedClient([.success(jsonBody: """
            {"five_hour":{"utilization":3,"resets_at":null}}
        """)])
        let poller = OAuthPoller(
            client: client,
            container: container,
            configuration: .init(),
            clock: TestClock()
        )

        _ = await poller.runOnce()

        let rows = try await Self.fetchSampleSummaries(in: container)
        #expect(rows.count == 1)
        #expect(rows[0].window == "five_hour")
        #expect(rows[0].hasResetsAt == false)  // null preserved as nil
    }

    // MARK: - Per-lane cooldown + account guard

    /// A 429 cools the lane it hit; with only one lane, the next
    /// (cadence-ignoring) poll has nothing eligible left to spend.
    @Test func rateLimited429CoolsTheLane() async throws {
        let container = try Self.makeContainer()
        let client = Self.sequencedClient([.status(429), .status(429)])
        let poller = OAuthPoller(client: client, container: container, configuration: .init(), clock: TestClock())

        let first = await poller.runOnce()
        if case .rateLimited = first {} else { Issue.record("expected rateLimited, got \(first)") }
        // Lane is cooling; no other lane to fall back to.
        #expect(await poller.runOnce() == .credentialsNotFound)
    }

    /// A 401 drops the lane and rejects the token, so rediscovery filters
    /// it out — a single-token user then has no lane at all.
    @Test func unauthorized401DropsTheLaneAndDoesNotRecur() async throws {
        let container = try Self.makeContainer()
        let client = Self.sequencedClient([.status(401), .success(jsonBody: #"{"five_hour":{"utilization":1}}"#)])
        let poller = OAuthPoller(client: client, container: container, configuration: .init(), clock: TestClock())

        #expect(await poller.runOnce() == .unauthorized)
        #expect(await poller.runOnce() == .credentialsNotFound)
    }

    /// Two distinct orgs are BOTH tracked — neither dropped — and both write
    /// history, each row stamped with its account.
    ///
    /// This used to assert the opposite: only the active account wrote rows,
    /// and isolation came from the live table holding exactly one account.
    /// That bought isolation with the other account's chart, so isolation is
    /// now a stamp and a predicate. The property under test is the same one —
    /// interleaving two logins must never mix them into one history — but it
    /// is checked where it now lives.
    @Test func bothAccountsWriteHistoryAndEachRowCarriesItsAccount() async throws {
        let container = try Self.makeContainer()
        let kc = KeychainOAuth(rawReader: { .success(Self.keychainBlob(token: "tokA")) })
        let held = EphemeralCredentialStore(OAuthCredential(
            accessToken: "tokB",
            expiresAt: Date().addingTimeInterval(3600),
            subscriptionType: nil
        ))
        let counter = AtomicCounter()
        let outcomes: [HTTPOutcome] = [
            .success(jsonBody: #"{"five_hour":{"utilization":10}}"#, headers: ["anthropic-organization-id": "orgA"]),
            .success(jsonBody: #"{"five_hour":{"utilization":99}}"#, headers: ["anthropic-organization-id": "orgB"]),
        ]
        let transport: OAuthClient.Transport = { _ in
            try outcomes[min(counter.next(), outcomes.count - 1)].materialize()
        }
        let client = OAuthClient(keychain: kc, transport: transport, desktopEnabled: { false }, heldStore: held)
        let poller = OAuthPoller(client: client, container: container, configuration: .init(), clock: TestClock())

        // Lane 0 (keychain, tokA) establishes the active account A and persists.
        let first = await poller.runOnce()
        if case .success = first {} else { Issue.record("expected success, got \(first)") }
        // Lane 1 (held, tokB) resolves to org B → secondary, tracked, and kept.
        if case .secondaryAccount = await poller.runOnce() {} else {
            Issue.record("expected secondaryAccount")
        }

        let rows = try await Self.fetchSampleSummaries(in: container)
        #expect(rows.count == 2)
        #expect(rows.filter { $0.accountId == "orgA" }.map(\.usedPercentage) == [10.0])
        #expect(rows.filter { $0.accountId == "orgB" }.map(\.usedPercentage) == [99.0])
        // Nothing unstamped: an unstamped row would read as whichever account
        // a predicate happened to ask for.
        #expect(rows.allSatisfy { $0.accountId != nil })

        // Both accounts exist and org B's reading is cached on its row.
        let accounts = try await Self.fetchAccounts(in: container)
        #expect(accounts.count == 2)
        #expect(accounts.first { $0.id == "orgA" }?.isActive == true)
        let b = accounts.first { $0.id == "orgB" }
        #expect(b?.isActive == false)
        #expect(b?.latestFiveHourPct == 99.0)

        let snap = await poller.snapshot()
        #expect(snap.primaryLaneCount == 1)          // only org A is primary
        #expect(snap.primaryOrg == "orgA")
    }

    /// Switching the active account moves no rows.
    ///
    /// It used to move all of them: the outgoing account's live samples went
    /// to `AccountUsageArchive` and the incoming account's came back, measured
    /// at 107,705 rows and 14.3 seconds on a real store, several times a day
    /// for anyone auto-switching. Now both timelines are simply present, and
    /// switching flips a flag.
    ///
    /// The assertion that matters is that a switch is *lossless in both
    /// directions at once* — after switching to B, A's history is still
    /// readable, which under the swap it was not.
    @Test func switchingActiveAccountMovesNoRows() async throws {
        let container = try Self.makeContainer()
        let kc = KeychainOAuth(rawReader: { .success(Self.keychainBlob(token: "tokA")) })
        let held = EphemeralCredentialStore(OAuthCredential(
            accessToken: "tokB", expiresAt: Date().addingTimeInterval(3600), subscriptionType: nil
        ))
        let counter = AtomicCounter()
        // A poll (orgA 10%), B poll (orgB 99%), then B is active and polled (orgB 77%).
        let outcomes: [HTTPOutcome] = [
            .success(jsonBody: #"{"five_hour":{"utilization":10}}"#, headers: ["anthropic-organization-id": "orgA"]),
            .success(jsonBody: #"{"five_hour":{"utilization":99}}"#, headers: ["anthropic-organization-id": "orgB"]),
            .success(jsonBody: #"{"five_hour":{"utilization":77}}"#, headers: ["anthropic-organization-id": "orgB"]),
        ]
        let transport: OAuthClient.Transport = { _ in
            try outcomes[min(counter.next(), outcomes.count - 1)].materialize()
        }
        let client = OAuthClient(keychain: kc, transport: transport, desktopEnabled: { false }, heldStore: held)
        let poller = OAuthPoller(client: client, container: container, configuration: .init(), clock: TestClock())

        _ = await poller.runOnce()   // orgA active, writes A:10
        _ = await poller.runOnce()   // orgB secondary, writes B:99
        let laneBId = OAuthPoller.laneId("tokB")

        await poller.setActiveAccount(id: "orgB")
        var rows = try await Self.fetchSampleSummaries(in: container)
        #expect(rows.count == 2)                                        // nothing moved
        #expect(rows.contains { $0.usedPercentage == 10.0 && $0.accountId == "orgA" })
        #expect(rows.contains { $0.usedPercentage == 99.0 && $0.accountId == "orgB" })
        #expect(await poller.snapshot().activeAccountKey == "orgB")

        // Poll B now that it's active → appends, stamped B.
        if case .success = await poller.testLane(id: laneBId) {} else {
            Issue.record("expected success polling active org B")
        }
        rows = try await Self.fetchSampleSummaries(in: container)
        #expect(rows.contains { $0.usedPercentage == 77.0 && $0.accountId == "orgB" })

        // Switch back to A. Every row from every phase is still there, and a
        // read scoped to A sees exactly A's.
        await poller.setActiveAccount(id: "orgA")
        rows = try await Self.fetchSampleSummaries(in: container)
        #expect(rows.count == 3)
        #expect(rows.filter { $0.accountId == "orgA" }.map(\.usedPercentage) == [10.0])
        #expect(Set(rows.filter { $0.accountId == "orgB" }.map(\.usedPercentage)) == [99.0, 77.0])
        #expect(await poller.snapshot().activeAccountKey == "orgA")
    }

    /// The config file can lie, and the credential cannot.
    ///
    /// `ActiveAccountObserver` reads `oauthAccount` from `~/.claude.json`,
    /// which is correct while one Claude Code owns that file. Run several at
    /// once — all sharing `~/.claude`, the default — and a session started
    /// under another account rewrites the object with its own identity,
    /// undoing a switcher's work silently. Seen on a real machine: cswap
    /// logged three switches to one account, and Pacer saw two reversions to
    /// the other at times cswap logged nothing.
    ///
    /// The Claude Code keychain lane holds the credential that actually bills,
    /// and every successful poll names its org for free. It outranks the file.
    @Test("a keychain credential's own org outranks a stale config file")
    func keychainCredentialOutranksConfig() async throws {
        let container = try Self.makeContainer()
        let kc = KeychainOAuth(rawReader: { .success(Self.keychainBlob(token: "tokA")) })
        let held = EphemeralCredentialStore(OAuthCredential(
            accessToken: "tokB", expiresAt: Date().addingTimeInterval(3600), subscriptionType: nil
        ))
        let counter = AtomicCounter()
        let outcomes: [HTTPOutcome] = [
            .success(jsonBody: #"{"five_hour":{"utilization":10}}"#,
                     headers: ["anthropic-organization-id": "orgA"]),
        ]
        let transport: OAuthClient.Transport = { _ in
            try outcomes[min(counter.next(), outcomes.count - 1)].materialize()
        }
        let client = OAuthClient(keychain: kc, transport: transport,
                                 desktopEnabled: { false }, heldStore: held)
        let poller = OAuthPoller(client: client, container: container,
                                 configuration: .init(), clock: TestClock())

        _ = await poller.runOnce()                       // keychain token is orgA
        #expect(await poller.snapshot().activeAccountKey == "orgA")

        // A concurrent session rewrites the config to say orgB, and the
        // observer duly reports it.
        await poller.setActiveAccount(id: "orgB")
        #expect(await poller.snapshot().activeAccountKey == "orgB")

        // Next poll of the Claude Code credential says orgA, as it always did.
        // That is the account being billed, so it wins. (Polled explicitly:
        // under the test clock the lane's interval has not elapsed, and a
        // `.secondary` lane is swept on its own cadence anyway.)
        _ = await poller.testLane(id: OAuthPoller.laneId("tokA"))
        let after = await poller.snapshot()
        #expect(after.activeAccountKey == "orgA")
        #expect(after.misclassifiedLaneCount == 0)
    }

    /// The restart case, which is where this went wrong in the field.
    ///
    /// Lane classification is restored from persisted meta, and so is
    /// `activeAccountKey`. The two can disagree — restart while signed into a
    /// different account than the one last saved and the signed-in account's
    /// lane comes back marked `.secondary`. `setActiveAccount` used to return
    /// early whenever the id already matched, so nothing ever repaired it: the
    /// account the user was actually on stayed on the slow secondary sweep,
    /// and only a *change* of account could fix it.
    ///
    /// Measured 2026-09-09 before the fix: 18 minutes with no reading at all
    /// while the signed-in account climbed 82% → 97%, and 19 of the 21 polls
    /// in that window spent on the account the user was not using.
    @Test("re-asserting the same active account repairs stale lane classification")
    func reassertingActiveAccountRepairsLanes() async throws {
        let container = try Self.makeContainer()
        let kc = KeychainOAuth(rawReader: { .success(Self.keychainBlob(token: "tokA")) })
        let held = EphemeralCredentialStore(OAuthCredential(
            accessToken: "tokB", expiresAt: Date().addingTimeInterval(3600), subscriptionType: nil
        ))
        let counter = AtomicCounter()
        let outcomes: [HTTPOutcome] = [
            .success(jsonBody: #"{"five_hour":{"utilization":10}}"#,
                     headers: ["anthropic-organization-id": "orgA"]),
            .success(jsonBody: #"{"five_hour":{"utilization":99}}"#,
                     headers: ["anthropic-organization-id": "orgB"]),
        ]
        let transport: OAuthClient.Transport = { _ in
            try outcomes[min(counter.next(), outcomes.count - 1)].materialize()
        }
        let client = OAuthClient(keychain: kc, transport: transport,
                                 desktopEnabled: { false }, heldStore: held)
        let poller = OAuthPoller(client: client, container: container,
                                 configuration: .init(), clock: TestClock())

        _ = await poller.runOnce()   // orgA becomes active, its lane primary
        _ = await poller.runOnce()   // orgB polled, classified secondary
        #expect(await poller.snapshot().activeAccountKey == "orgA")

        // The login moves to orgB while this poller is not the one watching —
        // exactly what a restart looks like. `Account.isActive` is the store's
        // record and is what a fresh poller restores `activeAccountKey` from;
        // `TokenLaneMeta` still says orgA's lane is the primary one.
        try await MainActor.run {
            let ctx = ModelContext(container)
            for account in try ctx.fetch(FetchDescriptor<Account>()) {
                account.isActive = (account.id == "orgB")
            }
            try ctx.save()
        }

        // A second poller over the same store: active key from `Account`
        // (orgB), lane classification from `TokenLaneMeta` (orgA primary).
        // The two disagree, and nothing has changed to make them agree.
        let restarted = OAuthPoller(client: client, container: container,
                                    configuration: .init(), clock: TestClock())
        await restarted.setActiveAccount(id: "orgB")

        let after = await restarted.snapshot()
        #expect(after.activeAccountKey == "orgB")
        // orgB is signed in, so orgB's lane must be the primary one. Counting
        // primaries is not enough — before the fix there was still exactly one,
        // it was just the wrong lane: `setActiveAccount` returned early on a
        // matching id, leaving orgA primary and orgB on the slow sweep.
        #expect(after.misclassifiedLaneCount == 0)
        #expect(after.primaryLaneCount == 1)
    }

    /// Scoped `limits[]` history is per-account too, and this is the sharpest
    /// version of the mixing hazard: both accounts have a "Fable" weekly with
    /// the *same* identity string. Nothing but `accountId` tells the two rows
    /// apart, so a read that forgets the stamp silently reports one account's
    /// weekly cap as the other's.
    @Test func scopedLimitsStayIsolatedByAccountStamp() async throws {
        let container = try Self.makeContainer()
        let kc = KeychainOAuth(rawReader: { .success(Self.keychainBlob(token: "tokA")) })
        let held = EphemeralCredentialStore(OAuthCredential(
            accessToken: "tokB", expiresAt: Date().addingTimeInterval(3600), subscriptionType: nil
        ))
        let counter = AtomicCounter()
        func body(five: Int, fable: Int, org: String) -> HTTPOutcome {
            .success(
                jsonBody: """
                {"five_hour":{"utilization":\(five)},"limits":[{"kind":"weekly_scoped","group":"weekly","percent":\(fable),"severity":"normal","resets_at":"2026-07-13T09:59:59+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":true}]}
                """,
                headers: ["anthropic-organization-id": org])
        }
        let outcomes = [body(five: 10, fable: 40, org: "orgA"),   // A active
                        body(five: 99, fable: 88, org: "orgB"),   // B secondary
                        body(five: 77, fable: 66, org: "orgB")]   // B active
        let transport: OAuthClient.Transport = { _ in
            try outcomes[min(counter.next(), outcomes.count - 1)].materialize()
        }
        let client = OAuthClient(keychain: kc, transport: transport, desktopEnabled: { false }, heldStore: held)
        let poller = OAuthPoller(client: client, container: container, configuration: .init(), clock: TestClock())

        _ = await poller.runOnce()   // orgA active → Fable@40 stamped orgA
        _ = await poller.runOnce()   // orgB secondary → Fable@88 stamped orgB

        var scoped = try await Self.fetchScopedSummaries(in: container)
        #expect(scoped.count == 2)
        // One identity, two accounts, two different numbers.
        #expect(Set(scoped.map(\.identity)).count == 1)
        #expect(scoped.filter { $0.accountId == "orgA" }.map(\.percent) == [40])
        #expect(scoped.filter { $0.accountId == "orgB" }.map(\.percent) == [88])

        await poller.setActiveAccount(id: "orgB")
        if case .success = await poller.testLane(id: OAuthPoller.laneId("tokB")) {} else {
            Issue.record("expected success polling active org B")
        }
        scoped = try await Self.fetchScopedSummaries(in: container)
        #expect(scoped.filter { $0.accountId == "orgA" }.map(\.percent) == [40])
        #expect(Set(scoped.filter { $0.accountId == "orgB" }.map(\.percent)) == [88, 66])

        // Switching back changes nothing about either account's rows.
        await poller.setActiveAccount(id: "orgA")
        scoped = try await Self.fetchScopedSummaries(in: container)
        #expect(scoped.count == 3)
        #expect(scoped.allSatisfy { $0.accountId != nil })
    }

    /// A single-account user with pre-existing (accountId == nil) history
    /// keeps working after the additive migration: the first poll adopts
    /// those rows as the active account and appends to the same timeline.
    @Test func existingSingleAccountDataStillResolvesAfterMigration() async throws {
        let container = try Self.makeContainer()
        // Seed a legacy row with no accountId, as an existing user would have.
        try await MainActor.run {
            let ctx = ModelContext(container)
            ctx.insert(RateLimitSample(
                sampledAt: Date(timeIntervalSince1970: 1_000),
                window: "five_hour", usedPercentage: 33, resetsAt: nil, source: "oauth"
            ))
            try ctx.save()
        }
        let client = Self.sequencedClient([.success(
            jsonBody: #"{"five_hour":{"utilization":44}}"#,
            headers: ["anthropic-organization-id": "orgA"]
        )])
        let poller = OAuthPoller(client: client, container: container, configuration: .init(), clock: TestClock())

        if case .success = await poller.runOnce() {} else { Issue.record("expected success") }
        let rows = try await Self.fetchSampleSummaries(in: container)
        // Legacy 33% row still present alongside the new 44% row — one
        // continuous timeline, nothing reset or dropped.
        #expect(rows.contains { $0.usedPercentage == 33.0 })
        #expect(rows.contains { $0.usedPercentage == 44.0 })
    }

    // MARK: - Other failure paths

    @Test func transportErrorSurfacesAndCoolsLane() async throws {
        struct StubError: Error {}
        let container = try Self.makeContainer()
        let kc = KeychainOAuth(rawReader: { .success(Self.defaultKeychainBlob()) })
        let client = OAuthClient(keychain: kc, transport: { _ in throw StubError() }, desktopEnabled: { false })
        let poller = OAuthPoller(client: client, container: container, configuration: .init(), clock: TestClock())

        let outcome = await poller.runOnce()
        if case .transport = outcome {} else { Issue.record("expected transport, got \(outcome)") }
        // Lane cooled; single-lane user has nothing else to poll.
        #expect(await poller.runOnce() == .credentialsNotFound)
    }

    @Test func credsNotFoundWhenNoToken() async throws {
        let container = try Self.makeContainer()
        let kc = KeychainOAuth(rawReader: { .failure(.notFound) })
        let client = OAuthClient(keychain: kc, transport: { _ in (Data(), HTTPURLResponse()) }, desktopEnabled: { false })
        let poller = OAuthPoller(client: client, container: container, configuration: .init(), clock: TestClock())

        #expect(await poller.runOnce() == .credentialsNotFound)
    }

    // MARK: - start() / stop() lifecycle

    @Test func startStopIsIdempotent() async throws {
        let container = try Self.makeContainer()
        let client = Self.sequencedClient([.success(jsonBody: #"{"five_hour":{"utilization":1,"resets_at":""}}"#)])
        let poller = OAuthPoller(client: client, container: container, configuration: .init(), clock: TestClock())

        await poller.start()
        await poller.start()  // double-start is no-op
        await poller.stop()
        await poller.stop()   // double-stop is no-op
    }

    @Test func loopExitsCleanlyOnStop() async throws {
        let container = try Self.makeContainer()
        let client = Self.sequencedClient([.success(jsonBody: #"{"five_hour":{"utilization":1,"resets_at":""}}"#)])
        let poller = OAuthPoller(client: client, container: container, configuration: .init(), clock: TestClock())
        await poller.start()
        try await Task.sleep(nanoseconds: 50_000_000)  // 50ms of loop iterations
        await poller.stop()
        // Reaching here without hanging means the task fully unwound.
    }
}

// MARK: - Test scaffolding

/// Yieldable HTTP outcome — a 200 with a JSON body (and optional
/// response headers), or a non-2xx with optional headers and body.
enum HTTPOutcome: Sendable {
    case success(jsonBody: String, headers: [String: String] = [:])
    case status(_ code: Int, body: String = "{}", headers: [String: String] = [:])

    func materialize() throws -> (Data, HTTPURLResponse) {
        switch self {
        case .success(let body, let headers):
            let response = HTTPURLResponse(
                url: OAuthClient.endpoint,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            return (Data(body.utf8), response)
        case .status(let code, let body, let headers):
            let response = HTTPURLResponse(
                url: OAuthClient.endpoint,
                statusCode: code,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            return (Data(body.utf8), response)
        }
    }
}

/// Atomic monotonic counter used to walk the outcomes array. Plain
/// `var` capture is rejected by Swift 6 strict concurrency.
final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = -1
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}

/// Test clock: `now()` advances only via `advance(by:)`; `sleep` is a
/// `Task.yield` so the loop spins quickly. Cancellation is cooperative —
/// a sleep run after `Task.cancel()` throws, matching production.
final class TestClock: PollerClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date = Date(timeIntervalSince1970: 0)) {
        self.current = start
    }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }

    func sleep(seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        await Task.yield()
        try Task.checkCancellation()
    }
}
