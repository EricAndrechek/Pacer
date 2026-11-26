import Foundation
import SwiftData
import Synchronization
import Testing
@testable import PacerCore
@testable import PacerUI

/// A model Claude Code uses before any pricing source lists it: the Sentry
/// issue it raises, the faster price checks while it is new, the cost-cache
/// reload a curated-only update now gets, and the "price pending" mark.
@Suite struct UnpricedModelHandlingTests {

    private let defaultsBag = TestDefaultsBag()

    private func freshStore() -> UserDefaults { defaultsBag.make(prefix: "unpriced") }

    /// The sink's answer, settable, and what it was handed.
    private final class Sender: @unchecked Sendable {
        let accepts = Mutex(true)
        let reports = Mutex<[UnpricedModelReport.Report]>([])
        var sent: [UnpricedModelReport.Report] { reports.withLock { $0 } }
        func send(_ r: UnpricedModelReport.Report) -> Bool {
            guard accepts.withLock({ $0 }) else { return false }
            reports.withLock { $0.append(r) }
            return true
        }
    }

    private static func today(offsetDays: Int = 0) -> String {
        TokenSample.formatDate(Date().addingTimeInterval(TimeInterval(offsetDays) * 86_400))
    }

    private static func state(_ models: Set<String>, firstDay: String = today()) -> UnpricedModels.State {
        UnpricedModels.State(unpriced: models, costless: models,
                             firstDay: Dictionary(uniqueKeysWithValues: models.map { ($0, firstDay) }))
    }

    @MainActor
    private static func hub(_ store: UserDefaults, _ sender: Sender, board: PricePending? = nil,
                            enabled: Bool = true) -> UnpricedModelsHub {
        UnpricedModelsHub(store: store, board: board ?? PricePending(), reportsEnabled: enabled,
                          send: { sender.send($0) })
    }

    // MARK: - The Sentry problem

    @MainActor
    @Test("a model's problem goes once per Mac, fingerprinted on the model")
    func problemOncePerModelPerMac() {
        let store = freshStore()
        let sender = Sender()
        let hub = Self.hub(store, sender)
        hub.publish(Self.state(["claude-sonnet-5-6"]))
        #expect(sender.sent.count == 1)
        let report = sender.sent[0]
        #expect(report.fingerprint == ["unpriced-model", "claude-sonnet-5-6"])
        #expect(report.attributes == ["model": .string("claude-sonnet-5-6"), "source": .string("catalog")])

        // Another publish, and the next launch (a new hub, the same defaults).
        hub.publish(Self.state(["claude-sonnet-5-6", "glm-4.6"]))
        Self.hub(store, sender).publish(Self.state(["claude-sonnet-5-6"]))
        #expect(sender.sent.count == 1)

        // Another model joining the set is its own first sighting.
        hub.publish(Self.state(["claude-sonnet-5-6", "claude-opus-6"]))
        #expect(sender.sent.map(\.model) == ["claude-sonnet-5-6", "claude-opus-6"])
        #expect(sender.sent.last?.fingerprint == ["unpriced-model", "claude-opus-6"])
    }

    @MainActor
    @Test("a report the sink refused is not marked, and goes at a later publish")
    func refusedIsNotMarked() {
        let store = freshStore()
        let sender = Sender()
        sender.accepts.withLock { $0 = false }
        let hub = Self.hub(store, sender)
        hub.publish(Self.state(["claude-sonnet-5-6"]))
        #expect(sender.sent.isEmpty)
        sender.accepts.withLock { $0 = true }
        Self.hub(store, sender).publish(Self.state(["claude-sonnet-5-6"]))
        #expect(sender.sent.map(\.model) == ["claude-sonnet-5-6"])
    }

