import Foundation
import Testing
@testable import PacerCore

@Suite("PostHog analytics: events, payload, scrubbing")
struct AnalyticsTests {

    private let context = AnalyticsPayload.Context(
        distinctId: "0D3C8A41-1F2B-4C5D-9E8F-0123456789AB", appVersion: "0.8.1", appBuild: "42",
        buildConfig: "release", macOS: "26.1")
    private let home = "/Users/alice"

    private func json(_ item: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: item, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Scrubbing fixture

    static let fakeAccountId = "7f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b"
    static let fakeEmail = "alice.smith@example.com"
    static let fakePath = "/Users/alice/Code/acme-secret/app.swift"
    static let fakeProjectDir = "-Users-alice-Code-acme-secret"
    static let fakeToken = "sk-ant-oat01-abcdefghijklmnopqrstuvwxyz0123456789"

    @Test("a fixture full of ids, paths, emails and tokens comes out clean")
    func fixtureClean() throws {
        let attributes: Telemetry.Attributes = [
            "settings.cost_mode": .string("auto"),
            "accounts.count": .int(2),
            "note": .string("failed at \(Self.fakePath) for \(Self.fakeEmail)"),
            "account": .string(Self.fakeAccountId),
            "dir": .string("~/.claude/projects/\(Self.fakeProjectDir)/x.jsonl"),
            "auth": .string("Bearer \(Self.fakeToken)"),
            // Keys that name forbidden data are dropped whatever the value.
            "email": .string("anything"),
            "account_id": .string("anything"),
            "env.path": .string("anything"),
            "project": .string("anything"),
        ]
        let event = AnalyticsEvent.dailyCheckin(
            attributes: attributes,
            person: ["accounts.plans": .string("max_20x"), "org_id": .string(Self.fakeAccountId)],
            setOnce: ["install.first_seen": .string("2026-10-01")])
        let out = try json(AnalyticsPayload.item(event, context: context, home: home))
        for secret in [Self.fakeAccountId, Self.fakeEmail, "alice", "acme-secret", Self.fakeToken, "anything"] {
            #expect(!out.contains(secret), "leaked \(secret)")
        }
        let props = try #require(AnalyticsPayload.item(event, context: context, home: home)["properties"] as? [String: Any])
        for key in ["email", "account_id", "env.path", "project"] { #expect(props[key] == nil) }
        #expect(props["settings.cost_mode"] as? String == "auto")
        #expect(props["accounts.count"] as? Int == 2)
        #expect((props["$set"] as? [String: Any])?["org_id"] == nil)
        #expect((props["$set_once"] as? [String: Any])?["install.first_seen"] as? String == "2026-10-01")
    }

    @Test("every event carries the install id, version, build config and macOS")
    func context_() throws {
        let item = AnalyticsPayload.item(.menubarOpened(), context: context, home: home)
        #expect(item["event"] as? String == "menubar_opened")
        let props = try #require(item["properties"] as? [String: Any])
        #expect(props["distinct_id"] as? String == context.distinctId)
        #expect(props["build.config"] as? String == "release")
        #expect(props["$app_version"] as? String == "0.8.1")
        #expect(props["$os_version"] as? String == "26.1")
        #expect(props["$set"] == nil)
        // The event's own uuid and an ISO timestamp.
        #expect((item["uuid"] as? String).flatMap(UUID.init(uuidString:)) != nil)
        #expect((item["timestamp"] as? String)?.hasSuffix("Z") == true)
    }

    @Test("a CLI run keeps the time it ran")
    func historicalTimestamp() throws {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let run = CLIRunLog.Run(at: at, subcommand: "gate", flags: ["cap"], outcome: .ok,
                                exitCode: nil, milliseconds: 40, source: "api")
        let event = try #require(AnalyticsEvent.cliCommands([run]).first)
        #expect(event.timestamp == at)
        let item = AnalyticsPayload.item(event, context: context, home: home)
        #expect(item["timestamp"] as? String == AnalyticsPayload.timestamp(at))
    }

    // MARK: - Constructors take vocabulary, not free text

    @Test("unknown names become other; free text is tokenized")
    func vocabulary() {
        #expect(AnalyticsEvent.tabViewed(tab: "history", dwellSeconds: 12).properties["tab"] == .string("history"))
        #expect(AnalyticsEvent.tabViewed(tab: "/Users/alice", dwellSeconds: 1).properties["tab"] == .string("other"))
        #expect(AnalyticsEvent.shortcutRun(intent: "GetUsageIntent").properties["intent"] == .string("GetUsageIntent"))
        #expect(AnalyticsEvent.shortcutRun(intent: "Evil intent").properties["intent"] == .string("other"))
        #expect(AnalyticsVocabulary.token("Hello World/x") == "hello_world_x")
        #expect(AnalyticsPayload.cleanString("in ~/Code/acme/x and /Volumes/Ext/acme, 50/50 via /v1/snapshot") == "in <path> and <path> 50/50 via /v1/snapshot")
        #expect(AnalyticsVocabulary.version("0.8.1") == "0.8.1")
        #expect(AnalyticsVocabulary.version("0.8.1 (alice)") == "other")
        #expect(AnalyticsEvent.updateInstalled(from: "0.8.0", to: "0.8.1").properties["to_version"] == .string("0.8.1"))
    }

    @Test("window keys are sent as their kind, never the account part")
    func windowKinds() {
        #expect(AnalyticsVocabulary.windowKind("five_hour") == "five_hour")
        #expect(AnalyticsVocabulary.windowKind("seven_day#\(Self.fakeAccountId)") == "seven_day")
        #expect(AnalyticsVocabulary.windowKind("seven_day_opus") == "scoped")
        let e = AnalyticsEvent.notificationShown(.threshold, window: "five_hour#\(Self.fakeAccountId)")
        #expect(e.properties["window"] == .string("five_hour"))
    }

    @Test("API client family comes from the User-Agent, which is not sent")
    func clientFamily() {
        #expect(AnalyticsVocabulary.clientFamily(userAgent: "curl/8.7.1") == "curl")
        #expect(AnalyticsVocabulary.clientFamily(userAgent: "Prometheus/2.53") == "prometheus")
        #expect(AnalyticsVocabulary.clientFamily(userAgent: "python-requests/2.32") == "python")
        #expect(AnalyticsVocabulary.clientFamily(userAgent: nil) == "none")
        #expect(AnalyticsVocabulary.clientFamily(userAgent: "alice-tool/1") == "other")
        let e = AnalyticsEvent.apiRequest(endpoint: "/v1/session?id=abc", client: "curl", count: 3, day: Date())
        #expect(e.properties["endpoint"] == .string("other"))
    }

    @Test("durations are coarse")
    func coarse() {
        #expect(AnalyticsEvent.coarseSeconds(12.4) == 12)
        #expect(AnalyticsEvent.coarseSeconds(134) == 130)
        #expect(AnalyticsEvent.coarseSeconds(3_629) == 3_600)
        #expect(AnalyticsEvent.coarseSeconds(-1) == 0)
        #expect(AnalyticsEvent.coarseSeconds(10 * 86_400) == 86_400)
    }

    @Test("every event name is snake_case")
    func names() {
        for name in AnalyticsEventName.allCases {
            #expect(name.rawValue.allSatisfy { $0.isLowercase || $0 == "_" }, "\(name.rawValue)")
        }
    }

    // MARK: - Install id

    @Test("install id: reads Sentry's file, or creates one in its format")
    func installId() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ph-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let created = try #require(AnalyticsIdentity.installId(in: dir))
        #expect(UUID(uuidString: created) != nil)
        #expect(AnalyticsIdentity.installId(in: dir) == created)
        try Data("SENTRY-ID\n".utf8).write(to: dir.appendingPathComponent("INSTALLATION"))
        #expect(AnalyticsIdentity.installId(in: dir) == "SENTRY-ID")
    }
}

@Suite("PostHog analytics: CLI, widgets, settings")
struct AnalyticsMappingTests {

