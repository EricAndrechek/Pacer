import AppKit
import Darwin
import Foundation
import Observation
import PacerCore
import ServiceManagement
import SwiftData
import WidgetKit

/// The daily check-in: one `app.heartbeat` span per Mac per local day, plus
/// the metrics that only make sense once a day (CLI runs, forecast accuracy,
/// counters). Plan and the approved field list: docs/telemetry-plan.md
/// ("Signals", "Metrics catalog").
///
/// **When**: at launch if nothing was sent today (after a short settle delay so
/// it never competes with startup), and on the `PacerToday` day rollover. No
/// timer of its own. The last-sent day is persisted, so quitting and
/// relaunching all day sends once.
///
/// **What it never carries**: account or org ids, emails, project names,
/// paths, costs or exact token counts. Plan tier, window kind and model id are
/// our own enumerable values; accounts are only ever labelled by a local index
/// (1, 2, 3 by creation order) that exists for this one send.
///
/// **Cost**: all store reads are one-shot fetches in a detached task with its
/// own `ModelContext`, a day's rows at most. Nothing here runs per scan cycle.
@MainActor
final class DailyCheckIn {

    static let shared = DailyCheckIn()

    private var container: ModelContainer?
    private var engines: EngineHost?
    private var started = false
    private var sending = false
    private let launchedAt = Date()
    private var cpuSecondsAtLastCheckIn: Double = 0

    private static let lastDayKey = "pacer.telemetry.checkin.lastDay"
    private static let runningKey = "pacer.telemetry.lifecycle.running"
    private static let launchesKey = "pacer.telemetry.lifecycle.launches"
    private static let uncleanKey = "pacer.telemetry.lifecycle.unclean"
    private static let settleDelay: Duration = .seconds(30)

    // MARK: - Start

