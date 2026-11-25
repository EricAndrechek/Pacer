import Foundation
import SwiftData
import Synchronization
import Testing
@testable import PacerCore
@testable import PacerUI

/// A model Claude Code uses before any pricing source lists it: the Sentry
/// issue it raises, the faster price checks while it lasts, the cost-cache
/// reload a curated-only update now gets, and the "price pending" mark.
@Suite struct UnpricedModelHandlingTests {

    // MARK: - The Sentry problem

    private static func freshStore() -> UserDefaults {
        let name = "pacer.test.unpriced.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        return store
    }

    private final class Sent: @unchecked Sendable {
        var reports: [UnpricedModelReport.Report] = []
        func send(_ r: UnpricedModelReport.Report) { reports.append(r) }
    }

    @Test("a model's problem goes once per Mac, fingerprinted on the model")
    func problemOncePerModelPerMac() {
        let store = Self.freshStore()
        let sent = Sent()
        UnpricedModelReport.reportFirstSightings(["claude-sonnet-5-6"], store: store, enabled: true,
                                                 send: sent.send)
        #expect(sent.reports.count == 1)
        let report = sent.reports[0]
        #expect(report.fingerprint == ["unpriced-model", "claude-sonnet-5-6"])
        #expect(report.attributes == ["model": .string("claude-sonnet-5-6"), "source": .string("catalog")])

        // The next publish, and the next launch (the same defaults): nothing.
        UnpricedModelReport.reportFirstSightings(["claude-sonnet-5-6"], store: store, enabled: true,
                                                 send: sent.send)
        #expect(sent.reports.count == 1)

        // Another model joining the set is its own first sighting.
        UnpricedModelReport.reportFirstSightings(["claude-sonnet-5-6", "claude-opus-6"], store: store,
                                                 enabled: true, send: sent.send)
        #expect(sent.reports.map(\.model) == ["claude-sonnet-5-6", "claude-opus-6"])
        #expect(sent.reports.last?.fingerprint == ["unpriced-model", "claude-opus-6"])
    }

    @Test("every spelling of one model is one report, named by its canonical id")
    func spellingsCollapse() {
        let both = UnpricedModelReport.reports(for: [
            "claude-sonnet-5-6[1m]", "us.anthropic.claude-sonnet-5-6-v1:0", "claude-sonnet-5-6-20261120",
        ])
        #expect(both == [.init(model: "claude-sonnet-5-6", source: .catalog)])
        // Only partner-cloud or regional ids: the first-party fallback ran out.
        let partner = UnpricedModelReport.reports(for: ["us.anthropic.claude-sonnet-5-6-v1:0"])
        #expect(partner == [.init(model: "claude-sonnet-5-6", source: .firstParty)])
    }

    @Test("a model from another backend is never reported")
    func nonClaudeModelsStayLocal() {
        #expect(UnpricedModelReport.reports(for: ["acme-internal-coder", "openrouter/foo/bar", "gpt-x"]).isEmpty)
    }

    @Test("a diagnostic launch or a Mac with crash reports off sends nothing and marks nothing")
    func notSentIsNotMarked() {
        let store = Self.freshStore()
        let sent = Sent()
        UnpricedModelReport.reportFirstSightings(["claude-sonnet-5-6"], store: store, enabled: false,
                                                 send: sent.send)
        store.set(false, forKey: PacerPreferenceKeys.telemetryCrashReports)
        UnpricedModelReport.reportFirstSightings(["claude-sonnet-5-6"], store: store, enabled: true,
                                                 send: sent.send)
        #expect(sent.reports.isEmpty)
        // So the user's own app, with reports on, still sends it.
        store.set(true, forKey: PacerPreferenceKeys.telemetryCrashReports)
        UnpricedModelReport.reportFirstSightings(["claude-sonnet-5-6"], store: store, enabled: true,
                                                 send: sent.send)
        #expect(sent.reports.count == 1)
    }

    @Test("the scrubber leaves the model tag and the fingerprint as they are")
    func scrubberKeepsModelIds() {
        for model in ["claude-sonnet-5-6", "claude-haiku-5-5", "claude-opus-4-7-thinking"] {
            let report = UnpricedModelReport.Report(model: model, source: .catalog)
            #expect(report.fingerprint.map { TelemetryScrubber.scrub($0) } == report.fingerprint)
            #expect(TelemetryScrubber.scrub(model) == model)
        }
    }

    /// The door carries the fingerprint to the sink; the app's sink sets it
    /// as the Sentry event's fingerprint (`SentryTelemetrySink.problem`).
    @Test("Telemetry.problem hands the fingerprint to the sink")
    func doorForwardsFingerprint() {
        let sink = RecordingSink()
        Telemetry.install(sink)
        defer { Telemetry.install(Telemetry.NoSink()) }
        let message = "unpriced-door-test-\(UUID().uuidString)"
        Telemetry.problem(message, attributes: ["model": .string("claude-x-1")],
                          fingerprint: ["unpriced-model", "claude-x-1"])
        Telemetry.problem(message)
        let mine = sink.problems.withLock { $0 }.filter { $0.message == message }
        #expect(mine.map(\.fingerprint) == [["unpriced-model", "claude-x-1"], nil])
    }