    // MARK: - CLI flag names

    static let known: Set<String> = ["cap", "margin", "model", "account", "help", "no-refresh"]

    @Test("flag names only, never values")
    func flagNamesOnly() {
        let args = ["--cap", "50", "--model", "opus-secret", "--account", "alice@example.com", "--no-refresh"]
        let names = CLIRunLog.flagNames(args, known: Self.known)
        #expect(names == ["account", "cap", "model", "no-refresh"])
        #expect(!names.joined().contains("opus"))
        #expect(!names.joined().contains("alice"))
    }

    @Test("--x=value keeps the name; unknown flags and negative numbers are other; -h is help")
    func flagEdgeCases() {
        #expect(CLIRunLog.flagNames(["--cap=50"], known: Self.known) == ["cap"])
        #expect(CLIRunLog.flagNames(["--secret-token", "x"], known: Self.known) == ["other"])
        #expect(CLIRunLog.flagNames(["--margin", "-5"], known: Self.known) == ["margin", "other"])
        #expect(CLIRunLog.flagNames(["-h"], known: Self.known) == ["help"])
        #expect(CLIRunLog.flagNames(["status", "-", "x"], known: Self.known) == [])
    }

    @Test("start lines carry flag names and round-trip; old lines still parse")
    func flagLines() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cli-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        CLIRunLog.recordStart(runId: "a1", subcommand: "gate", flags: ["cap", "model"], at: at, to: url)
        CLIRunLog.recordEnd(runId: "a1", subcommand: "gate", exitCode: 2, milliseconds: 1_500,
                            source: .api, at: at.addingTimeInterval(1.5), to: url)
        CLIRunLog.recordStart(runId: "b2", subcommand: "status", at: at.addingTimeInterval(5), to: url)
        CLIRunLog.recordEnd(runId: "b2", subcommand: "status", exitCode: 0, milliseconds: 30,
                            source: .offline, at: at.addingTimeInterval(5.03), to: url)
        let lines = CLIRunLog.lines(at: url)
        #expect(lines.first?.flags == ["cap", "model"])
        let runs = CLIRunLog.runs(lines, since: at.addingTimeInterval(-1), until: at.addingTimeInterval(3_600))
        #expect(runs.count == 2)
        #expect(runs[0].outcome == .other && runs[0].exitCode == 2)
        #expect(runs[1].outcome == .ok && runs[1].flags.isEmpty)
        let events = AnalyticsEvent.cliCommands(runs)
        #expect(events[0].properties["flags"] == .list([.string("cap"), .string("model")]))
        #expect(events[0].properties["duration_bucket"] == .string("1000_2000"))
        #expect(events[1].properties["source"] == .string("offline"))
    }

