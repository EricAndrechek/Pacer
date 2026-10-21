import Foundation
import SwiftData
import Testing
@testable import PacerCore

// #245: "active" is a set of (account, client) pairs. Fictional ids throughout.

private let cliOrg = "11111111-1111-4111-8111-111111111111"
private let workOrg = "22222222-2222-4222-8222-222222222222"
private let desktopUser = "44444444-4444-4444-8444-444444444444"
private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

private func tempDirectory(_ label: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pacer-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Clients on accounts")
struct AccountClientsTests {

    private func clients() -> AccountClients {
        AccountClients.build(
            cliAccount: cliOrg, cliSince: t0.addingTimeInterval(-3_600),
            desktop: ["/d/Claude-Work": [workOrg: t0.addingTimeInterval(-10 * 60)],
                      "/d/Claude": [cliOrg: t0.addingTimeInterval(-2 * 3_600)]],
            installLabels: ["/d/Claude-Work": "Desktop · Work", "/d/Claude": "Desktop · Claude"],
            profiles: ["/p/1-work": workOrg],
            profileActivity: [:])
    }

    @Test("the CLI is active while it is the login; a Desktop for 30 minutes after its last session")
    func activeWindows() {
        let c = clients()
        #expect(c.entries.first?.kind == .cli)
        #expect(c.active(on: cliOrg, at: t0).map(\.label) == ["CLI"])
        #expect(c.active(on: workOrg, at: t0).map(\.label) == ["Desktop · Work"])
        #expect(c.activeAccountIds(at: t0) == [cliOrg, workOrg])
        // Its 30 minutes run out 20 minutes from now; that is the next change.
        #expect(c.nextExpiry(after: t0) == t0.addingTimeInterval(20 * 60))
        let later = t0.addingTimeInterval(21 * 60)
        #expect(c.activeAccountIds(at: later) == [cliOrg])
        #expect(c.activePairs(at: t0) != c.activePairs(at: later))
    }

    @Test("a pinned profile counts only after it writes")
    func profiles() {
        let quiet = clients()
        #expect(!quiet.active(on: workOrg, at: t0).contains { $0.kind == .profile })
        let writing = AccountClients.build(
            cliAccount: nil, cliSince: nil, desktop: [:], installLabels: [:],
            profiles: ["/p/1-work": workOrg], profileActivity: ["/p/1-work": t0.addingTimeInterval(-60)])
        #expect(writing.active(on: workOrg, at: t0).map(\.label) == ["Profile · 1-work"])
    }

    @Test("one account on one install looks like the login and nothing else")
    func singleAccountUnchanged() {
        let c = AccountClients.build(
            cliAccount: cliOrg, cliSince: t0, desktop: ["/d/Claude": [cliOrg: t0]],
            installLabels: ["/d/Claude": "Desktop"], profiles: [:], profileActivity: [:])
        // Both are on the one account; the set of active accounts is that one.
        #expect(c.activeAccountIds(at: t0) == [cliOrg])
    }
}

@Suite("What the screens show for clients")
struct AccountClientsPresentationTests {
    private let clients = AccountClients.build(
        cliAccount: cliOrg, cliSince: t0,
        desktop: ["/d/Claude-Work": [workOrg: t0.addingTimeInterval(-60)]],
        installLabels: ["/d/Claude-Work": "Desktop · Work"], profiles: [:], profileActivity: [:])

    @Test("the menu groups only with more than one active account, or concurrent profiles")
    func menuGrouping() {
        let all = [cliOrg, workOrg, "33333333-3333-4333-8333-333333333333"]
        // Desktop on a second account: the two active ones, in order.
        #expect(AccountClients.menuGroupAccounts(
            all: all, concurrent: false, active: clients.activeAccountIds(at: t0)) == [cliOrg, workOrg])
        // One active account (the single-account user, or Desktop timed out): no groups.
        #expect(AccountClients.menuGroupAccounts(all: all, concurrent: false, active: [cliOrg]) == nil)
        // Concurrent profiles keep every account, as before.
        #expect(AccountClients.menuGroupAccounts(all: all, concurrent: true, active: [cliOrg]) == all)
    }

    @Test("an alert names the client only where the CLI is not")
    func alertLabels() {
        #expect(clients.alertLabel("work", account: workOrg, at: t0) == "work (Desktop · Work)")
        #expect(clients.alertLabel("personal", account: cliOrg, at: t0) == "personal")
        // Desktop's 30 minutes over: the plain name again.
        #expect(clients.alertLabel("work", account: workOrg, at: t0.addingTimeInterval(3_600)) == "work")
    }
}