    private final class RecordingSink: Telemetry.Sink {
        struct Problem: Sendable { let message: String; let fingerprint: [String]? }
        let problems = Mutex<[Problem]>([])
        func count(_ key: String, _ value: Int, attributes: Telemetry.Attributes) {}
        func distribution(_ key: String, _ value: Double, unit: Telemetry.Unit, attributes: Telemetry.Attributes) {}
        func gauge(_ key: String, _ value: Double, unit: Telemetry.Unit, attributes: Telemetry.Attributes) {}
        func span(_ span: Telemetry.Span) {}
        func breadcrumb(_ category: String, _ message: String) {}
        func problem(_ message: String, attributes: Telemetry.Attributes, fingerprint: [String]?) {
            problems.withLock { $0.append(Problem(message: message, fingerprint: fingerprint)) }
        }
    }

    // MARK: - Refresh cadence

    /// Run the refresh loop's decisions over `hours` of simulated time and
    /// return when it refreshed. `unpriced(t)` is whether a model had no
    /// price at `t`; `fails` makes every attempt fail.
    private static func refreshTimes(
        hours: Double, fails: Bool = false, unpriced: (TimeInterval) -> Bool
    ) -> [TimeInterval] {
        var t: TimeInterval = 0
        var lastSuccess: TimeInterval?
        var attempts: [TimeInterval] = []
        while t < hours * 3600 {
            let age = lastSuccess.map { t - $0 }
            let due = PricingRefreshSchedule.isDue(cacheAge: age, hasUnpriced: unpriced(t))
            if due {
                attempts.append(t)
                if !fails { lastSuccess = t }
            }
            t += PricingRefreshSchedule.delay(
                attempted: due, succeeded: due && !fails,
                cacheAge: lastSuccess.map { t - $0 }, hasUnpriced: unpriced(t))
        }
        return attempts
    }

    @Test("hourly while a model is unpriced, daily once none is")
    func cadenceFollowsTheUnpricedSet() {
        #expect(PricingRefreshSchedule.interval(hasUnpriced: true) == 3600)
        #expect(PricingRefreshSchedule.interval(hasUnpriced: false) == 24 * 3600)

        let hourly = Self.refreshTimes(hours: 24) { _ in true }
        #expect(hourly.count == 24)
        #expect(zip(hourly, hourly.dropFirst()).allSatisfy { $1 - $0 == 3600 })

        let daily = Self.refreshTimes(hours: 48) { _ in false }
        #expect(daily == [0, 24 * 3600])

        // Priced from 3 h on: back to daily, counted from the last refresh.
        let priced = Self.refreshTimes(hours: 48) { $0 < 3 * 3600 }
        #expect(priced == [0, 3600, 7200, 26 * 3600])
    }

    @Test("a model that turns up unpriced mid-wait is checked for within the hour")
    func newlyUnpricedIsNoticedWithinTheHour() {
        let times = Self.refreshTimes(hours: 12) { $0 >= 5 * 3600 }
        #expect(times.first == 0)
        #expect(times.count >= 2)
        #expect((times.dropFirst().first ?? .infinity) <= 6 * 3600)
    }