    @Test("a busy day is thinned to the cap with a weight that adds back up")
    func cliThinning() {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let runs = (0..<1_000).map {
            CLIRunLog.Run(at: at.addingTimeInterval(Double($0)), subcommand: "status", flags: [],
                          outcome: .ok, exitCode: nil, milliseconds: 20, source: "api")
        }
        let events = AnalyticsEvent.cliCommands(runs)
        #expect(events.count == AnalyticsEvent.cliDailyLimit)
        #expect(events.first?.properties["sample_weight"] == .double(10))
        #expect(events.first?.timestamp == at)
    }

    // MARK: - Widget inventory

    @Test("widget inventory: kind, family, config as our own words")
    func widgetInventory() {
        let items = [
            WidgetInventory.Item(kind: WidgetKinds.paceChart, family: "systemMedium", fields: [
                "primary_window": WidgetInventory.windowField("five_hour"),
                "secondary_window": WidgetInventory.windowField("seven_day_opus#7f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b"),
                "account": "7f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b",
            ]),
            WidgetInventory.Item(kind: WidgetKinds.topProjects, family: "systemLarge", fields: [
                "range": WidgetInventory.rangeField("days7"), "pinned_project": "true",
            ]),
            WidgetInventory.Item(kind: "SomethingElse", family: "systemSmall"),
        ]
        let event = WidgetInventory.event(items, refreshes: [WidgetKinds.paceChart: 12])
        #expect(event.name == "widget_inventory")
        #expect(event.properties["count"] == .int(3))
        guard case .list(let list) = event.properties["widgets"] else { Issue.record("no list"); return }
        let first = list.first { if case .object(let o) = $0 { o["kind"] == .string(WidgetKinds.paceChart) } else { false } }
        guard case .object(let chart) = first else { Issue.record("no chart"); return }
        #expect(chart["primary_window"] == .string("five_hour"))
        #expect(chart["secondary_window"] == .string("scoped"))
        #expect(chart["account"] == nil)
        #expect(event.properties["refreshes.PaceChart"] == .int(12))
        #expect(event.set["widgets.count"] == .int(3))
        #expect(event.set["widgets.kinds"] == .string("PaceChart+TopProjects+other"))
        #expect(WidgetInventory.personProperties([])["widgets.kinds"] == .string("none"))
        #expect(WidgetInventory.windowField(nil) == "default")
        #expect(WidgetInventory.rangeField("days365") == "other")
    }

