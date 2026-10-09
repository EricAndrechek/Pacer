import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// The snapshot's session table reads turns with raw SQLite (#211), through
/// Core Data's mangled column names. So, as for `RawLimitReader`, the test is
/// parity: rows go in through SwiftData, and the raw read and the answers built
/// from it must equal the ordinary per-session lookup exactly.
@Suite("Raw session turn reads match SwiftData exactly")
struct RawSessionTurnReaderParityTests {

    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeStore() throws -> (ModelContainer, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).sqlite")
        let container = try ModelContainer(
            for: TokenSample.self, AccountSessionInfo.self, AccountActivation.self,
            Account.self, ClaudeCodeMeta.self,
            configurations: ModelConfiguration(url: url))
        return (container, url)
    }

    private func turn(_ context: ModelContext, session: String?, secondsAgo: Double,
                      model: String, account: String?, path: String?) {
        let at = Self.now.addingTimeInterval(-secondsAgo)
        let sample = TokenSample(
            sampledAt: at, date: TokenSample.formatDate(at), model: model,
            inputTokens: 1, outputTokens: 1, cacheReadTokens: 0,
            cacheCreation5mTokens: 0, cacheCreation1hTokens: 0,
            sessionId: session, projectPath: path)
        sample.accountId = account
        context.insert(sample)
    }

    /// The awkward cases:
    /// - a fan-out with more than 200 turns inside fifteen minutes;
    /// - a `<synthetic>` newest turn;
    /// - an unattributed session with no project;
    /// - a session whose newest turn sits just inside the window, with older
    ///   turns beyond the edge;
    /// - a session wholly outside the window;
    /// - turns with no session at all.
    private func seed(_ context: ModelContext) throws {
        let window = PacerSessionLookupBuilder.snapshotWindow
        for i in 0..<260 {
            turn(context, session: "fanout", secondsAgo: 30 + Double(i) * 3,
                 model: i.isMultiple(of: 3) ? "claude-sonnet-5" : "claude-opus-5",
                 account: "orgA", path: "/tmp/acme")
        }
        turn(context, session: "synthetic", secondsAgo: 10, model: "<synthetic>",
             account: "orgA", path: "/tmp/globex")
        turn(context, session: "synthetic", secondsAgo: 20, model: "claude-haiku-5",
             account: "orgA", path: "/tmp/globex")
        turn(context, session: "unattributed", secondsAgo: 600, model: "claude-opus-5",
             account: nil, path: nil)
        turn(context, session: "edge", secondsAgo: window - 60, model: "claude-opus-5",
             account: "orgB", path: "/tmp/initech")
        turn(context, session: "edge", secondsAgo: window + 300, model: "claude-sonnet-5",
             account: "orgB", path: "/tmp/initech")
        turn(context, session: "edge", secondsAgo: window + 3_600, model: "claude-haiku-5",
             account: "orgB", path: "/tmp/initech")
        turn(context, session: "old", secondsAgo: window + 600, model: "claude-opus-5",
             account: "orgA", path: "/tmp/acme")
        turn(context, session: nil, secondsAgo: 5, model: "claude-opus-5",
             account: "orgA", path: "/tmp/acme")
        context.insert(AccountActivation(
            accountId: "orgA", startedAt: .distantPast, source: AccountActivation.sourceObserved))
        try context.save()
    }

    @Test("the raw read returns the same turns, newest first")
    func turnsMatch() throws {
        let (container, url) = try makeStore()
        let context = ModelContext(container)
        try seed(context)
        let since = Self.now.addingTimeInterval(-PacerSessionLookupBuilder.snapshotWindow)

        let raw = try #require(RawSessionTurnReader.turns(storeURL: url, since: since))
        let stored = try context.fetch(FetchDescriptor<TokenSample>(
            predicate: #Predicate { $0.sampledAt >= since && $0.sessionId != nil },
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]))
        #expect(raw.count == stored.count)
        for (r, s) in zip(raw, stored) {
            #expect(r.sessionId == s.sessionId)
            #expect(r.turn == PacerSessionTurn(sampledAt: s.sampledAt, model: s.model,
                                               accountId: s.accountId, projectPath: s.projectPath))
        }
    }

    @Test("every live session's answer equals the per-session store lookup")
    func answersMatch() throws {
        let (container, url) = try makeStore()
        let context = ModelContext(container)
        try seed(context)
        let binding = PacerSessionBinding.load(context: context, desktop: nil)

        let live = PacerSessionLookupBuilder.live(
            context: context, storeURL: url, binding: binding, now: Self.now)
        #expect(Set(live.keys) == ["fanout", "synthetic", "unattributed", "edge"])
        for (id, answer) in live {
            let stored = try #require(PacerSessionLookupBuilder.lookup(
                context: context, sessionId: id, binding: binding, now: Self.now))
            #expect(try answer.encodedJSON() == stored.encodedJSON(), "session \(id)")
        }
        // The cases the fixture exists for, stated directly.
        #expect(live["fanout"]?.models == ["claude-sonnet-5", "claude-opus-5"])
        #expect(live["synthetic"]?.model == "claude-haiku-5")
        #expect(live["unattributed"]?.accountId == nil)
        // Its turn beyond the window's edge is within fifteen minutes of its
        // newest, so it counts; the one an hour before that does not.
        #expect(live["edge"]?.models == ["claude-opus-5", "claude-sonnet-5"])
    }
}