    @MainActor
    @Test("at most three reports a launch; the rest go on the next")
    func perLaunchCap() {
        let store = freshStore()
        let sender = Sender()
        let models: Set<String> = ["claude-a-1", "claude-b-1", "claude-c-1", "claude-d-1", "claude-e-1"]
        let hub = Self.hub(store, sender)
        hub.publish(Self.state(models))
        #expect(sender.sent.count == UnpricedModelReport.perLaunchCap)
        hub.publish(Self.state(models.union(["claude-f-1"])))
        #expect(sender.sent.count == 3)
        Self.hub(store, sender).publish(Self.state(models))
        #expect(Set(sender.sent.map(\.model)) == models)
    }

    @MainActor
    @Test("a diagnostic launch or a test sends nothing and marks nothing")
    func disabledSendsNothing() {
        let store = freshStore()
        let sender = Sender()
        Self.hub(store, sender, enabled: false).publish(Self.state(["claude-sonnet-5-6"]))
        #expect(sender.sent.isEmpty)
        Self.hub(store, sender).publish(Self.state(["claude-sonnet-5-6"]))
        #expect(sender.sent.count == 1)
    }

    @Test("every spelling of one model is one report, named by its canonical id")
    func spellingsCollapse() {
        let both = UnpricedModelReport.reports(for: [
            "claude-sonnet-5-6[1m]", "us.anthropic.claude-sonnet-5-6-v1:0", "claude-sonnet-5-6-20261120",
        ])
        #expect(both == [.init(model: "claude-sonnet-5-6", source: .catalog)])
        // Only partner-cloud or regional ids: the first-party fallback ran out.
        let partner = UnpricedModelReport.reports(for: ["us.anthropic.claude-sonnet-5-6-v1:0"])
        #expect(partner == [.init(model: "claude-sonnet-5-6", source: .partnerOnly)])
        #expect(partner.first?.attributes["source"] == .string("partner_only"))
    }

