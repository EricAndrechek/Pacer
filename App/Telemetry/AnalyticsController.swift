import Foundation
import PacerCore

/// Starts the PostHog side of telemetry: product usage events, under the
/// "Usage data" toggle. Crash and performance data are `TelemetryController`'s
/// (Sentry). Plan and every event: docs/telemetry-plan.md, "PostHog".
///
/// **When it runs**: the user's own app only (`LaunchMode.isNormalLaunch`),
/// with a token and host in Info.plist (`PacerPostHogToken`,
/// `PacerPostHogHost`; empty for builds from source), unless
/// `PACER_TELEMETRY=off`. It installs its sink whatever the toggle says,
/// because the toggle is read on every send: turning "Usage data" on later
/// needs no restart, and turning it off drops what is queued.
///
/// **Identity**: `distinct_id` is Sentry's install id (the `INSTALLATION` file
/// in Sentry's App Group cache folder), so one Mac is the same person in both
/// tools. If Sentry has not run yet (crash reports off), the file is created
/// in Sentry's own format and Sentry adopts it later.
@MainActor
final class AnalyticsController {

    static let shared = AnalyticsController()

    private(set) var client: PostHogClient?
    private var observer: NSObjectProtocol?
    private var lastUsage: Bool?

    var isRunning: Bool { client != nil }

    func startIfAllowed() {
        guard client == nil, LaunchMode.isNormalLaunch,
              ProcessInfo.processInfo.environment["PACER_TELEMETRY"] != "off",
              let token = Self.token, let host = Self.host,
              let id = AnalyticsIdentity.installId(in: URL(fileURLWithPath: TelemetryController.cacheDirectory))
        else { return }
        TelemetryConsent.migrate(store: PacerPreferences.store)
        #if DEBUG
        TelemetryBudget.shared.useLimits(.debug)
        #endif
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let context = AnalyticsPayload.Context(
            distinctId: id,
            appVersion: Self.appVersion,
            appBuild: info["CFBundleVersion"] as? String ?? "0",
            buildConfig: TelemetryController.buildConfig,
            macOS: "\(os.majorVersion).\(os.minorVersion)")
        let queueURL = try? PacerStore.sharedContainerURL()
            .appendingPathComponent("PostHog", isDirectory: true)
            .appendingPathComponent("queue.json")
        AnalyticsProfile.shared.use(fileURL: queueURL?.deletingLastPathComponent()
            .appendingPathComponent("profile.json"))
        let client = PostHogClient(config: .init(
            token: token, batchURL: host.appendingPathComponent("batch/"),
            queueURL: queueURL, context: context,
            allowed: { TelemetryController.analyticsAllowed }))
        self.client = client
        Analytics.install(PostHogAnalyticsSink(client: client))
        client.resume()
        lastUsage = TelemetryController.analyticsAllowed
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: PacerPreferences.store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncWithToggle() }
        }
        Log.write("Telemetry", "analytics started · usage=\(TelemetryController.analyticsAllowed)")
    }

    /// Off the main thread for the same reason as
    /// `TelemetryController.prepareForTermination`: it waits up to 2 s on the
    /// network, `HangWatch`'s threshold.
    func prepareForTermination() async {
        guard let client else { return }
        await Task.detached(priority: .userInitiated) { client.flushBeforeExit(timeout: 2) }.value
    }

    /// Turned off: nothing already queued may leave.
    private func syncWithToggle() {
        let on = TelemetryController.analyticsAllowed
        guard on != lastUsage else { return }
        lastUsage = on
        if !on { client?.discardAll() }
    }

    // MARK: - Configuration

    nonisolated static var token: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "PacerPostHogToken") as? String,
              raw.hasPrefix("phc_") else { return nil }
        return raw
    }

    nonisolated static var host: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "PacerPostHogHost") as? String,
              raw.hasPrefix("https://"), let url = URL(string: raw) else { return nil }
        return url
    }

    nonisolated static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
}

/// Where `Analytics.capture` goes in the app: toggle, then caps, then the
/// install's profile as `$set`, then the queue (which scrubs through `AnalyticsPayload`).
struct PostHogAnalyticsSink: Analytics.Sink {
    let client: PostHogClient

    func capture(_ event: AnalyticsEvent) {
        guard TelemetryController.analyticsAllowed,
              TelemetryBudget.shared.takeAnalytics(event: event.name) else { return }
        client.enqueue(AnalyticsProfile.shared.stamped(event, live: AnalyticsUsage.personProperties()))
    }
}
