import Foundation
import SwiftData
import Testing
@testable import PacerCore

// #241 and #192: a login change reaches every part of Pacer within about a
// second, and an account exists the moment its login is seen rather than when
// its first usage reading lands. Fictional orgs and addresses throughout.

// MARK: - Account on sight

@Suite("Account.ensure creates an account from a sighting")
@MainActor
struct AccountEnsureTests {

    private func context() throws -> ModelContext {
        ModelContext(try PacerStore.makeInMemoryContainer())
    }

    @Test("a missing account is created from what is known, with no readings")
    func createsFromSeed() throws {
        let context = try context()
        let seen = Date(timeIntervalSince1970: 1_790_000_000)
        let seed = Account.Seed(id: "org-new", organizationId: "org-new",
                                emailAddress: "new@example.com",
                                organizationName: "Globex", switcherSlot: 3)

        let (account, created) = Account.ensure(seed, in: context, now: seen)
        try context.save()

        #expect(created)
        #expect(account.id == "org-new")
        #expect(account.organizationId == "org-new")
        #expect(account.emailAddress == "new@example.com")
        #expect(account.organizationName == "Globex")
        #expect(account.switcherSlot == 3)
        #expect(account.isActive == false)
        #expect(account.firstSeenAt == seen)
        #expect(account.hasDerivedName)
        // No reading of any kind: "no reading yet" is a state, not a 0%.
        #expect(account.latestFiveHourPct == nil)
        #expect(account.latestSevenDayPct == nil)
        #expect(account.latestPolledAt == nil)
        #expect(try context.fetchCount(FetchDescriptor<RateLimitSample>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<UsageLimitSample>()) == 0)
    }

    @Test("an existing account is never overwritten")
    func neverOverwrites() throws {
        let context = try context()
        let original = Account(
            id: "org-a", organizationId: "org-a", displayName: "Work",
            isActive: true, firstSeenAt: .distantPast, lastSeenAt: .distantPast,
            subscriptionType: "max", emailAddress: "a@example.com",
            organizationName: "Acme", latestFiveHourPct: 42)
        original.switcherSlot = 1
        context.insert(original)
        try context.save()

        let (account, created) = Account.ensure(
            Account.Seed(id: "org-a", organizationId: "org-a",
                         emailAddress: "other@example.com", organizationName: "Initech",
                         switcherSlot: 9),
            in: context)

        #expect(!created)
        #expect(account.displayName == "Work")
        #expect(account.emailAddress == "a@example.com")
        #expect(account.organizationName == "Acme")
        #expect(account.switcherSlot == 1)
        #expect(account.isActive)
        #expect(account.latestFiveHourPct == 42)
        #expect(account.firstSeenAt == .distantPast)
    }

    @Test("ensuring twice makes one row, saved or not")
    func idempotent() throws {
        let context = try context()
        let seed = Account.Seed(id: "org-b", organizationId: "org-b")
        #expect(Account.ensure(seed, in: context).created)
        // Before a save: the pending insert is found, not duplicated.
        #expect(!Account.ensure(seed, in: context).created)
        try context.save()
        #expect(!Account.ensure(seed, in: context).created)
        #expect(try context.fetchCount(FetchDescriptor<Account>()) == 1)
    }

    @Test("a seed from the config carries its identity; one from cswap its slot")
    func seedsFromSources() {
        let observed = ActiveAccountObserver.Observation(
            organizationId: "org-c", accountUuid: "u-c", emailAddress: "c@example.com",
            organizationName: "Umbrella", rootPath: nil)
        #expect(Account.Seed(observed) == Account.Seed(
            id: "org-c", organizationId: "org-c", emailAddress: "c@example.com",
            organizationName: "Umbrella"))
        let listed = SwitcherUsageCache.ListedAccount(
            organizationId: "org-d", emailAddress: "d@example.com", slot: 2)
        #expect(Account.Seed(listed) == Account.Seed(
            id: "org-d", organizationId: "org-d", emailAddress: "d@example.com", switcherSlot: 2))
    }
}

