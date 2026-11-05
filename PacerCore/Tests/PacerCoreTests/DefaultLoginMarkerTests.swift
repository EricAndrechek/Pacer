import Foundation
import Testing
@testable import PacerCore

/// #343: the app writes the default login down for `pacer status`, which
/// compares it with the login a verdict was gated under. Fictional org ids.
@Suite("Default login marker")
struct DefaultLoginMarkerTests {

    private static let work = "11111111-1111-4111-8111-111111111111"
    private static let home = "22222222-2222-4222-8222-222222222222"

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
    }

    static func scratch() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pacer-login-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(DefaultLoginMarker.fileName)
    }

    static func span(_ account: String, _ start: TimeInterval) -> AccountTrail.Span {
        AccountTrail.Span(accountId: account, startedAt: Date(timeIntervalSince1970: start),
                          endedAt: nil, rootPath: nil)
    }

    @Test func roundTripsAndRejectsAnythingElse() {
        let marker = DefaultLoginMarker(accountId: Self.work, since: Date(timeIntervalSince1970: 1_799_000_000),
                                        changedAt: Date(timeIntervalSince1970: 1_799_000_001.5))
        #expect(DefaultLoginMarker.decode(marker.encoded()) == marker)
        #expect(DefaultLoginMarker.decode(Data("{\"account\": \"\(Self.work)\"".utf8)) == nil)
        #expect(DefaultLoginMarker.decode(Data("{}".utf8)) == nil)
        #expect(DefaultLoginMarker.read(from: nil) == nil)
    }

    @Test func aTestProcessNeverTouchesTheRealContainer() {
        #expect(DefaultLoginMarker.fileURL() == nil)
        #expect(DefaultLoginMarker.publishURL() == nil)
    }

    @Test func writesOnASwitchAndOnlyThen() throws {
        let url = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let clock = Clock()
        let publisher = DefaultLoginMarkerPublisher(url: url, now: { clock.now })

        publisher.publish(Self.span(Self.work, 1_799_990_000))
        let first = try #require(DefaultLoginMarker.read(from: url))
        #expect(first.accountId == Self.work)
        #expect(first.changedAt == clock.now)

        // The same login again: nothing written (an unchanged file stays put).
        try FileManager.default.removeItem(at: url)
        clock.advance(30)
        publisher.publish(Self.span(Self.work, 1_799_990_000))
        #expect(DefaultLoginMarker.read(from: url) == nil)

        // A switch is written, stamped when this process saw it.
        clock.advance(30)
        publisher.publish(Self.span(Self.home, 1_800_000_050))
        let switched = try #require(DefaultLoginMarker.read(from: url))
        #expect(switched.accountId == Self.home)
        #expect(switched.changedAt == clock.now)

        // A correction that backdates the same login is not a new switch.
        let switchedAt = clock.now
        clock.advance(30)
        publisher.publish(Self.span(Self.home, 1_800_000_040))
        let corrected = try #require(DefaultLoginMarker.read(from: url))
        #expect(corrected.since == Date(timeIntervalSince1970: 1_800_000_040))
        #expect(corrected.changedAt == switchedAt)

        // No open span is "can't tell", never a logout.
        publisher.publish(nil)
        #expect(DefaultLoginMarker.read(from: url)?.accountId == Self.home)
    }

    @Test func aRelaunchOnTheSameLoginKeepsWhenItChanged() throws {
        let url = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let clock = Clock()
        DefaultLoginMarkerPublisher(url: url, now: { clock.now }).publish(Self.span(Self.work, 1_799_990_000))
        let written = try #require(DefaultLoginMarker.read(from: url))

        // A new process an hour later, same login: a reader must not take
        // the relaunch for a switch a moment ago.
        clock.advance(3_600)
        DefaultLoginMarkerPublisher(url: url, now: { clock.now }).publish(Self.span(Self.work, 1_799_990_000))
        #expect(DefaultLoginMarker.read(from: url) == written)

        // A new process on another login than the file names: asserted.
        DefaultLoginMarkerPublisher(url: url, now: { clock.now }).publish(Self.span(Self.home, 1_800_003_000))
        let asserted = try #require(DefaultLoginMarker.read(from: url))
        #expect(asserted.accountId == Self.home)
        #expect(asserted.changedAt == clock.now)
    }

    /// The coordinator writes it when the trail moves, from a login pass, so
    /// a `pacer status` sees a switch within the pass rather than the cycle.
    @Test func aLoginPassWritesTheTrailsLogin() async throws {
        let url = try Self.scratch()
        let home = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: home) }
        let coordinator = ScanCoordinator(
            container: try PacerStore.makeInMemoryContainer(),
            configuration: .init(watcherMode: .manual, probeStatsCache: false,
                                 loginMarker: DefaultLoginMarkerPublisher(url: url)),
            resolver: ClaudePathResolver(environment: [:], homeDirectory: home),
            homeDirectory: home, keychainStamp: { nil })
        func signIn(_ org: String) throws {
            let config = home.appendingPathComponent(".claude.json")
            try #"{"oauthAccount":{"organizationUuid":"\#(org)","accountUuid":"u-\#(org)"}}"#
                .write(to: config, atomically: true, encoding: .utf8)
        }
        try signIn(Self.work)
        await coordinator.followLoginChange(.config)
        #expect(DefaultLoginMarker.read(from: url)?.accountId == Self.work)

        try await Task.sleep(nanoseconds: 20_000_000)
        try signIn(Self.home)
        await coordinator.followLoginChange(.config)
        #expect(DefaultLoginMarker.read(from: url)?.accountId == Self.home)
    }

    @Test func writesNothingWithoutAPlace() {
        // Tests and diagnostic launches get a publisher with no file.
        DefaultLoginMarkerPublisher(url: nil).publish(Self.span(Self.work, 1_799_990_000))
    }
}
