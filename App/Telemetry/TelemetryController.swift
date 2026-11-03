import Foundation
import Observation
import PacerCore
@preconcurrency import Sentry

/// Crash reports and usage data, sent to Pacer's Sentry project. The plan,
/// the decisions behind it and every signal are in docs/telemetry-plan.md;
/// the rules for adding a signal are in AGENTS.md → Telemetry.
///
/// **When it runs**: the user's own app only (`LaunchMode.isNormalLaunch`),
/// with a DSN in Info.plist (`PacerSentryDSN`; empty for builds from source),
/// unless `PACER_TELEMETRY=off`, and only when at least one of the two
/// Settings → Privacy toggles is on. Both default to on.
///
/// **The toggles are read on every send**, not at start: turning one off stops
/// that kind of data immediately without restarting the SDK (sentry-cocoa does
/// not document start-after-close as supported). With both off at launch the
/// SDK never starts.
///
/// **What it never does**: automatic network, file or Core Data capture (the
/// OAuth poller carries a bearer token, and file spans carry paths), screenshots,
/// view hierarchies, forwarding `Log` lines. Everything that leaves goes through
/// `TelemetryScrubber`.
@MainActor
final class TelemetryController {

    static let shared = TelemetryController()

    private(set) var isRunning = false
    private var sessionDay: String?
    private var observers: [NSObjectProtocol] = []

    /// Freeze and MetricKit reports count against the free plan's error quota;
    /// a Mac stuck in a bad state could send hundreds a day.
    private static let hangCap = DailyCap(kind: "hang", limit: 2)

    // MARK: - Start

    func startIfAllowed() {
        guard !isRunning, LaunchMode.isNormalLaunch else { return }
        guard ProcessInfo.processInfo.environment["PACER_TELEMETRY"] != "off" else { return }
        guard let dsn = Self.dsn else { return }
        let store = PacerPreferences.store
        guard PacerPreferences.telemetryCrashReportsEnabled(from: store)
                || PacerPreferences.telemetryUsageDataEnabled(from: store) else { return }

        SentrySDK.start { options in
            Self.configure(options, dsn: dsn)
        }
        isRunning = true
        Telemetry.install(SentryTelemetrySink())
        tagScope()
        if Self.usageAllowed { startSession() }
        observe()
        Log.write("Telemetry", "started · \(Self.environment) · crash=\(Self.crashAllowed) usage=\(Self.usageAllowed)")
    }

    /// Ends the day's session and sends what is queued before the app quits.
    /// Bounded: quitting must not wait on the network.
    func prepareForTermination() {
        guard isRunning else { return }
        if sessionDay != nil { SentrySDK.endSession() }
        sessionDay = nil
        SentrySDK.flush(timeout: 2)
    }

    /// Scope tags every crash, hang and MetricKit report carries.
    /// `arena.cpu_mode` follows the arena's governor (full core when plugged
    /// in and idle, a fifth otherwise), so a CPU report says which was on.
    /// PacerCore only calls the closure on a change; here it is a tag write.
    private func tagScope() {
        SentrySDK.configureScope { $0.setTag(value: Self.buildConfig, key: "build.config") }
        let tag: @Sendable (String) -> Void = { mode in
            SentrySDK.configureScope { $0.setTag(value: mode, key: "arena.cpu_mode") }
        }
        ArenaBudgetGovernor.onModeChange = tag
        if let mode = ArenaBudgetGovernor.lastModeName { tag(mode) }
    }

    // MARK: - Options