@Suite("Desktop's activity per install and account")
struct DesktopActivityTests {

    @Test("the newest lastActivityAt under each account folder, else the record's date")
    func newestRecord() throws {
        let data = try tempDirectory("desktop-activity")
        defer { try? FileManager.default.removeItem(at: data) }
        let folder = data.appendingPathComponent("claude-code-sessions")
            .appendingPathComponent(desktopUser).appendingPathComponent(workOrg)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let older = Int64(t0.timeIntervalSince1970 * 1000) - 600_000
        let newer = Int64(t0.timeIntervalSince1970 * 1000)
        try #"{"sessionId":"local_1","cliSessionId":"\#(UUID().uuidString.lowercased())","lastActivityAt":\#(older)}"#
            .write(to: folder.appendingPathComponent("local_1.json"), atomically: true, encoding: .utf8)
        // Agent mode pretty-prints.
        try "{\n  \"cliSessionId\": \"\(UUID().uuidString.lowercased())\",\n  \"lastActivityAt\": \(newer)\n}"
            .write(to: folder.appendingPathComponent("local_2.json"), atomically: true, encoding: .utf8)

        let directory = DesktopSessionDirectory(dataDirectories: [data])
        let install = data.canonicalPathURL.path
        #expect(directory.activity[install]?[workOrg] == t0)

        // No field at all: the record's own date stands in, never earlier.
        let bare = folder.appendingPathComponent("local_3.json")
        try #"{"cliSessionId":"\#(UUID().uuidString.lowercased())"}"#.write(to: bare, atomically: true, encoding: .utf8)
        let stamp = t0.addingTimeInterval(120)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: bare.path)
        directory.refresh()
        let seen = try #require(directory.activity[install]?[workOrg])
        #expect(abs(seen.timeIntervalSince(stamp)) < 1)
    }
}

@Suite("Clients in the HTTP API")
@ScanActor
struct AccountClientsAPITests {

    @Test("/v1/accounts lists each account's clients; /metrics names them for two accounts only")
    func accountsAndMetrics() throws {
        let container = try PacerStore.makeInMemoryContainer()
        let context = ModelContext(container)
        for id in [cliOrg, workOrg] {
            _ = Account.ensure(Account.Seed(id: Account.key(forOrg: id), organizationId: id), in: context)
        }
        try context.save()
        let clients = AccountClients.build(
            cliAccount: cliOrg, cliSince: t0,
            desktop: ["/d/Claude-Work": [workOrg: t0.addingTimeInterval(-60)]],
            installLabels: ["/d/Claude-Work": "Desktop · Work"], profiles: [:], profileActivity: [:])

        let list = PacerAccountsBuilder.list(context: context, now: t0, clients: clients)
        let work = try #require(list.accounts.first { $0.id == workOrg })
        #expect(work.clients.map(\.label) == ["Desktop · Work"])
        #expect(work.clients.first?.active == true)
        #expect(work.clients.first?.activeUntil == t0.addingTimeInterval(29 * 60))
        let cli = try #require(list.accounts.first { $0.id == cliOrg })
        #expect(cli.clients.map(\.kind) == ["cli"])
        #expect(cli.clients.first?.activeUntil == nil)

        let change = PacerClientsChange(clients, now: t0)
        #expect(change.active.map(\.kind) == ["cli", "desktop"])
        #expect(try change.encodedJSON().contains("\"label\" : \"Desktop · Work\""))
        #expect(PacerMetrics.instanceTag(work.clients[0]).count == 8)
        #expect(PacerMetrics.instanceTag(cli.clients[0]) == "cli")
    }
}