// MARK: - Change detection, as pure functions

@Suite("Login change detection")
struct LoginChangeDetectionTests {

    /// A config shaped like Claude Code's: large, with `oauthAccount` among
    /// many other top-level keys.
    private func config(org: String?, account: String? = "acct-1", extra: String = "") -> Data {
        let oauth: String
        if let org {
            oauth = #"{"accountUuid":"\#(account ?? "")","emailAddress":"x@example.com","organizationUuid":"\#(org)","organizationName":"Acme {braces} \"quoted\""}"#
        } else {
            oauth = "null"
        }
        let projects = (0..<200).map { #""/tmp/p\#($0)":{"history":[{"display":"hello"}]}"# }
            .joined(separator: ",")
        return Data(#"{"numStartups":12,"projects":{\#(projects)},\#(extra)"oauthAccount" : \#(oauth),"theme":"dark"}"#.utf8)
    }

    @Test("the identity comes out of a large config without parsing the rest")
    func extractsIdentity() {
        let identity = ConfigLoginIdentity.extract(from: config(org: "org-a"))
        #expect(identity == ConfigLoginIdentity(organizationId: "org-a", accountUuid: "acct-1"))
    }

    @Test("a rewrite that keeps the login is no change; a different org is")
    func diffing() {
        let first = ConfigLoginIdentity.extract(from: config(org: "org-a"))
        let rewritten = ConfigLoginIdentity.extract(from: config(org: "org-a", extra: #""tipsHistory":{"x":3},"#))
        let switched = ConfigLoginIdentity.extract(from: config(org: "org-b"))
        let sameOrgOtherUser = ConfigLoginIdentity.extract(from: config(org: "org-a", account: "acct-2"))
        #expect(first == rewritten)
        #expect(first != switched)
        #expect(first != sameOrgOtherUser)
    }

    @Test("logged out, truncated, or not JSON reads as unknown, never as a login")
    func unknowns() {
        #expect(ConfigLoginIdentity.extract(from: config(org: nil)) == nil)
        let whole = config(org: "org-a")
        #expect(ConfigLoginIdentity.extract(from: whole.prefix(whole.count - 60)) == nil)
        #expect(ConfigLoginIdentity.extract(from: Data("not json".utf8)) == nil)
        #expect(ConfigLoginIdentity.extract(from: Data(#"{"oauthAccount":{}}"#.utf8)) == nil)
    }

    @Test("the key quoted inside someone's prompt is not the login")
    func ignoresEscapedKey() {
        let data = Data(#"{"history":"pasted \"oauthAccount\":{\"organizationUuid\":\"org-evil\"}","oauthAccount":{"organizationUuid":"org-real"}}"#.utf8)
        #expect(ConfigLoginIdentity.extract(from: data)?.organizationId == "org-real")
    }

    @Test("the keychain item's modification stamp is read from security's attribute dump")
    func keychainStamp() {
        let dump = """
        keychain: "/Users/someone/Library/Keychains/login.keychain-db"
        version: 512
        class: "genp"
        attributes:
            0x00000007 <blob>="Claude Code-credentials"
            "acct"<blob>="someone"
            "cdat"<timedate>=0x32303236303130313132303030305A00  "20260101120000Z\\000"
            "mdat"<timedate>=0x32303236313030393132333435365A00  "20261009123456Z\\000"
            "svce"<blob>="Claude Code-credentials"
        """
        #expect(KeychainItemStamp.modificationStamp(inSecurityOutput: dump) == "20261009123456Z")
        #expect(KeychainItemStamp.modificationStamp(inSecurityOutput: "") == nil)
        #expect(KeychainItemStamp.modificationStamp(inSecurityOutput: "attributes:\n  \"acct\"<blob>=\"x\"") == nil)
    }

    @Test("cswap's roster lists every account, with or without a reading")
    func switcherRoster() {
        let json = """
        {"schemaVersion": 2, "accounts": {
          "1": {"email": "a@example.com", "organizationUuid": "org-work",
                "fetchedAt": 1788889000.5, "nextPollAt": 1788889300,
                "lastGood": {"five_hour": {"pct": 34.0, "resets_at": null}}},
          "2": {"email": "b@example.com", "organizationUuid": "org-new",
                "fetchedAt": 0, "lastError": "http-429", "lastGood": null},
          "3": {"email": "", "organizationUuid": "org-quiet"},
          "x": {"organizationUuid": ""}}}
        """
        let contents = SwitcherUsageCache.parse(Data(json.utf8))
        #expect(contents.accounts == [
            .init(organizationId: "org-work", emailAddress: "a@example.com", slot: 1),
            .init(organizationId: "org-new", emailAddress: "b@example.com", slot: 2),
            .init(organizationId: "org-quiet", emailAddress: nil, slot: 3),
        ])
        #expect(contents.readings.map(\.organizationId) == ["org-work"])
        #expect(SwitcherUsageCache.parse(Data("junk".utf8)) == .empty)
    }
}

// MARK: - End to end: a login Pacer has never seen

/// A keychain whose token a test can change underneath the poller.
private final class KeychainBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _token: String
    private var _reads = 0
    init(_ token: String) { _token = token }
    /// How many times the keychain's secret was read — one per discovery.
    var reads: Int { lock.lock(); defer { lock.unlock() }; return _reads }
    var token: String {
        get { lock.lock(); defer { lock.unlock() }; return _token }
        set { lock.lock(); _token = newValue; lock.unlock() }
    }
    func blob() -> Data {
        lock.lock(); _reads += 1; lock.unlock()
        return try! JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": [
                "accessToken": token,
                "expiresAt": Int64(Date().addingTimeInterval(3600).timeIntervalSince1970) * 1000,
            ]
        ])
    }
}

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    func hit() { lock.lock(); _count += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
}