    private static func configure(_ o: Options, dsn: String) {
        o.dsn = dsn
        o.releaseName = release
        o.environment = environment
        // Eric's decision (2026-10-21): collect the IP so Sentry can say where
        // users are (country/city). It also attaches Sentry's install id to
        // logs and metrics, which is what counts distinct Macs.
        o.sendDefaultPii = true
        // Shared with nothing today, but in the App Group so cache cleaners do
        // not reset the install id and the CLI can read it for problem reports.
        o.cacheDirectoryPath = cacheDirectory
        // Sessions are one per Mac per day, managed below. Sentry's automatic
        // ones start when the app becomes active, which a menu-bar app rarely
        // is, so they would count window opens instead of running Macs.
        o.enableAutoSessionTracking = false

        o.enableUncaughtNSExceptionReporting = true
        o.enableAppHangTracking = true
        o.appHangTimeoutInterval = 2
        o.enableMetricKit = true

        // Off: everything automatic that could carry a token, a path or a
        // project name. (Screenshots, view hierarchies and UI-interaction
        // tracing are iOS-only options; the macOS SDK has none to turn off.)
        o.enableSwizzling = false
        o.enableNetworkTracking = false
        o.enableNetworkBreadcrumbs = false
        o.enableCaptureFailedRequests = false
        o.tracePropagationTargets = []
        o.enableFileIOTracing = false
        o.enableCoreDataTracing = false
        o.enableAutoBreadcrumbTracking = false
        o.enableAutoPerformanceTracing = false
        o.enableLogs = false
        o.maxBreadcrumbs = 50

        // Only transactions we start ourselves exist, and each says whether it
        // is sampled (`SentryTelemetrySink`); everything else is dropped.
        o.tracesSampler = { context in
            (context.customSamplingContext?[SentryTelemetrySink.sampleKey] as? NSNumber) ?? 0
        }

        o.beforeSend = { event in
            guard TelemetryController.crashAllowed else { return nil }
            if TelemetryController.isHangLike(event),
               !TelemetryController.hangCap.take(on: TokenSample.formatDate(Date()), store: PacerPreferences.store) {
                return nil
            }
            TelemetryController.scrub(event)
            return event
        }
        o.beforeBreadcrumb = { crumb in
            if let message = crumb.message { crumb.message = TelemetryScrubber.scrub(message) }
            return crumb
        }
        o.beforeSendSpan = { span in
            // Spans arrive only inside transactions we built; scrub their data
            // anyway, since a description can quote an error.
            if let description = span.spanDescription { span.spanDescription = TelemetryScrubber.scrub(description) }
            return span
        }
        o.beforeSendMetric = { metric in
            TelemetryController.usageAllowed ? metric : nil
        }
    }

    nonisolated private static func isHangLike(_ event: Event) -> Bool {
        guard let mechanism = event.exceptions?.first?.mechanism?.type else { return false }
        return mechanism == "AppHang" || mechanism.hasPrefix("mx_")
    }

    nonisolated private static func scrub(_ event: Event) {
        if let message = event.message?.formatted {
            event.message = SentryMessage(formatted: TelemetryScrubber.scrub(message))
        }
        for exception in event.exceptions ?? [] {
            if let value = exception.value { exception.value = TelemetryScrubber.scrub(value) }
        }
        for crumb in event.breadcrumbs ?? [] {
            if let message = crumb.message { crumb.message = TelemetryScrubber.scrub(message) }
        }
        if let extra = event.extra { event.extra = TelemetryScrubber.scrub(extra) }
        if let tags = event.tags { event.tags = tags.mapValues { TelemetryScrubber.scrub($0) } }
    }

    // MARK: - Toggles, read live

    nonisolated static var crashAllowed: Bool {
        PacerPreferences.telemetryCrashReportsEnabled(from: PacerPreferences.store)
    }
    nonisolated static var usageAllowed: Bool {
        PacerPreferences.telemetryUsageDataEnabled(from: PacerPreferences.store)
    }

    // MARK: - Sessions: one per Mac per local day

    private func startSession() {
        // `startSession` ends the open one cleanly (`exited`) before starting,
        // so a day change is one call.
        SentrySDK.startSession()
        sessionDay = PacerToday.shared.key
    }

    private func observe() {
        // Day rollover: PacerToday already turns NSCalendarDayChanged and wake
        // into a published day key, so no timer of our own.
        trackDay()
        // The usage toggle: end the session when it goes off, start one when
        // it comes back on.
        let store = PacerPreferences.store
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncSessionWithToggle() }
        })
    }

    private func trackDay() {
        withObservationTracking {
            _ = PacerToday.shared.key
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.sessionDay != nil, self.sessionDay != PacerToday.shared.key, Self.usageAllowed {
                    self.startSession()
                }
                self.trackDay()
            }
        }
    }

    private func syncSessionWithToggle() {
        let on = Self.usageAllowed
        if on, sessionDay == nil {
            startSession()
        } else if !on, sessionDay != nil {
            SentrySDK.endSession()
            sessionDay = nil
        }
    }

    // MARK: - Identity

    nonisolated static var dsn: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "PacerSentryDSN") as? String,
              raw.hasPrefix("https://") else { return nil }
        return raw
    }

    /// Debug builds are `make install` builds: they stay out of the real
    /// numbers, and their version (0.3.0 + a timestamp) means nothing.
    nonisolated static var environment: String {
        #if DEBUG
        "development"
        #else
        "production"
        #endif
    }

    /// `debug` for `make install` builds, `release` for shipped ones.
    nonisolated static var buildConfig: String {
        #if DEBUG
        "debug"
        #else
        "release"
        #endif
    }

    nonisolated static var release: String {
        #if DEBUG
        "com.ericandrechek.pacer@dev"
        #else
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        return "com.ericandrechek.pacer@\(version)+\(build)"
        #endif
    }

    nonisolated static var cacheDirectory: String {
        if let group = try? PacerStore.sharedContainerURL().appendingPathComponent("Sentry", isDirectory: true) {
            try? FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
            return group.path
        }
        return NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first ?? ""
    }
}
