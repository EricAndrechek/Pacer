import Foundation
import Testing
@testable import PacerCore

// The store is what lets Pacer keep a live Claude Code token for an account it
// is not signed into, and it reads other tools' keychain items to do it. So the
// properties that matter are about restraint: it reads only what changed, it
// never retries a read that failed, and it reads nothing of the switcher's
// when the user has turned that off (#170).

@Suite("Parked credential store")
struct ParkedCredentialStoreTests {

    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        func note(_ item: ParkedCredentialStore.Item) {
            lock.lock(); log.append("\(item.service)|\(item.account ?? "")"); lock.unlock()
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return log.count }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return log }
    }

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: T
        init(_ v: T) { _value = v }
        var value: T {
            get { lock.lock(); defer { lock.unlock() }; return _value }
            set { lock.lock(); _value = newValue; lock.unlock() }
        }
    }

    private static func blob(_ token: String, expires: Date = Date().addingTimeInterval(3600)) -> Data {
        let body: [String: Any] = ["claudeAiOauth": [
            "accessToken": token,
            "expiresAt": Int64(expires.timeIntervalSince1970) * 1000,
        ]]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private static func item(_ service: String, _ account: String?, _ modified: TimeInterval?) -> ParkedCredentialStore.Item {
        .init(service: service, account: account,
              modified: modified.map { Date(timeIntervalSince1970: $0) })
    }

    @Test("switcher items, profile items, and nothing else")
    func classification() {
        typealias S = ParkedCredentialStore
        #expect(S.kind(service: "claude-swap", account: "account-1-someone@example.com") == .switcher)
        #expect(S.kind(service: "claude-swap", account: "account-1-someone@example.com.prev") == nil)
        #expect(S.kind(service: "claude-swap", account: "settings") == nil)
        #expect(S.kind(service: "Claude Code-credentials-1a2b3c4d", account: "me") == .profile)
        #expect(S.kind(service: "Claude Code-credentials", account: "me") == nil)
        #expect(S.kind(service: "Claude Safe Storage", account: "Claude") == nil)
    }

    @Test("an item is read once, and again only when its modification date moves")
    func readsOnlyChangedItems() {
        let reads = Reads()
        let items = Box([Self.item("claude-swap", "account-1-a@example.com", 100),
                         Self.item("claude-swap", "account-2-b@example.com", 100)])
        let store = ParkedCredentialStore(
            listItems: { items.value },
            read: { item in reads.note(item); return .data(Self.blob("tok-\(item.account!)")) },
            switcherEnabled: { true })

        #expect(store.credentials().count == 2)
        #expect(store.credentials().count == 2)
        #expect(reads.count == 2)

        // cswap refreshed account 2's copy.
        items.value = [Self.item("claude-swap", "account-1-a@example.com", 100),
                       Self.item("claude-swap", "account-2-b@example.com", 200)]
        #expect(store.credentials().count == 2)
        #expect(reads.count == 3)
        #expect(reads.all.last == "claude-swap|account-2-b@example.com")
    }

    /// A profile item holding a token that expired months ago used to cost a
    /// `security` subprocess on every discovery.
    @Test("a dead profile item is read once, not on every discovery")
    func deadProfileItemIsReadOnce() {
        let reads = Reads()
        let store = ParkedCredentialStore(
            listItems: { [Self.item("Claude Code-credentials-1a2b3c4d", "me", 100)] },
            read: { item in
                reads.note(item)
                return .data(Self.blob("old", expires: Date(timeIntervalSince1970: 1_000)))
            },
            switcherEnabled: { true })
        for _ in 0..<5 { _ = store.credentials() }
        #expect(reads.count == 1)
    }

    /// The Claude Desktop lesson: a read that makes macOS ask for a password
    /// must not ask again every few minutes.
    @Test("a failed read stops that kind for the session, and keeps what it had")
    func failureLatches() {
        let reads = Reads()
        let items = Box([Self.item("claude-swap", "account-1-a@example.com", 100)])
        let fail = Box(false)
        let store = ParkedCredentialStore(
            listItems: { items.value },
            read: { item in
                reads.note(item)
                return fail.value ? .failed("access denied") : .data(Self.blob("tok"))
            },
            switcherEnabled: { true })
        #expect(store.credentials().map(\.accessToken) == ["tok"])

        fail.value = true
        items.value = [Self.item("claude-swap", "account-1-a@example.com", 200),
                       Self.item("claude-swap", "account-2-b@example.com", 200)]
        _ = store.credentials()
        let afterFailure = reads.count
        #expect(store.switcherStatus().failure == "access denied")

        // More changes: nothing is read, and the token already held stays.
        items.value = [Self.item("claude-swap", "account-1-a@example.com", 300),
                       Self.item("claude-swap", "account-2-b@example.com", 300)]
        #expect(store.credentials().map(\.accessToken) == ["tok"])
        #expect(reads.count == afterFailure)

        // Turning the setting off and on again is the user asking to retry.
        store.resetFailures()
        fail.value = false
        #expect(store.credentials().count == 2)
    }

    @Test("with the setting off, no switcher item is read; profile items still are")
    func optOut() {
        let reads = Reads()
        let store = ParkedCredentialStore(
            listItems: { [Self.item("claude-swap", "account-1-a@example.com", 100),
                          Self.item("Claude Code-credentials-1a2b3c4d", "me", 100)] },
            read: { item in reads.note(item); return .data(Self.blob("tok-\(item.service)")) },
            switcherEnabled: { false })
        #expect(store.credentials().map(\.accessToken) == ["tok-Claude Code-credentials-1a2b3c4d"])
        #expect(reads.all == ["Claude Code-credentials-1a2b3c4d|me"])
    }

    @Test("status counts saved logins and the ones that gave a live token")
    func status() {
        let store = ParkedCredentialStore(
            listItems: { [Self.item("claude-swap", "account-1-a@example.com", 100),
                          Self.item("claude-swap", "account-2-b@example.com", 100),
                          Self.item("claude-swap", "account-2-b@example.com.prev", 100)] },
            read: { item in
                item.account == "account-1-a@example.com"
                    ? .data(Self.blob("live"))
                    : .data(Self.blob("expired", expires: Date(timeIntervalSince1970: 1_000)))
            },
            switcherEnabled: { true })
        #expect(store.switcherStatus() == .init(saved: 2, usable: 0, failure: nil))
        _ = store.credentials()
        #expect(store.switcherStatus() == .init(saved: 2, usable: 1, failure: nil))
    }

    @Test("the setting is on unless it has been turned off")
    func defaultsOn() {
        let defaults = UserDefaults(suiteName: "pacer-test-\(UUID().uuidString)")!
        #expect(PacerPreferences.switcherCredentialsEnabled(from: defaults))
        defaults.set(false, forKey: PacerPreferenceKeys.switcherCredentialsEnabled)
        #expect(!PacerPreferences.switcherCredentialsEnabled(from: defaults))
    }
}