@Suite("Following a login change without a poll", .serialized)
@ScanActor
struct LoginPassTests {

    private struct Rig {
        let home: URL
        let container: ModelContainer
        let coordinator: ScanCoordinator
        let keychain: KeychainBox
        let requests: RequestCounter
    }

    /// A coordinator with a private home, an in-memory store and a fake
    /// keychain. The transport names the org from the token (`tok-a` →
    /// `org-a`) and counts requests, so a test can tell a poll happened.
    private func rig(
        token: String,
        stamp: @escaping @Sendable () -> String? = { nil },
        recheckDelay: TimeInterval = 2
    ) async throws -> Rig {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pacer-login-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let keychain = KeychainBox(token)
        let requests = RequestCounter()
        let transport: OAuthClient.Transport = { request in
            requests.hit()
            let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
            let org = "org-" + String(auth.split(separator: "-").last ?? "")
            let response = HTTPURLResponse(
                url: OAuthClient.endpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["anthropic-organization-id": org])!
            return (Data(#"{"five_hour":{"utilization":10}}"#.utf8), response)
        }
        let client = OAuthClient(
            keychain: KeychainOAuth(rawReader: { .success(keychain.blob()) }),
            transport: transport, desktopEnabled: { false })
        let container = try PacerStore.makeInMemoryContainer()
        let coordinator = ScanCoordinator(
            container: container,
            configuration: .init(watcherMode: .manual, probeStatsCache: false),
            resolver: ClaudePathResolver(environment: [:], homeDirectory: home),
            oauthClient: client,
            homeDirectory: home,
            keychainStamp: stamp,
            fastRejectRecheckDelay: recheckDelay)
        // `UsageScope.shared` is process-wide and other suites assert on it
        // in parallel; what these tests check is the store, which is what the
        // mirror is reconciled from.
        await coordinator.oauthPollerForTesting?.stopPublishingScopeForTesting()
        return Rig(home: home, container: container, coordinator: coordinator,
                   keychain: keychain, requests: requests)
    }

    private func writeConfig(_ home: URL, org: String, email: String) throws {
        let url = home.appendingPathComponent(".claude.json")
        try #"{"numStartups":3,"oauthAccount":{"organizationUuid":"\#(org)","accountUuid":"u-\#(org)","emailAddress":"\#(email)","organizationName":"\#(org) Inc"}}"#
            .write(to: url, atomically: true, encoding: .utf8)
        // A write is "after" any earlier keychain read only if its mtime is;
        // put it a moment in the past of now but after everything before.
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private struct AccountState: Sendable, Equatable {
        let id: String
        let isActive: Bool
        let email: String?
        let fiveHour: Double?
    }

    private func accounts(_ container: ModelContainer) async -> [AccountState] {
        await MainActor.run {
            let rows = (try? ModelContext(container).fetch(
                FetchDescriptor<Account>(sortBy: [SortDescriptor(\.id)]))) ?? []
            return rows.map { AccountState(id: $0.id, isActive: $0.isActive,
                                           email: $0.emailAddress, fiveHour: $0.latestFiveHourPct) }
        }
    }

    private func openLogin(_ container: ModelContainer) -> String? {
        let context = ModelContext(container)
        let open = (try? context.fetch(FetchDescriptor<AccountActivation>(
            predicate: #Predicate { $0.endedAt == nil && $0.rootPath == nil }))) ?? []
        return open.first?.accountId
    }

    @Test("a never-seen login is an active account at once — no poll, no reading")
    func neverSeenLoginIsActiveImmediately() async throws {
        let rig = try await rig(token: "tok-a")
        try writeConfig(rig.home, org: "org-a", email: "a@example.com")
        await rig.coordinator.followLoginChange(.config)

        // The switch: Claude Code writes a token Pacer has never polled and
        // names an org Pacer has no row for.
        try await Task.sleep(nanoseconds: 20_000_000)
        rig.keychain.token = "tok-new"
        try writeConfig(rig.home, org: "org-new", email: "new@example.com")
        await rig.coordinator.followLoginChange(.config)

        let rows = await accounts(rig.container)
        #expect(rows.map(\.id) == ["org-a", "org-new"])
        let new = try #require(rows.first { $0.id == "org-new" })
        #expect(new.isActive)
        #expect(new.email == "new@example.com")
        #expect(new.fiveHour == nil)                       // no reading yet, not 0%
        #expect(rows.filter(\.isActive).map(\.id) == ["org-new"])
        #expect(openLogin(rig.container) == "org-new")    // the trail moved and was saved
        #expect(rig.requests.count == 0, "activation must not wait on a usage poll")
        let poller = try #require(rig.coordinator.oauthPollerForTesting)
        #expect(await poller.snapshot().activeAccountKey == "org-new")
    }

    @Test("a stale config write is still vetoed by a keychain token that resolves elsewhere")
    func staleConfigStillVetoed() async throws {
        let rig = try await rig(token: "tok-a")
        let poller = try #require(rig.coordinator.oauthPollerForTesting)
        // The keychain's token is known to be org-a's: one real poll.
        _ = await poller.runOnce()
        #expect(rig.requests.count == 1)
        try writeConfig(rig.home, org: "org-a", email: "a@example.com")
        await rig.coordinator.followLoginChange(.config)
        #expect(openLogin(rig.container) == "org-a")

        // Another Claude Code process writes back an identity it was holding.
        // The keychain did not move.
        try await Task.sleep(nanoseconds: 20_000_000)
        try writeConfig(rig.home, org: "org-b", email: "b@example.com")
        await rig.coordinator.followLoginChange(.config)

        #expect(openLogin(rig.container) == "org-a")
        let rows = await accounts(rig.container)
        #expect(rows.filter(\.isActive).map(\.id) == ["org-a"])
        #expect(!rows.contains { $0.id == "org-b" }, "a rejected login is not provisioned")
        #expect(await poller.snapshot().activeAccountKey == "org-a")
    }

    @Test("a keychain change re-judges a config that was rejected against the old token")
    func keychainMoveRejudges() async throws {
        let rig = try await rig(token: "tok-a")
        let poller = try #require(rig.coordinator.oauthPollerForTesting)
        _ = await poller.runOnce()
        try writeConfig(rig.home, org: "org-a", email: "a@example.com")
        await rig.coordinator.followLoginChange(.config)

        // cswap wrote the config first: read against the old token, rejected.
        try await Task.sleep(nanoseconds: 20_000_000)
        try writeConfig(rig.home, org: "org-c", email: "c@example.com")
        await rig.coordinator.followLoginChange(.config)
        #expect(openLogin(rig.container) == "org-a")

        // Then its keychain write lands. The file has not changed since.
        rig.keychain.token = "tok-c"
        await rig.coordinator.followLoginChange(.keychain)

        #expect(openLogin(rig.container) == "org-c")
        let rows = await accounts(rig.container)
        #expect(rows.filter(\.isActive).map(\.id) == ["org-c"])
    }

    @Test("cswap's roster provisions every listed account; readings only where it has them")
    func switcherRosterProvisions() async throws {
        let rig = try await rig(token: "tok-a")
        let cache = SwitcherUsageCache.defaultURL(homeDirectory: rig.home)
        try FileManager.default.createDirectory(
            at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fetched = Date().addingTimeInterval(-30).timeIntervalSince1970
        try """
        {"schemaVersion": 2, "accounts": {
          "1": {"email": "a@example.com", "organizationUuid": "org-a", "fetchedAt": \(fetched),
                "lastGood": {"five_hour": {"pct": 34.0, "resets_at": null},
                             "seven_day": {"pct": 7.0, "resets_at": null}}},
          "2": {"email": "b@example.com", "organizationUuid": "org-b", "fetchedAt": 0}}}
        """.write(to: cache, atomically: true, encoding: .utf8)

        await rig.coordinator.followLoginChange(.switcher)
        // Twice: an unchanged roster provisions nothing new and replays nothing.
        await rig.coordinator.followLoginChange(.switcher)

        let rows = await accounts(rig.container)
        #expect(rows.map(\.id) == ["org-a", "org-b"])
        #expect(rows.first { $0.id == "org-a" }?.fiveHour == 34)
        #expect(rows.first { $0.id == "org-b" }?.fiveHour == nil)
        #expect(rows.first { $0.id == "org-b" }?.email == "b@example.com")
        let samples = await MainActor.run {
            (try? ModelContext(rig.container).fetch(FetchDescriptor<RateLimitSample>()))?
                .map { $0.accountId ?? "" } ?? []
        }
        #expect(samples.sorted() == ["org-a", "org-a"])   // 5h + 7d, once
        #expect(rig.requests.count == 0)
    }
}


// MARK: - #243: a flip back to an already-rejected identity

/// The keychain item's stamp, which a test moves by hand.
private final class StampBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?
    init(_ value: String?) { _value = value }
    var value: String? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

@Suite("Fast reject of an already-rejected identity (#243)", .serialized)
@ScanActor
struct FlipFastRejectTests {

    private struct Rig {
        let home: URL
        let container: ModelContainer
        let coordinator: ScanCoordinator
        let keychain: KeychainBox
        let poller: OAuthPoller
    }

    private func rig(stamp: StampBox) async throws -> Rig {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pacer-flip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let keychain = KeychainBox("tok-a")
        let transport: OAuthClient.Transport = { request in
            let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
            let org = "org-" + String(auth.split(separator: "-").last ?? "")
            let response = HTTPURLResponse(
                url: OAuthClient.endpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["anthropic-organization-id": org])!
            return (Data(#"{"five_hour":{"utilization":10}}"#.utf8), response)
        }
        let client = OAuthClient(
            keychain: KeychainOAuth(rawReader: { .success(keychain.blob()) }),
            transport: transport, desktopEnabled: { false })
        let container = try PacerStore.makeInMemoryContainer()
        // A huge recheck delay: the real timer never fires inside a test, and
        // the follow-up is driven by hand so nothing sleeps.
        let coordinator = ScanCoordinator(
            container: container,
            configuration: .init(watcherMode: .manual, probeStatsCache: false),
            resolver: ClaudePathResolver(environment: [:], homeDirectory: home),
            oauthClient: client,
            homeDirectory: home,
            keychainStamp: { stamp.value },
            fastRejectRecheckDelay: 3600,
            // No throttle between full reads, so a test can tell a full read
            // from one that was skipped rather than merely deferred.
            loginPassCredentialCheckInterval: 0)
        let poller = try #require(coordinator.oauthPollerForTesting)
        await poller.stopPublishingScopeForTesting()
        return Rig(home: home, container: container, coordinator: coordinator,
                   keychain: keychain, poller: poller)
    }

    private func writeConfig(_ home: URL, org: String) async throws {
        // Distinct mtimes: each flip must read as a new write.
        try await Task.sleep(nanoseconds: 20_000_000)
        let url = home.appendingPathComponent(".claude.json")
        try #"{"oauthAccount":{"organizationUuid":"\#(org)","accountUuid":"u-\#(org)","emailAddress":"\#(org)@example.com","organizationName":"\#(org) Inc"}}"#
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private func openLogin(_ container: ModelContainer) -> String? {
        let open = (try? ModelContext(container).fetch(FetchDescriptor<AccountActivation>(
            predicate: #Predicate { $0.endedAt == nil && $0.rootPath == nil }))) ?? []
        return open.first?.accountId
    }

    /// Signed into A with a poll behind it, then B written back stale and
    /// rejected by a full read: the state every test starts from.
    private func rejectB(_ rig: Rig) async throws {
        _ = await rig.poller.runOnce()
        try await writeConfig(rig.home, org: "org-a")
        await rig.coordinator.followLoginChange(.config)
        #expect(openLogin(rig.container) == "org-a")
        let before = rig.keychain.reads
        try await writeConfig(rig.home, org: "org-b")
        await rig.coordinator.followLoginChange(.config)
        #expect(openLogin(rig.container) == "org-a")
        #expect(rig.keychain.reads == before + 1, "the first rejection is a full read")
        #expect(rig.coordinator.rememberedRejectionForTesting == "org-b")
    }

    @Test("A, B, A, B with a constant stamp and the keychain on A is one discovery")
    func flipStorm() async throws {
        let rig = try await rig(stamp: StampBox("S1"))
        try await rejectB(rig)
        let afterFirst = rig.keychain.reads

        for _ in 0..<3 {
            try await writeConfig(rig.home, org: "org-a")
            await rig.coordinator.followLoginChange(.config)
            try await writeConfig(rig.home, org: "org-b")
            await rig.coordinator.followLoginChange(.config)
        }

        #expect(rig.keychain.reads == afterFirst, "no further discovery for the same stale identity")
        #expect(openLogin(rig.container) == "org-a")
        #expect(rig.coordinator.fastRejectFollowUpPendingForTesting, "one follow-up, coalesced")
    }

    @Test("config first, then the keychain write and its watch event: accepted")
    func configFirstKeychainEvent() async throws {
        let stamp = StampBox("S1")
        let rig = try await rig(stamp: stamp)
        try await rejectB(rig)

        // cswap writes the config naming B; the keychain has not moved yet.
        try await writeConfig(rig.home, org: "org-a")
        await rig.coordinator.followLoginChange(.config)
        try await writeConfig(rig.home, org: "org-b")
        await rig.coordinator.followLoginChange(.config)
        #expect(openLogin(rig.container) == "org-a")

        // Its keychain write lands and the watcher says so.
        rig.keychain.token = "tok-b"
        stamp.value = "S2"
        await rig.coordinator.followLoginChange(.keychain)

        #expect(openLogin(rig.container) == "org-b")
        #expect(rig.coordinator.rememberedRejectionForTesting == nil)
    }

    @Test("config first, keychain event never arrives: the follow-up check accepts")
    func configFirstNoKeychainEvent() async throws {
        let stamp = StampBox("S1")
        let rig = try await rig(stamp: stamp)
        try await rejectB(rig)

        try await writeConfig(rig.home, org: "org-a")
        await rig.coordinator.followLoginChange(.config)
        try await writeConfig(rig.home, org: "org-b")
        await rig.coordinator.followLoginChange(.config)
        #expect(openLogin(rig.container) == "org-a")
        #expect(rig.coordinator.fastRejectFollowUpPendingForTesting)

        // The keychain moves and no event is delivered.
        rig.keychain.token = "tok-b"
        stamp.value = "S2"
        await rig.coordinator.runFastRejectFollowUp()

        #expect(openLogin(rig.container) == "org-b")
        #expect(!rig.coordinator.fastRejectFollowUpPendingForTesting)
        await rig.coordinator.stop()
    }

    @Test("an unmoved stamp at the follow-up check does nothing more")
    func followUpUnchangedStamp() async throws {
        let rig = try await rig(stamp: StampBox("S1"))
        try await rejectB(rig)
        try await writeConfig(rig.home, org: "org-a")
        await rig.coordinator.followLoginChange(.config)
        try await writeConfig(rig.home, org: "org-b")
        await rig.coordinator.followLoginChange(.config)
        let reads = rig.keychain.reads

        await rig.coordinator.runFastRejectFollowUp()

        #expect(rig.keychain.reads == reads)
        #expect(rig.coordinator.rememberedRejectionForTesting == "org-b")
        #expect(openLogin(rig.container) == "org-a")
        await rig.coordinator.stop()
    }

    @Test("an unreadable stamp disables the fast path")
    func nilStamp() async throws {
        let rig = try await rig(stamp: StampBox(nil))
        _ = await rig.poller.runOnce()
        try await writeConfig(rig.home, org: "org-a")
        await rig.coordinator.followLoginChange(.config)
        try await writeConfig(rig.home, org: "org-b")
        await rig.coordinator.followLoginChange(.config)
        #expect(openLogin(rig.container) == "org-a")

        #expect(rig.coordinator.rememberedRejectionForTesting == nil, "nothing is remembered without a stamp")
        try await writeConfig(rig.home, org: "org-a")
        await rig.coordinator.followLoginChange(.config)
        try await writeConfig(rig.home, org: "org-b")
        await rig.coordinator.followLoginChange(.config)
        #expect(!rig.coordinator.fastRejectFollowUpPendingForTesting)
        await rig.coordinator.stop()
    }

    @Test("accepting an identity forgets the rejection; a later identity takes the full path")
    func clearedOnAccept() async throws {
        let rig = try await rig(stamp: StampBox("S1"))
        try await rejectB(rig)

        // A real switch to B that reaches Pacer through a read the scan path
        // would take, not a keychain event: the pass accepts it on sight.
        rig.keychain.token = "tok-b"
        await rig.poller.refreshSignedInCredential()   // unresolved: no verdict, accepts
        try await writeConfig(rig.home, org: "org-b")
        await rig.coordinator.followLoginChange(.config)
        #expect(openLogin(rig.container) == "org-b")
        #expect(rig.coordinator.rememberedRejectionForTesting == nil)
        _ = await rig.poller.runOnce()                 // tok-b now resolves to org-b

        // C names someone the keychain does not hold: a full read, not a fast reject.
        let before = rig.keychain.reads
        try await writeConfig(rig.home, org: "org-c")
        await rig.coordinator.followLoginChange(.config)
        #expect(rig.keychain.reads == before + 1)
        #expect(openLogin(rig.container) == "org-b")
        #expect(rig.coordinator.rememberedRejectionForTesting == "org-c")
        await rig.coordinator.stop()
    }
}
