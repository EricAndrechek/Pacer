import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// What model is *this* agent running?
///
/// The session endpoint used to answer with the newest turn's model, which is
/// only right when a session runs one model at a time. Claude Code writes a
/// subagent's turns under the parent's session id, so a fan-out means several
/// models share one id and "newest" is whichever agent wrote last. A Sonnet
/// builder was told "Fable" and gated on its orchestrator's cap.
@Suite("Session models")
struct PacerSessionModelsTests {

    private static func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Account.self, AccountSessionInfo.self, ProjectMeta.self,
            AccountActivation.self, AccountDailyAggregate.self, TokenSample.self,
            RateLimitSample.self, UsageLimitSample.self, ExtraUsageSample.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @MainActor
    private static func turn(_ context: ModelContext, session: String, model: String,
                             secondsAgo: Double, now: Date) {
        context.insert(TokenSample(
            sampledAt: now.addingTimeInterval(-secondsAgo),
            date: TokenSample.formatDate(now.addingTimeInterval(-secondsAgo)),
            model: model,
            inputTokens: 10, outputTokens: 20, cacheReadTokens: 0,
            cacheCreation5mTokens: 0, cacheCreation1hTokens: 0,
            sessionId: session, projectPath: "/tmp/p"))
    }

    @MainActor
    @Test func aFanOutReportsEveryModelInFlight() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // An orchestrator and its builders, interleaved under one session id.
        Self.turn(context, session: "s1", model: "claude-sonnet-5", secondsAgo: 30, now: now)
        Self.turn(context, session: "s1", model: "claude-fable-5-1", secondsAgo: 10, now: now)
        Self.turn(context, session: "s1", model: "claude-sonnet-5", secondsAgo: 5, now: now)
        try context.save()

        let found = try #require(try PacerSessionLookupBuilder.lookup(
            container: container, sessionId: "s1", now: now))
        #expect(Set(found.models) == ["claude-sonnet-5", "claude-fable-5-1"])
        // Newest first, so a single-model session's `model` is unchanged.
        #expect(found.model == "claude-sonnet-5")
    }

    @MainActor
    @Test func oneModelSessionsAreStillUnambiguous() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        Self.turn(context, session: "s1", model: "claude-opus-5", secondsAgo: 60, now: now)
        Self.turn(context, session: "s1", model: "claude-opus-5", secondsAgo: 5, now: now)
        try context.save()

        let found = try #require(try PacerSessionLookupBuilder.lookup(
            container: container, sessionId: "s1", now: now))
        #expect(found.models == ["claude-opus-5"])
        #expect(found.model == "claude-opus-5")
    }

    /// A model used an hour ago is not a model in flight. Without a horizon,
    /// any long session eventually looks ambiguous forever and never gates on
    /// a per-model cap again.
    @MainActor
    @Test func aModelFromHoursAgoIsNotStillRunning() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        Self.turn(context, session: "s1", model: "claude-haiku-4-5-20251001",
                  secondsAgo: 3 * 3600, now: now)
        Self.turn(context, session: "s1", model: "claude-opus-5", secondsAgo: 5, now: now)
        try context.save()

        let found = try #require(try PacerSessionLookupBuilder.lookup(
            container: container, sessionId: "s1", now: now))
        #expect(found.models == ["claude-opus-5"])
    }

    /// `<synthetic>` is Claude Code's sentinel for non-billable internal
    /// traffic. It names no real model and must not make a session look like
    /// it is running two.
    @MainActor
    @Test func syntheticTurnsAreNotAModel() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        Self.turn(context, session: "s1", model: "claude-opus-5", secondsAgo: 20, now: now)
        Self.turn(context, session: "s1", model: JSONLLineParser.syntheticModelSentinel,
                  secondsAgo: 2, now: now)
        try context.save()

        let found = try #require(try PacerSessionLookupBuilder.lookup(
            container: container, sessionId: "s1", now: now))
        #expect(found.models == ["claude-opus-5"])
        #expect(found.model == "claude-opus-5")
    }
}