    @Test("failures retry no faster than the retry interval, at either cadence")
    func failuresBackOff() {
        for unpriced in [true, false] {
            let attempts = Self.refreshTimes(hours: 6, fails: true) { _ in unpriced }
            #expect(attempts.count >= 5)
            #expect(zip(attempts, attempts.dropFirst())
                .allSatisfy { $1 - $0 >= PricingRefreshSchedule.retryInterval })
        }
    }

    // MARK: - The curated-only reload

    private final class Calls: @unchecked Sendable { var reloads = 0 }

    @MainActor
    @Test("a curated-only refresh reloads the cost cache")
    func curatedOnlyRefreshReloads() async {
        let calls = Calls()
        let outcome = await PricingRefreshPass.run(
            refreshCatalog: { false }, refreshCurated: { true }, reload: { calls.reloads += 1 })
        #expect(calls.reloads == 1)
        #expect(outcome.reloaded && outcome.curatedRefreshed && !outcome.catalogRefreshed)

        let catalog = await PricingRefreshPass.run(
            refreshCatalog: { true }, refreshCurated: { false }, reload: { calls.reloads += 1 })
        #expect(calls.reloads == 2 && catalog.reloaded)

        let neither = await PricingRefreshPass.run(
            refreshCatalog: { false }, refreshCurated: { false }, reload: { calls.reloads += 1 })
        #expect(calls.reloads == 2)
        #expect(!neither.reloaded && !neither.pricesChanged)
    }

    // MARK: - The "price pending" mark

    @MainActor
    @Test("the mark is on an unpriced model's cost and goes once it is priced")
    func hintFollowsPricing() {
        let board = PricePending()
        func row(_ model: String) -> PacerUsageRow<PacerUsageNoExtra> {
            // How the views build a model's row.
            PacerUsageRow(id: model, label: pacerModelDisplayName(model), tokens: .zero,
                          costParts: .zero, cost: 0, pricePendingModels: board.pending(in: [model]))
        }
        board.update(["claude-sonnet-5-6"])
        #expect(row("claude-sonnet-5-6").pricePendingModels == ["claude-sonnet-5-6"])
        #expect(PacerPricePending.help(row("claude-sonnet-5-6").pricePendingModels)
                == "No price yet for Sonnet 5.6; costs update once one is published")
        #expect(row("claude-opus-4-7").pricePendingModels.isEmpty)
        #expect(PacerPricePending.help(row("claude-opus-4-7").pricePendingModels) == nil)

        // A total that includes it (the Today tile, the menu's Today row).
        #expect(board.pending(in: ["claude-opus-4-7", "claude-sonnet-5-6"]) == ["claude-sonnet-5-6"])

        board.update([])
        #expect(row("claude-sonnet-5-6").pricePendingModels.isEmpty)
        #expect(PacerPricePending.help(row("claude-sonnet-5-6").pricePendingModels) == nil)
    }

    @Test("two spellings of one model name it once")
    func helpNamesEachModelOnce() {
        #expect(PacerPricePending.help(["claude-sonnet-5-6", "claude-sonnet-5-6[1m]"])
                == "No price yet for Sonnet 5.6; costs update once one is published")
    }

    @Test("a donut list's folded tail keeps its rows' marks")
    func foldedTailCarriesTheMark() {
        var rows: [PacerUsageRow<PacerUsageNoExtra>] = []
        for i in 0..<4 {
            let pending: [String] = i == 3 ? ["m3"] : []
            let tokens = TokenBreakdown(inputTokens: Int64(100 - i))
            let cost = Double(10 - i)
            rows.append(PacerUsageRow(id: "m\(i)", label: "m\(i)", tokens: tokens, costParts: .zero,
                                      cost: cost, pricePendingModels: pending))
        }
        let data = PacerShareListData(rows: rows, sort: .costDescending, maxSlices: 2)
        #expect(data.other?.pricePendingModels == ["m3"])
    }

    // MARK: - The scan hands the set on

    private final class Published: @unchecked Sendable {
        let sets = Mutex<[Set<String>]>([])
    }

    @ScanActor
    @Test("the scan hands on the unpriced set at its first reconcile and on changes only")
    func scanPublishesOnChangeOnly() async throws {
        let model = "claude-zz-unreleased-9-9"
        let root = try Self.fixtureRoot(model: model)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(for: Schema(PacerStore.allModelTypes),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let published = Published()
        func coordinator(_ mode: CostMode) -> ScanCoordinator {
            ScanCoordinator(
                container: container,
                configuration: .init(costMode: mode, watcherMode: .manual, probeStatsCache: false,
                                     onUnpricedModels: { set in published.sets.withLock { $0.append(set) } }),
                resolver: ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": root.path]))
        }
        // The reconcile reads the daily rollup before the cycle recomputes it,
        // so on an empty store the first cycle has nothing pending and the
        // model shows up at the next; a third cycle changes nothing.
        let first = coordinator(.calculate)
        _ = try await first.runOnce()
        _ = try await first.runOnce()
        _ = try await first.runOnce()
        #expect(published.sets.withLock { $0 } == [[], [model]])

        // A relaunch hands it on again: nothing is published at launch.
        _ = try await coordinator(.calculate).runOnce()
        #expect(published.sets.withLock { $0 } == [[], [model], [model]])

        // Display mode prices nothing, so nothing is pending.
        _ = try await coordinator(.display).runOnce()
        #expect(published.sets.withLock { $0 }.last == [])
    }

    private static func fixtureRoot(model: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pacer-unpriced-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("projects/-tmp-fixture")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fields: [String: Any] = [
            "type": "assistant", "timestamp": stamp.string(from: Date()), "requestId": "r1",
            "sessionId": "unpriced-session", "cwd": "/tmp/acme",
            "message": [
                "model": model, "id": "m1", "stop_reason": "end_turn",
                "usage": ["input_tokens": 100, "output_tokens": 200, "cache_read_input_tokens": 0,
                          "cache_creation": ["ephemeral_5m_input_tokens": 0,
                                             "ephemeral_1h_input_tokens": 0]],
            ] as [String: Any],
        ]
        let line = String(data: try JSONSerialization.data(withJSONObject: fields), encoding: .utf8)!
        try (line + "\n").write(to: dir.appendingPathComponent("unpriced-session.jsonl"),
                                atomically: true, encoding: .utf8)
        return root
    }
}