    func start(container: ModelContainer, engines: EngineHost) {
        guard !started, TelemetryController.shared.isRunning else { return }
        started = true
        self.container = container
        self.engines = engines
        Self.recordLaunch()
        trackDay()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            await self?.runIfDue()
        }
    }

    private func trackDay() {
        withObservationTracking {
            _ = PacerToday.shared.key
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                await self.runIfDue()
                self.trackDay()
            }
        }
    }

    // MARK: - Lifecycle markers

    /// A launch whose predecessor never wrote the clean-exit marker is an
    /// unclean exit (crash, force quit, power loss). Sparkle's relaunch goes
    /// through `applicationShouldTerminate`, so it counts as clean.
    private static func recordLaunch() {
        let store = PacerPreferences.store
        launchOrigin.record(store: store)
        if store.bool(forKey: runningKey) { store.set(store.integer(forKey: uncleanKey) + 1, forKey: uncleanKey) }
        store.set(store.integer(forKey: launchesKey) + 1, forKey: launchesKey)
        store.set(true, forKey: runningKey)
    }

    /// How this process was launched. Captured in `applicationWillFinishLaunching`
    /// because `currentAppleEvent` is only the launch event that early; read
    /// by `recordLaunch` once telemetry has started. Main-thread only.
    private static var launchOrigin = LaunchOrigin.manual

    static func captureLaunchOrigin() {
        let event = NSAppleEventManager.shared().currentAppleEvent
        // kAEOpenApplication carrying keyAELaunchedAsLogInItem is what
        // launchd's login-item launch sends.
        let saysLogin = event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
                == OSType(keyAELaunchedAsLogInItem)
        launchOrigin = LaunchOrigin.classify(
            appleEventSaysLogin: saysLogin,
            loginItemEnabled: SMAppService.mainApp.status == .enabled,
            secondsSinceBoot: ProcessInfo.processInfo.systemUptime)
    }

    /// Called from the terminate path once everything has flushed.
    static func markCleanExit() {
        PacerPreferences.store.set(false, forKey: runningKey)
    }

    // MARK: - Send

    private func runIfDue() async {
        guard !sending, TelemetryController.shared.isRunning, TelemetryController.usageAllowed,
              let container, let engines else { return }
        let store = PacerPreferences.store
        let today = PacerToday.shared.key
        guard store.string(forKey: Self.lastDayKey) != today else { return }
        // Marked before the work, not after: a send that takes a while must
        // not be started twice by a rollover landing in the middle of it.
        store.set(today, forKey: Self.lastDayKey)
        sending = true
        defer { sending = false }

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday.addingTimeInterval(-86_400)
        let yesterdayKey = TokenSample.formatDate(startOfYesterday)

        let gatherStart = Date()
        let settings = Self.settingsAttributes(store: store)
            .merging(Self.clientAttributes(AccountClientsStore.current)) { _, new in new }
        let lifecycle = Self.lifecycleAttributes(store: store, launchedAt: launchedAt,
                                                 cpuBefore: cpuSecondsAtLastCheckIn)
        cpuSecondsAtLastCheckIn = Self.cpuSeconds()
        let widgetsStart = Date()
        let widgets = await Self.installedWidgets()
        let widgetsEnd = Date()
        let counters = TelemetryCounters.drain()

        let storeStart = Date()
        let gathered = await Task.detached(priority: .utility) {
            Self.gather(container: container, startOfYesterday: startOfYesterday,
                        startOfToday: startOfToday, yesterdayKey: yesterdayKey)
        }.value
        let storeEnd = Date()

        var attributes: Telemetry.Attributes = ["checkin.day": .string(today)]
        for part in [settings, lifecycle, gathered.attributes, widgets] {
            attributes.merge(part) { _, new in new }
        }
        for (key, n) in counters { attributes["counter.\(key)"] = .int(n) }
        // Which forecast networks this Mac has on disk (stat only): with the
        // accuracy metrics, this is what says whether the ~2.7 GB of large
        // models ever earn their download (docs/telemetry-plan.md).
        attributes["models.present"] = .string(ArenaWeightStore.presentModelIds().joined(separator: ","))

        // A real span with real children, like the scan and engine spans that
        // do reach Sentry: a zero-length childless transaction was dropped on
        // its way there. The children are the two slow parts of gathering.
        // The full snapshot goes as one metric: metrics take attributes and
        // can be grouped and counted per Mac (count_unique(user.id)). The
        // transaction carries only a small core: with ~60 attributes the
        // installed build's heartbeat never reached Sentry (2026-11-02) while
        // every small transaction and every metric did.
        Telemetry.count("checkin.snapshot", 1, attributes: attributes)
        let core = attributes.filter { Self.coreKeys.contains($0.key) }
        Telemetry.span(.init(
            // Not "app.*": Sentry treats app-start-style ops specially, and the
            // "app.heartbeat" transaction never arrived while every other did.
            op: "pacer.checkin", name: "daily check-in", start: gatherStart, end: Date(),
            attributes: core,
            children: [
                .init(op: "checkin.widgets", name: "checkin.widgets", start: widgetsStart, end: widgetsEnd),
                .init(op: "checkin.gather", name: "checkin.gather", start: storeStart, end: storeEnd),
            ]))
        for (key, n) in counters { Telemetry.count(key, n) }
        if let cpu = lifecycle["energy.cpu_seconds"], case .double(let seconds) = cpu {
            Telemetry.gauge("energy.cpu_seconds", seconds, unit: .second)
        }

        Self.sendCLISummary(gathered.cli, since: startOfYesterday, until: startOfToday)
        // Widget build times, from the extension's own log (it has no network).
        for d in WidgetRefreshLog.durations(since: startOfYesterday, until: startOfToday) {
            for ms in TelemetryBands.thinned(d.ms, limit: 200) {
                Telemetry.distribution("widget.timeline_ms", Double(ms), unit: .millisecond,
                                       attributes: ["kind": .string(d.kind), "family": .string(d.family)])
            }
        }
        await sendForecastAccuracy(engines: engines, accounts: gathered.accounts)
    }

    /// The attributes the transaction carries (the snapshot metric carries
    /// all). Span-only because `count_unique(user.id)` works on spans, not
    /// metrics, so whatever the dashboard groups Macs by is here. Keep it
    /// under ~16: ~60 attributes never reached Sentry.
    private static let coreKeys: Set<String> = [
        "checkin.day", "env.macos", "env.model", "env.model_name", "settings.cost_mode",
        "accounts.count", "accounts.plans", "usage.seven_day.peak_band", "usage.five_hour.peak_band",
        "install.first_seen", "install.age_days", "build.config",
    ]

    // MARK: - Settings snapshot

    private static func settingsAttributes(store: UserDefaults) -> Telemetry.Attributes {
        var a: Telemetry.Attributes = [:]
        // Chips are built-in tokens (`five_hour_pct`); a per-model chip's token
        // embeds a model name, so only its count is kept.
        let chips = (store.string(forKey: PacerPreferenceKeys.menuBarChips) ?? "")
            .split(separator: ",").map(String.init)
        let builtIn = chips.filter { !$0.hasPrefix("scoped_pct:") }
        a["settings.menu_bar_chips"] = .string(builtIn.joined(separator: ","))
        a["settings.menu_bar_scoped_chips"] = .int(chips.count - builtIn.count)
        a["settings.menu_bar_icon_style"] = .string(sanitized(store.string(forKey: PacerPreferenceKeys.menuBarIconStyle) ?? ""))
        a["settings.api_server_on"] = .bool(PacerPreferences.apiServerConfig(from: store).enabled)
        a["settings.notifications_on"] = .bool(store.bool(forKey: PacerPreferenceKeys.notificationsEnabled))
        a["settings.cost_mode"] = .string("\(PacerPreferences.costMode(from: store))")
        a["settings.desktop_credentials_on"] = .bool(PacerPreferences.desktopCredentialsEnabled(from: store))
        a["settings.switcher_on"] = .bool(PacerPreferences.switcherCredentialsEnabled(from: store))
        let skillManifest = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/skills/\(ClaudeSkillInstaller.skillName)/\(ClaudeSkillInstaller.manifestName)")
        a["settings.skill_installed"] = .bool(FileManager.default.fileExists(atPath: skillManifest.path))
        return a
    }

    /// Clients on this Mac by kind (CLI login, Desktop installs, pinned
    /// profiles): counts only, from what the scan already published.
    private static func clientAttributes(_ clients: AccountClients) -> Telemetry.Attributes {
        let counts = clients.clientCountsByKind()
        var a: Telemetry.Attributes = [:]
        for kind in [AccountClients.Kind.cli, .desktop, .profile] {
            a["clients.\(kind.rawValue)_count"] = .int(counts[kind] ?? 0)
        }
        return a
    }

    // MARK: - Lifecycle, energy, Sparkle

    private static func lifecycleAttributes(store: UserDefaults, launchedAt: Date,
                                            cpuBefore: Double) -> Telemetry.Attributes {
        var a: Telemetry.Attributes = [:]
        a["lifecycle.restarts"] = .int(store.integer(forKey: launchesKey))
        a["lifecycle.unclean_exits"] = .int(store.integer(forKey: uncleanKey))
        store.set(0, forKey: launchesKey)
        store.set(0, forKey: uncleanKey)
        // Since the last check-in, by how the launch happened.
        let origins = LaunchOrigin.drain(store: store)
        a["lifecycle.launches_login"] = .int(origins.login)
        a["lifecycle.launches_manual"] = .int(origins.manual)
        a["lifecycle.uptime_hours"] = .double((Date().timeIntervalSince(launchedAt) / 360).rounded() / 10)
        a["lifecycle.login_item"] = .bool(SMAppService.mainApp.status == .enabled)
        // Sparkle records its last check in the app's own defaults; reading it
        // needs no change to the updater. Whether the check found an update
        // is not stored there, so only its age is reported.
        if let last = UserDefaults.standard.object(forKey: "SULastCheckTime") as? Date {
            a["lifecycle.sparkle_last_check_hours"] = .int(Int(Date().timeIntervalSince(last) / 3600))
        }
        // What the last update check did (found / no update / download failed /
        // will install / error_<domain>_<code>), from the Sparkle delegate.
        if let update = UpdateOutcomeLog.last(store: store) {
            a["lifecycle.update_result"] = .string(update.result)
            if let version = update.version { a["lifecycle.update_version"] = .string(version) }
        }
        let cpu = max(cpuSeconds() - cpuBefore, 0)
        a["energy.cpu_seconds"] = .double((cpu * 10).rounded() / 10)
        return a
    }

    /// User + system CPU time of this process since launch.
    private static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    // MARK: - Widgets

    private static func installedWidgets() async -> Telemetry.Attributes {
        let names: [String] = await withCheckedContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { result in
                let list = (try? result.get()) ?? []
                continuation.resume(returning: list.map { "\($0.kind):\($0.family)" }.sorted())
            }
        }
        return ["widgets.installed": .string(names.joined(separator: ",")),
                "widgets.count": .int(names.count)]
    }

    // MARK: - Store, files, environment (detached)

    private struct Gathered: Sendable {
        var attributes: Telemetry.Attributes
        var cli: [String: CLIRunLog.CommandStats]
        /// Account id -> (1-based index, plan tier). Lives for this send only.
        var accounts: [String: AccountLabel]
    }

    struct AccountLabel: Sendable {
        let index: Int
        let plan: String
        /// No 5-hour limit on this account (verified Ultra): its 5-hour
        /// forecasts and usage bands are not reported, because there is no
        /// window to be right or wrong about.
        let hasNoFiveHour: Bool
    }

    /// Whether the 5-hour window exists for the scope being reported: for one
    /// account its own flag, for all accounts only when none of them has one.
    /// No accounts yet is "unknown", so the window is kept.
    nonisolated static func reportsFiveHour(accountId: String?, accounts: [String: AccountLabel]) -> Bool {
        CheckInFields.reportsFiveHour(
            scopedHasNoFiveHour: accountId.flatMap { accounts[$0]?.hasNoFiveHour },
            allHaveNoFiveHour: accounts.values.map(\.hasNoFiveHour),
            scopedToAccount: accountId != nil)
    }

    nonisolated private static func gather(container: ModelContainer, startOfYesterday: Date,
                                           startOfToday: Date, yesterdayKey: String) -> Gathered {
        let context = ModelContext(container)
        var a: Telemetry.Attributes = [:]

        // Accounts and plans.
        let accounts = (try? context.fetch(FetchDescriptor<Account>(sortBy: [SortDescriptor(\.firstSeenAt)]))) ?? []
        a["accounts.count"] = .int(accounts.count)
        var labels: [String: AccountLabel] = [:]
        var tiers: [String: Int] = [:]
        var subscriptions: [String: Int] = [:]
        for (i, account) in accounts.enumerated() {
            let tier = sanitized(account.rateLimitTier ?? "unknown")
            labels[account.id] = AccountLabel(
                index: i + 1, plan: tier,
                hasNoFiveHour: LimitSamplePoint.hasNoFiveHourWindow(
                    hasFiveHour: account.latestFiveHourPct != nil,
                    hasSevenDay: account.latestSevenDayPct != nil))
            tiers[tier, default: 0] += 1
            subscriptions[sanitized(account.subscriptionType ?? "unknown"), default: 0] += 1
        }
        a["accounts.plans"] = .string(CheckInFields.plans(tiers: Array(tiers.keys)))
        for (tier, n) in tiers { a["accounts.tier.\(tier)"] = .int(n) }
        for (sub, n) in subscriptions { a["accounts.subscription.\(sub)"] = .int(n) }

        // Usage levels: yesterday's peak per window, banded.
        let rate = (try? context.fetch(FetchDescriptor<RateLimitSample>(
            predicate: #Predicate { $0.sampledAt >= startOfYesterday && $0.sampledAt < startOfToday }))) ?? []
        let fiveHourExists = Self.reportsFiveHour(accountId: nil, accounts: labels)
        for window in ["five_hour", "seven_day"] where fiveHourExists || window != "five_hour" {
            let peak = rate.lazy.filter { $0.window == window }.map(\.usedPercentage).max() ?? 0
            a["usage.\(window).peak_band"] = .int(TelemetryBands.percentBand(peak))
            a["usage.\(window).hit_100"] = .bool(peak >= 100)
            // Whether the app ever told the user "you will hit this limit" on
            // yesterday, from the snapshot trail the engine already writes
            // (`hitClaimed` is what the chip and alerts said). Together with
            // `hit_100` it says if the claim and the outcome agreed. A probe
            // fetch, one row at most, once a day.
            let surface = "rl-\(window)"
            var claimed = FetchDescriptor<PredictionSnapshot>(predicate: #Predicate {
                $0.surface == surface && $0.hitClaimed == true
                    && $0.recordedAt >= startOfYesterday && $0.recordedAt < startOfToday
            })
            claimed.fetchLimit = 1
            let forecastHit = ((try? context.fetchCount(claimed)) ?? 0) > 0
            a["usage.\(window).forecast_hit"] = .bool(forecastHit)
        }
        let rows = (try? context.fetch(FetchDescriptor<DailyAggregate>(
            predicate: #Predicate { $0.date == yesterdayKey }))) ?? []
        var tokens: Int64 = 0
        var models = Set<String>()
        for row in rows where row.model != "<synthetic>" {
            let n = row.inputTokens + row.outputTokens + row.cacheReadTokens
                + row.cacheCreation5mTokens + row.cacheCreation1hTokens
            if n > 0 { models.insert(row.model) }
            tokens += n
        }
        a["usage.models_used"] = .int(models.count)
        a["usage.tokens_magnitude"] = .string(TelemetryBands.magnitude(tokens))

        for (k, v) in environment() { a[k] = v }
        a["build.config"] = .string(TelemetryController.buildConfig)
        for (k, v) in installAttributes(earliestAccount: accounts.first?.firstSeenAt) { a[k] = v }

        let cli = CLIRunLog.summary(CLIRunLog.lines(), since: startOfYesterday, until: startOfToday)
        return Gathered(attributes: a, cli: cli, accounts: labels)
    }

    nonisolated private static func environment() -> Telemetry.Attributes {
        var a: Telemetry.Attributes = [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        a["env.macos"] = .string("\(os.majorVersion).\(os.minorVersion)")
        let model = sysctlString("hw.model")
        a["env.model"] = .string(model)
        a["env.model_name"] = .string(MacModelName.name(for: model))
        a["env.ram_gb"] = .int(Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824))
        a["env.timezone_utc_offset_hours"] = .double(Double(TimeZone.current.secondsFromGMT()) / 3600)

        let home = FileManager.default.homeDirectoryForCurrentUser
        if let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = values.volumeAvailableCapacityForImportantUsage {
            a["env.free_disk_gb_bucket"] = .int(TelemetryBands.gigabytesBucket(bytes: free))
        }

        let fm = FileManager.default
        a["env.has_dot_claude"] = .bool(fm.fileExists(atPath: home.appendingPathComponent(".claude").path))
        a["env.has_config_claude"] = .bool(fm.fileExists(atPath: home.appendingPathComponent(".config/claude").path))
        a["env.claude_config_dir_set"] = .bool(!(ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? "").isEmpty)

        let claudeDirs = (try? ClaudePathResolver().resolve())?.map(\.projectsDirectory) ?? []
        let storeURL = try? PacerStore.storeURL()
        let snapshot = StorageInspector.snapshot(
            storeURL: storeURL, logsDirectory: home.appendingPathComponent("Library/Logs/Pacer"),
            claudeProjectsDirectories: claudeDirs)
        a["env.store_mb_bucket"] = .int(TelemetryBands.megabytesBucket(bytes: snapshot.pacerDatabaseBytes))
        a["env.transcript_files_bucket"] = .int(TelemetryBands.countBucket(snapshot.claudeLogFileCount))
        if let container = try? PacerStore.sharedContainerURL() {
            let archive = StorageInspector.fileAllocatedSize(container.appendingPathComponent("raw-archive.duckdb"))
            a["env.archive_mb_bucket"] = .int(TelemetryBands.megabytesBucket(bytes: archive))
        }
        return a
    }

    /// When this install first ran, from the App Group defaults. An install
    /// that predates the key is backfilled once from the oldest account row
    /// (an ascending `firstSeenAt` sort, so one row; already fetched above, no
    /// extra read). Coarse and ours, not an identifier.
    nonisolated private static func installAttributes(earliestAccount: Date?) -> Telemetry.Attributes {
        let store = PacerPreferences.store
        let now = Date()
        let r = CheckInFields.installFirstSeen(
            stored: store.string(forKey: PacerPreferenceKeys.installFirstSeen),
            earliestEvidence: earliestAccount, now: now)
        if r.save { store.set(r.day, forKey: PacerPreferenceKeys.installFirstSeen) }
        return ["install.first_seen": .string(r.day),
                "install.age_days": .int(CheckInFields.installAgeDays(firstSeen: r.day, now: now))]
    }

    nonisolated private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "unknown" }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Plan tiers and subscription types come from the server as raw strings;
    /// keep them to a safe, short metric-key alphabet.
    nonisolated private static func sanitized(_ raw: String) -> String {
        let allowed = raw.lowercased().map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" }
        return String(String(allowed).prefix(40))
    }

    // MARK: - CLI

    private static let durationCap = 500

    private static func sendCLISummary(_ summary: [String: CLIRunLog.CommandStats], since: Date, until: Date) {
        for (subcommand, stats) in summary {
            let attributes: Telemetry.Attributes = ["subcommand": .string(subcommand)]
            for ms in TelemetryBands.thinned(stats.durationsMs, limit: durationCap) {
                Telemetry.distribution("cli.command_ms", Double(ms), unit: .millisecond, attributes: attributes)
            }
            Telemetry.count("cli.runs", stats.runs, attributes: attributes)
            Telemetry.count("cli.failures", stats.failures, attributes: attributes)
            Telemetry.count("cli.hung", stats.hung, attributes: attributes)
        }
    }

    // MARK: - Forecast accuracy

    /// Per scope (each account, then all accounts) and window kind: the model
    /// that was picked and how it did, read from the compare sheet's board,
    /// which is built from what each engine already holds (no model is run).
    private func sendForecastAccuracy(engines: EngineHost, accounts: [String: AccountLabel]) async {
        for (scope, engine) in engines.all {
            let label = scope.accountId.flatMap { accounts[$0] }
            if scope.accountId != nil, label == nil { continue }
            let scopeName = scope.isAllAccounts ? "all" : "account"
            // The account-wide blocks, then each per-model (scoped) cap the
            // engine fits, named by cadence and model family only.
            var windows: [(key: String, name: String)] = [("seven_day", "seven_day")]
            if Self.reportsFiveHour(accountId: scope.accountId, accounts: accounts) {
                windows.insert(("five_hour", "five_hour"), at: 0)
            }
            windows += await engine.scopedWindowKinds().map { ($0.key, $0.kind) }
            for (windowKey, window) in windows {
                let board = await engine.meterModelBoard(windowKey: windowKey)
                var ranked: [(id: String, miss: Double, isPick: Bool)] = []
                for row in board.rows {
                    switch row.status {
                    case .ranked(let miss, _), .wellBehind(let miss, _):
                        ranked.append((row.id, miss, row.isPick))
                    default: break
                    }
                }
                guard let best = ranked.map({ $0.miss }).min(),
                      let pick = ranked.first(where: { $0.isPick }) else { continue }
                let attributes: Telemetry.Attributes = [
                    "model": .string(pick.id),
                    "window": .string(window),
                    "plan": .string(label?.plan ?? "all"),
                    "account_index": .int(label?.index ?? 0),
                    "scope": .string(scopeName),
                ]
                Telemetry.distribution("forecast.error_pp", pick.miss, attributes: attributes)
                Telemetry.gauge("forecast.gap_to_best_pp", max(pick.miss - best, 0), attributes: attributes)
                Telemetry.gauge("forecast.ranked_models", Double(ranked.count), attributes: attributes)
                Telemetry.gauge("forecast.cycles", Double(board.spanCycles), attributes: attributes)
            }
        }
    }
}
