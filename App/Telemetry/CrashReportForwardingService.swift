import Foundation
import Observation
import PacerCore

/// Forwards crash reports of the processes that cannot report themselves: the
/// widget extension (no network) and the `pacer` CLI (must stay a fast offline
/// process). macOS writes a `.ips` report for every crash; this reads the new
/// ones, turns them into Sentry native events (`CrashReportForwarder`) and
/// posts them to the project's envelope endpoint. See docs/telemetry-plan.md,
/// "Covering the CLI and the widget".
///
/// **Not the app's own crashes** (`Pacer-*.ips`): the SDK sends those, and
/// forwarding them as well would count every crash twice.
///
/// **When**: a few seconds after launch and on the day rollover, only while
/// "Send crash reports" is on. Off the main thread throughout; nothing waits
/// on the network but this task.
///
/// **State** (App Group defaults): a watermark (the newest report handled) so
/// old reports are never re-read, and the last 200 incident ids sent, so a
/// report whose file was touched again is not sent twice.
@MainActor
final class CrashReportForwardingService {

    static let shared = CrashReportForwardingService()

    private var started = false
    private var running = false

    nonisolated private static let watermarkKey = "pacer.telemetry.crashfwd.watermark"
    nonisolated private static let sentKey = "pacer.telemetry.crashfwd.sentIncidents"
    nonisolated private static let sentCap = 200
    nonisolated private static let maxPerRun = 5
    nonisolated private static let maxFileBytes = 2 * 1024 * 1024
    nonisolated private static let firstRunLookback: TimeInterval = 7 * 86_400
    private static let launchDelay: Duration = .seconds(10)

    func start() {
        guard !started, TelemetryController.shared.isRunning else { return }
        started = true
        trackDay()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.launchDelay)
            await self?.run()
        }
    }

    private func trackDay() {
        withObservationTracking {
            _ = PacerToday.shared.key
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                await self.run()
                self.trackDay()
            }
        }
    }

    private func run() async {
        guard !running, TelemetryController.crashAllowed,
              let raw = TelemetryController.dsn, let dsn = SentryEnvelope.DSN(raw) else { return }
        running = true
        defer { running = false }
        let environment = TelemetryController.environment
        await Task.detached(priority: .utility) {
            await Self.forward(dsn: dsn, environment: environment)
        }.value
    }

    // MARK: - Work (off the main thread)

    private struct Candidate { let url: URL; let modified: Date }

    nonisolated private static func forward(dsn: SentryEnvelope.DSN, environment: String) async {
        let store = PacerPreferences.store
        let seeded = store.object(forKey: watermarkKey) as? Double
        var watermark = Date(timeIntervalSince1970: seeded ?? Date().addingTimeInterval(-firstRunLookback).timeIntervalSince1970)
        if seeded == nil { store.set(watermark.timeIntervalSince1970, forKey: watermarkKey) }
        var sent = store.stringArray(forKey: sentKey) ?? []

        var posted = 0
        let found = candidates(after: watermark)
        // One line per scan: the only way to tell "nothing to send" from "the
        // send failed" on someone's Mac (Pacer.err.log).
        defer { Log.write("Telemetry", "crash reports: \(found.count) new, \(posted) forwarded") }
        for candidate in found {
            guard posted < maxPerRun else { break }
            guard let text = readText(candidate.url) else {
                watermark = advance(watermark, to: candidate.modified, store: store)
                continue
            }
            // The same release string the app's own events carry, so a widget
            // or CLI crash sits under the release it shipped in (dev builds
            // report "@dev", as the app does).
            let parsed = CrashReportForwarder.report(fromIPS: text, release: { version, build in
                #if DEBUG
                TelemetryController.release
                #else
                version.isEmpty ? nil : "com.ericandrechek.pacer@\(version)+\(build)"
                #endif
            }, environment: environment)
            // The app's own crashes belong to the SDK; an unparseable report
            // (still being written, hand-edited) is skipped for good.
            guard let report = parsed, report.processName != "Pacer" else {
                watermark = advance(watermark, to: candidate.modified, store: store)
                continue
            }
            if sent.contains(report.incidentId) {
                watermark = advance(watermark, to: candidate.modified, store: store)
                continue
            }
            guard let envelope = SentryEnvelope.event(withIdentity(report.eventJSON)) else {
                watermark = advance(watermark, to: candidate.modified, store: store)
                continue
            }
            let request = SentryEnvelope.request(envelope, dsn: dsn, timeout: 10)
            let response = try? await URLSession.shared.data(for: request)
            let status = (response?.1 as? HTTPURLResponse)?.statusCode
            guard status == 200 else {
                // Network down or refused: stop here so the report is tried
                // again next time instead of being skipped by the watermark.
                // Sentry's error body says which field it rejected; it echoes
                // the payload's structure, not its contents.
                let detail = response.map { String(decoding: $0.0.prefix(300), as: UTF8.self) } ?? ""
                Log.write("Telemetry", "crash report forward failed: HTTP \(status.map(String.init) ?? "none") \(detail)")
                break
            }
            posted += 1
            sent.append(report.incidentId)
            if sent.count > sentCap { sent.removeFirst(sent.count - sentCap) }
            store.set(sent, forKey: sentKey)
            watermark = advance(watermark, to: candidate.modified, store: store)
        }
    }

    /// The Mac's Sentry install id (what the SDK attaches to the app's own
    /// events, from `<cacheDirectoryPath>/INSTALLATION`) and IP inference, so a
    /// forwarded crash counts against the same Mac and location as the app's.
    nonisolated private static func withIdentity(_ eventJSON: Data) -> Data {
        guard var event = (try? JSONSerialization.jsonObject(with: eventJSON)) as? [String: Any] else {
            return eventJSON
        }
        var user: [String: Any] = ["ip_address": "{{auto}}"]
        let file = URL(fileURLWithPath: TelemetryController.cacheDirectory).appendingPathComponent("INSTALLATION")
        if let id = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !id.isEmpty {
            user["id"] = id
        }
        event["user"] = user
        return (try? JSONSerialization.data(withJSONObject: event)) ?? eventJSON
    }

    nonisolated private static func advance(_ current: Date, to date: Date, store: UserDefaults) -> Date {
        guard date > current else { return current }
        store.set(date.timeIntervalSince1970, forKey: watermarkKey)
        return date
    }

    /// Reports for the widget and the CLI newer than the watermark, oldest
    /// first, so the watermark can advance in order.
    nonisolated private static func candidates(after watermark: Date) -> [Candidate] {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        var found: [Candidate] = []
        for directory in [base, base.appendingPathComponent("Retired", isDirectory: true)] {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])) ?? []
            for url in urls {
                let name = url.lastPathComponent
                // "Pacer-" is excluded on purpose; see the type comment.
                guard CrashReportForwarder.isCandidate(fileName: name),
                      name.hasPrefix("PacerWidgets-") || name.hasPrefix("pacer-"),
                      let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate,
                      modified > watermark else { continue }
                found.append(Candidate(url: url, modified: modified))
            }
        }
        return found.sorted { $0.modified < $1.modified }
    }

    nonisolated private static func readText(_ url: URL) -> String? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size <= maxFileBytes, let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