    @Test("another backend's model, or a Claude alias with no version, is never a tag")
    func onlyVersionedClaudeIds() {
        #expect(UnpricedModelReport.reports(for: [
            "acme-internal-coder", "openrouter/foo/bar", "gpt-x", "claude-sonnet-acme-prod", "claude-internal",
        ]).isEmpty)
        #expect(UnpricedModelReport.reports(for: ["claude-3-5-sonnet"]).map(\.model) == ["claude-3-5-sonnet"])
    }

    @Test("the scrubber leaves the model tag and the fingerprint as they are")
    func scrubberKeepsModelIds() {
        for model in ["claude-sonnet-5-6", "claude-haiku-5-5", "claude-opus-4-7-thinking"] {
            let report = UnpricedModelReport.Report(model: model, source: .catalog)
            let fields = Telemetry.ProblemFields(UnpricedModelReport.message, attributes: report.attributes,
                                                 fingerprint: report.fingerprint)
            #expect(fields.fingerprint == report.fingerprint)
            #expect(fields.tags == ["model": model, "source": "catalog"])
        }
    }

    /// The mapping the Sentry sink applies (`SentryTelemetrySink.problem`
    /// assigns these fields to the event).
    @Test("a problem's fields: tags, extra, and a scrubbed fingerprint")
    func problemFields() {
        let fields = Telemetry.ProblemFields(
            "Model has no price",
            attributes: ["model": .string("claude-x-1"), "ok": .bool(true), "ms": .int(3), "r": .double(.nan)],
            fingerprint: ["unpriced-model", "/Users/somebody/x"])
        #expect(fields.tags == ["model": "claude-x-1", "ok": "true"])
        #expect(fields.extra == ["ms": .int(3)])
        #expect(fields.fingerprint == ["unpriced-model", "~/x"])
        #expect(Telemetry.ProblemFields("m", attributes: [:], fingerprint: []).fingerprint == nil)
        #expect(Telemetry.ProblemFields("m", attributes: [:], fingerprint: nil).fingerprint == nil)
    }

    @Test("Telemetry.problem hands the fingerprint to the sink and returns its answer")
    func doorForwardsFingerprint() {
        let sink = RecordingSink()
        Telemetry.install(sink)
        defer { Telemetry.install(Telemetry.NoSink()) }
        let message = "unpriced-door-test-\(UUID().uuidString)"
        #expect(Telemetry.problem(message, attributes: ["model": .string("claude-x-1")],
                                  fingerprint: ["unpriced-model", "claude-x-1"]))
        #expect(!Telemetry.problem(message + "-refused"))
        let mine = sink.problems.withLock { $0 }.filter { $0.message.hasPrefix(message) }
        #expect(mine.map(\.fingerprint) == [["unpriced-model", "claude-x-1"], nil])
        #expect(!Telemetry.NoSink().problem("m", attributes: [:], fingerprint: nil))
    }

    private final class RecordingSink: Telemetry.Sink {
        struct Problem: Sendable { let message: String; let fingerprint: [String]? }
        let problems = Mutex<[Problem]>([])
        func count(_ key: String, _ value: Int, attributes: Telemetry.Attributes) {}
        func distribution(_ key: String, _ value: Double, unit: Telemetry.Unit, attributes: Telemetry.Attributes) {}
        func gauge(_ key: String, _ value: Double, unit: Telemetry.Unit, attributes: Telemetry.Attributes) {}
        func span(_ span: Telemetry.Span) {}
        func breadcrumb(_ category: String, _ message: String) {}
        func problem(_ message: String, attributes: Telemetry.Attributes, fingerprint: [String]?) -> Bool {
            problems.withLock { $0.append(Problem(message: message, fingerprint: fingerprint)) }
            return !message.hasSuffix("-refused")
        }
    }

    // MARK: - Refresh cadence

    @MainActor
    @Test("hourly only while a new, versioned Claude model is unpriced")
    func hourlyOnlyForNewClaudeModels() {
        let store = freshStore()
        let sender = Sender()
        let hub = Self.hub(store, sender, enabled: false)
        let now = Date()
        hub.publish(Self.state(["claude-sonnet-5-6"]))
        #expect(hub.wantsHourlyChecks(at: now))
        #expect(!hub.wantsHourlyChecks(at: now.addingTimeInterval(UnpricedModels.hourlyWindow + 86_400)))

        // Unpriced for over a week: daily.
        hub.publish(Self.state(["claude-sonnet-5-6"], firstDay: Self.today(offsetDays: -10)))
        #expect(!hub.wantsHourlyChecks(at: now))
        // Another backend's model, or an alias, never: it would be hourly for good.
        hub.publish(Self.state(["glm-4.6", "kimi-k2", "claude-sonnet-acme-prod"]))
        #expect(!hub.wantsHourlyChecks(at: now))
        // A new one beside them is.
        hub.publish(Self.state(["glm-4.6", "claude-opus-6"]))
        #expect(hub.wantsHourlyChecks(at: now))
        hub.publish(.empty)
        #expect(!hub.wantsHourlyChecks(at: now))
    }

    /// A clock, the catalog cache's write time, and the loop's turns, all
    /// through `PricingRefreshLoop.tick`, the function the app's loop runs.
    @MainActor
    private final class LoopRig {
        var now: TimeInterval = 0
        var cacheWrittenAt: TimeInterval?
        var attempts: [TimeInterval] = []
        var fetchSucceeds = true
        var cacheWriteSucceeds = true
        var hourly: (TimeInterval) -> Bool = { _ in false }

        func run(hours: Double) async -> [TimeInterval] {
            while now < hours * 3600 {
                let tick = await PricingRefreshLoop.tick(.init(
                    cacheAge: { [unowned self] in cacheWrittenAt.map { now - $0 } },
                    hourly: { [unowned self] in hourly(now) },
                    refresh: { [unowned self] _ in
                        attempts.append(now)
                        if fetchSucceeds && cacheWriteSucceeds { cacheWrittenAt = now }
                        return PricingRefreshPass.Outcome(catalogRefreshed: fetchSucceeds, curatedRefreshed: false,
                                                          reloaded: fetchSucceeds, pricesChanged: false)
                    }))
                now += tick.delay
            }
            return attempts
        }
    }

    @MainActor
    @Test("hourly while asked for, daily otherwise")
    func cadenceFollowsTheHourlyFlag() async {
        #expect(PricingRefreshSchedule.interval(hourly: true) == 3600)
        #expect(PricingRefreshSchedule.interval(hourly: false) == 24 * 3600)

        let hourly = LoopRig()
        hourly.hourly = { _ in true }
        let times = await hourly.run(hours: 24)
        #expect(times.count == 24)
        #expect(zip(times, times.dropFirst()).allSatisfy { $1 - $0 == 3600 })

        // `as [TimeInterval]`: Swift 6.0 (macOS 15 CI) infers an Int array here.
        #expect(await LoopRig().run(hours: 48) == [0, 24 * 3600] as [TimeInterval])

        // Hourly for the first 3 h: back to daily, counted from the last refresh.
        let ends = LoopRig()
        ends.hourly = { $0 < 3 * 3600 }
        #expect(await ends.run(hours: 48) == [0, 3600, 7200, 26 * 3600] as [TimeInterval])
    }

    @MainActor
    @Test("a model that turns up unpriced mid-wait is checked for within the hour")
    func newlyUnpricedIsNoticedWithinTheHour() async {
        let rig = LoopRig()
        rig.hourly = { $0 >= 5 * 3600 }
        let times = await rig.run(hours: 12)
        #expect(times.first == 0)
        #expect(times.count >= 2)
        #expect((times.dropFirst().first ?? .infinity) <= 6 * 3600)
    }

    @MainActor
    @Test("a failed fetch, or a cache it could not write, waits the retry interval")
    func failuresBackOff() async {
        for hourly in [true, false] {
            for failure in ["fetch", "cache write"] {
                let rig = LoopRig()
                rig.hourly = { _ in hourly }
                if failure == "fetch" { rig.fetchSucceeds = false } else { rig.cacheWriteSucceeds = false }
                let attempts = await rig.run(hours: 6)
                #expect(attempts.count >= 5, "\(failure), hourly \(hourly)")
                #expect(zip(attempts, attempts.dropFirst())
                    .allSatisfy { $1 - $0 >= PricingRefreshSchedule.retryInterval }, "\(failure), hourly \(hourly)")
            }
        }
    }

    // MARK: - The curated-only reload

    private final class Calls: @unchecked Sendable {
        var reloads = 0
        var generation: UInt64 = 0
    }

    @MainActor
    @Test("a curated-only refresh reloads the cost cache")
    func curatedOnlyRefreshReloads() async {
        let calls = Calls()
        let outcome = await PricingRefreshPass.run(
            refreshCatalog: { false }, refreshCurated: { true }, reload: { calls.reloads += 1 },
            generation: { calls.generation })
        #expect(calls.reloads == 1)
        #expect(outcome.reloaded && outcome.curatedRefreshed && !outcome.catalogRefreshed)

        let catalog = await PricingRefreshPass.run(
            refreshCatalog: { true }, refreshCurated: { false }, reload: { calls.reloads += 1 },
            generation: { calls.generation })
        #expect(calls.reloads == 2 && catalog.reloaded)

        let neither = await PricingRefreshPass.run(
            refreshCatalog: { false }, refreshCurated: { false }, reload: { calls.reloads += 1 },
            generation: { calls.generation })
        #expect(calls.reloads == 2)
        #expect(neither == .nothing)
    }

    @MainActor
    @Test("new prices are reported only when the reload installed them")
    func pricesChangedFollowsTheGeneration() async {
        let calls = Calls()
        let changed = await PricingRefreshPass.run(
            refreshCatalog: { false }, refreshCurated: { true },
            reload: { calls.generation += 1 }, generation: { calls.generation })
        #expect(changed.pricesChanged)
        let same = await PricingRefreshPass.run(
            refreshCatalog: { true }, refreshCurated: { true },
            reload: {}, generation: { calls.generation })
        #expect(!same.pricesChanged)
    }

    // MARK: - The "price pending" mark

    @MainActor
    @Test("publishing reaches the views' copy, costless models only")
    func publishReachesTheBoard() async {
        let board = PricePending()
        let hub = Self.hub(freshStore(), Sender(), board: board, enabled: false)
        hub.publish(UnpricedModels.State(unpriced: ["claude-sonnet-5-6", "claude-costed-1"],
                                         costless: ["claude-sonnet-5-6"], firstDay: [:]))
        #expect(await eventually(timeout: .seconds(60)) { board.models == ["claude-sonnet-5-6"] })
        hub.publish(.empty)
        #expect(await eventually(timeout: .seconds(60)) { board.models.isEmpty })
    }

    @Test("a state from the rollup: first day, and costed models left unmarked")
    func stateFromRows() {
        let rows: [(model: String, date: String, cost: Double)] = [
            ("claude-new-1", "2026-11-20", 0), ("claude-new-1", "2026-11-18", 0),
            ("claude-costed-1", "2026-11-21", 0.4), ("claude-opus-4-7", "2026-01-01", 3),
        ]
        let state = UnpricedModels.State(unpriced: ["claude-new-1", "claude-costed-1"], rows: rows)
        #expect(state.costless == ["claude-new-1"])
        #expect(state.firstDay == ["claude-new-1": "2026-11-18", "claude-costed-1": "2026-11-21"])
    }

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

    @Test("only a Claude model is promised a price")
    func helpPromisesOnlyClaudeModels() {
        #expect(PacerPricePending.help(["claude-sonnet-5-6", "claude-sonnet-5-6[1m]"])
                == "No price yet for Sonnet 5.6; costs update once one is published")
        let other = PacerPricePending.help(["glm-4.6"]) ?? ""
        #expect(other.hasPrefix("No price for "))
        #expect(!other.contains("update"))
        let alias = PacerPricePending.help(["claude-sonnet-acme-prod"]) ?? ""
        #expect(alias.hasPrefix("No price for ") && !alias.contains("update"))
        let both = PacerPricePending.help(["claude-sonnet-5-6", "glm-4.6"]) ?? ""
        #expect(both.hasPrefix("No price yet for Sonnet 5.6; costs update once one is published. No price for "))
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

    // MARK: - The scan hands the state on

    private final class Published: @unchecked Sendable {
        let states = Mutex<[UnpricedModels.State]>([])
        var sets: [Set<String>] { states.withLock { $0.map(\.unpriced) } }
    }

    @ScanActor
    @Test("the scan hands on the unpriced state after its first cycle and on changes only")
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
                                     onUnpricedModels: { s in published.states.withLock { $0.append(s) } }),
                resolver: ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": root.path]))
        }
        // The reconcile reads the daily rollup before the cycle recomputes it,
        // so on an empty store the first cycle has nothing pending and the
        // model shows up at the next; a third cycle changes nothing.
        let first = coordinator(.calculate)
        _ = try await first.runOnce()
        _ = try await first.runOnce()
        _ = try await first.runOnce()
        #expect(published.sets == [[], [model]])
        let state = try #require(published.states.withLock { $0.last })
        #expect(state.costless == [model])
        #expect(state.firstDay == [model: TokenSample.formatDate(Date())])

        // A relaunch hands it on again: nothing is published at launch.
        _ = try await coordinator(.calculate).runOnce()
        #expect(published.sets == [[], [model], [model]])

        // Display mode prices nothing, so nothing is pending.
        _ = try await coordinator(.display).runOnce()
        #expect(published.sets.last == [])
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