    @Test("widget tap URL round-trips; other URLs are not taps")
    func widgetTapURL() throws {
        let url = try #require(WidgetTapURL.make(kind: WidgetKinds.paceGauges, family: "systemSmall"))
        #expect(url.absoluteString == "pacer://widget?kind=PaceGaugesWidget&family=systemSmall")
        let tap = try #require(WidgetTapURL.parse(url))
        #expect(tap.kind == WidgetKinds.paceGauges && tap.family == "systemSmall")
        #expect(WidgetTapURL.parse(URL(string: "https://example.com/widget?kind=x")!) == nil)
        let e = AnalyticsEvent.widgetTapped(kind: "Evil", family: "systemSmall")
        #expect(e.properties["kind"] == .string("other"))
    }

    @Test("refresh counts are timeline grants only, in the day")
    func refreshCounts() {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let entries = [
            WidgetRefreshLog.Entry(at: at, event: .timeline, kind: "A", family: "systemSmall", next: nil),
            WidgetRefreshLog.Entry(at: at, event: .snapshot, kind: "A", family: "systemSmall", next: nil),
            WidgetRefreshLog.Entry(at: at.addingTimeInterval(-90_000), event: .timeline, kind: "A", family: "systemSmall", next: nil),
        ]
        #expect(WidgetInventory.refreshCounts(entries, since: at.addingTimeInterval(-10), until: at.addingTimeInterval(10)) == ["A": 1])
    }

    // MARK: - Settings and controls

    @Test("settings: bools and fixed sets send a value; numbers and unknowns do not")
    func settingsDiff() throws {
        let s = try #require(UserDefaults(suiteName: "an-\(UUID().uuidString)"))
        let before = AnalyticsSettings.snapshot(s)
        s.set(true, forKey: PacerPreferenceKeys.notificationsEnabled)
        s.set("calculate", forKey: PacerPreferenceKeys.costMode)
        s.set(81, forKey: PacerPreferenceKeys.dailySummaryHour)
        s.set("30d", forKey: "pacer.history.range")
        s.set("7f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b", forKey: UsageScope.key)
        s.set("secret-token", forKey: PacerPreferenceKeys.apiToken)
        s.set("icon,scoped_pct:opus,five_hour_pct", forKey: PacerPreferenceKeys.menuBarChips)
        let events = AnalyticsSettings.changes(from: before, to: AnalyticsSettings.snapshot(s))
        func find(_ key: String, _ name: String) -> AnalyticsEvent? {
            events.first { $0.properties[key] == .string(name) }
        }
        #expect(find("setting", "notifications")?.properties["value"] == .string("true"))
        #expect(find("setting", "cost_mode")?.properties["value"] == .string("calculate"))
        let hour = try #require(find("setting", "notifications_daily_summary_hour"))
        #expect(hour.properties["value"] == nil)
        #expect(find("setting", "menu_bar_chips")?.properties["value"] == .string("five_hour_pct+icon+scoped"))
        let range = try #require(find("control", "range"))
        #expect(range.name == "control_changed" && range.properties["card"] == .string("history"))
        #expect(range.properties["value"] == .string("30d"))
        #expect(find("control", "account_scope")?.properties["value"] == .string("one"))
        // The API token is not watched at all.
        #expect(events.count == 6)
        #expect(!events.contains { "\($0)".contains("secret-token") || "\($0)".contains("7f1e2d3c") })
        // Nothing changed: nothing sent.
        #expect(AnalyticsSettings.changes(from: AnalyticsSettings.snapshot(s), to: AnalyticsSettings.snapshot(s)).isEmpty)
    }

    @Test("menu bar chips: hidden when empty")
    func chips() {
        #expect(AnalyticsSettings.chipsSummary("") == "hidden")
        #expect(AnalyticsSettings.sendable("weird_style", policy: .fixed(AnalyticsSettings.iconStyles)) == "other")
        #expect(AnalyticsSettings.sendable("/Users/alice", policy: .identifier) == "other")
    }

    @Test("usage counters go to PostHog; health and performance counters stay with Sentry")
    func counterRouting() {
        #expect(CounterRouting.isUsage("ui.tab.history"))
        #expect(CounterRouting.isUsage("intent.GetUsageIntent"))
        #expect(CounterRouting.isUsage("api.route.v1.snapshot"))
        #expect(!CounterRouting.isUsage("ui.click.delay.lt100"))
        #expect(!CounterRouting.isUsage("data.malformed_line"))
        #expect(!CounterRouting.isUsage("telemetry.capped.analytics"))
        #expect(!CounterRouting.isUsage("api.snapshot_ms.lt100"))
    }
}
