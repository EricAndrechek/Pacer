import Foundation
import SwiftData
import Testing
@testable import PacerCore

// #192: `/v1/stream` pushes an `account` event the moment the active login
// changes. The server is in the app target and has no test seam of its own;
// what a client relies on — the payload, its framing, and when it fires — is
// here. Fictional ids throughout.

@Suite("The /v1/stream account event")
struct AccountStreamEventTests {

    @Test("encodes as {activeAccountId, since}, ISO-8601, keys sorted")
    func encoding() throws {
        let change = PacerAccountChange(
            activeAccountId: "org-new", since: Date(timeIntervalSince1970: 1_791_547_200))
        let json = try change.encodedJSON()
        #expect(json == """
        {
          "activeAccountId" : "org-new",
          "since" : "2026-10-09T12:00:00Z"
        }
        """)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(PacerAccountChange.self, from: Data(json.utf8)) == change)
        #expect(PacerAccountChange.eventName == "account")
    }

    @Test("framed as one SSE event, one data line per payload line")
    func framing() throws {
        let json = try PacerAccountChange(
            activeAccountId: "org-new", since: Date(timeIntervalSince1970: 1_791_547_200)).encodedJSON()
        let frame = PacerSSE.frame(event: PacerAccountChange.eventName, data: json)
        #expect(frame == """
        event: account
        data: {
        data:   "activeAccountId" : "org-new",
        data:   "since" : "2026-10-09T12:00:00Z"
        data: }


        """)
        // What a client does with it: join the data lines back.
        let rejoined = frame.split(separator: "\n")
            .filter { $0.hasPrefix("data: ") }
            .map { $0.dropFirst("data: ".count) }
            .joined(separator: "\n")
        #expect(rejoined == json)
    }

    @Test("fires on a change only — not on the same login re-asserted, not on unknown")
    func detector() {
        var detector = PacerAccountChange.Detector(last: "org-a")
        let at = Date(timeIntervalSince1970: 1_791_547_200)
        #expect(detector.observe("org-a", since: at) == nil)      // republished at launch
        #expect(detector.observe(nil, since: at) == nil)          // not known yet
        #expect(detector.observe("org-b", since: at)
                == PacerAccountChange(activeAccountId: "org-b", since: at))
        #expect(detector.observe("org-b", since: at) == nil)
        #expect(detector.observe("org-a", since: at)?.activeAccountId == "org-a")

        var fresh = PacerAccountChange.Detector(last: nil)
        #expect(fresh.observe("org-a", since: at)?.activeAccountId == "org-a")
    }
    @Test("posted and read back through NotificationCenter")
    func notificationRoundTrip() {
        let change = PacerAccountChange(
            activeAccountId: "org-new", since: Date(timeIntervalSince1970: 1_791_547_200))
        let sender = NSObject()
        let heard = Heard()
        let observer = NotificationCenter.default.addObserver(
            forName: PacerAccountChange.didActivate, object: sender, queue: nil
        ) { heard.record(PacerAccountChange($0)) }
        defer { NotificationCenter.default.removeObserver(observer) }
        change.post(from: sender)
        #expect(heard.changes == [change])
        #expect(PacerAccountChange(Notification(name: PacerAccountChange.didActivate)) == nil)
    }

    /// #254: the stream used to hear of a switch through `UsageScope`, three
    /// main-actor hops after the poller had already decided, so the event
    /// waited out every redraw the switch caused. The poller now announces it
    /// itself, from its own executor, and only for a real change to a row
    /// the store knows.
    @Test("a switch is announced by the poller, off the main thread, once")
    func pollerAnnouncesSwitch() async throws {
        let container = try PacerStore.makeInMemoryContainer()
        try await MainActor.run {
            let context = ModelContext(container)
            for (id, active) in [("org-254-a", true), ("org-254-b", false)] {
                context.insert(Account(id: id, organizationId: id, displayName: id, isActive: active,
                                       firstSeenAt: .distantPast, lastSeenAt: .distantPast))
            }
            try context.save()
        }
        let blob = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": [
            "accessToken": "tok-254",
            "expiresAt": Int64(Date().addingTimeInterval(3600).timeIntervalSince1970) * 1000,
        ]])
        let client = OAuthClient(keychain: KeychainOAuth(rawReader: { .success(blob) }),
                                 transport: { _ in throw URLError(.notConnectedToInternet) },
                                 desktopEnabled: { false })
        let poller = OAuthPoller(client: client, container: container, clock: TestClock())
        await poller.stopPublishingScopeForTesting()

        let heard = Heard()
        let observer = NotificationCenter.default.addObserver(
            forName: PacerAccountChange.didActivate, object: poller, queue: nil
        ) { heard.record(PacerAccountChange($0), onMain: Thread.isMainThread) }
        defer { NotificationCenter.default.removeObserver(observer) }

        await poller.setActiveAccount(id: "org-254-b")
        await poller.setActiveAccount(id: "org-254-b")      // re-asserted: no news
        await poller.setActiveAccount(id: "org-254-nobody") // no such row: nothing to tell

        #expect(heard.changes.map(\.activeAccountId) == ["org-254-b"])
        #expect(heard.onMain == [false], "announced from the poller, not the main actor")
    }
}

/// What an observer heard, from whichever thread posted.
private final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var _changes: [PacerAccountChange] = []
    private var _onMain: [Bool] = []

    func record(_ change: PacerAccountChange?, onMain: Bool = false) {
        guard let change else { return }
        lock.withLock {
            _changes.append(change)
            _onMain.append(onMain)
        }
    }

    var changes: [PacerAccountChange] { lock.withLock { _changes } }
    var onMain: [Bool] { lock.withLock { _onMain } }
}
