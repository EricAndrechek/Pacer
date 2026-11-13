import Darwin
import Foundation
import PacerCore
// `_spi(Private)` for the two things Sentry's own hang tracker uses to build
// its event: every thread's stack (`threadInspector`) and the binary images
// those stacks need for symbolication (`debugImageProvider`). Both are in the
// shipped xcframework's private interface from 9.30 to 9.33; if a release
// renames them, this file stops compiling rather than reporting less.
@_spi(Private) @preconcurrency import Sentry

/// Turns `HangWatch` events into Sentry reports. Sentry's own hang tracking is
/// off (`TelemetryController.configure`); this replaces it. Why, and how a
/// hang is detected: `HangWatch`.
///
/// - `.began` (the main thread stuck for 2 s and still stuck): an
///   "App Hanging" event with every thread's stack, sent at once, so it
///   reaches Sentry even if the app never gets free. It is the event Sentry's
///   tracker built (same type, mechanism and message), so it joins the same
///   issues, plus a `hang.phase` tag (`launch` or `running`). A marker goes on
///   disk (`HangMarker`).
/// - `.continuing`, every 5 s: the marker's "last seen" moves on.
/// - `.ended`: the length as `main_thread.hang_ms` (`ended=recovered`), a
///   breadcrumb and a log line; the marker goes.
/// - Next launch, marker still there: the app ended while hung (force quit,
///   an update replacing it, a crash): `main_thread.hang_ms` with
///   `ended=terminated` and the length it had reached, with the version that
///   hung.
///
/// Volume: one event per hang, under the `.hang` cap in `beforeSend` (10 a day,
/// 3 on a Debug build); the metric under the per-name metric cap. Nothing runs
/// while the main thread is responsive.
enum HangReporter {

    static let threshold: TimeInterval = 2
    static let heartbeat: TimeInterval = 5

    /// The message Sentry's tracker used, so existing issues keep grouping.
    static let message = "App hanging for at least \(Int(threshold * 1000)) ms."

    /// Called on `HangWatch`'s queue.
    static func handle(_ event: HangWatch.Event) {
        switch event {
        case .began(let hang):
            guard !isBeingTraced else { return }
            writeMarker(for: hang)
            // Every thread's stack, once, for both the send and the log. The
            // log line is written for every hang, sent or not: Sentry's daily
            // cap leaves most hangs with no stack anywhere otherwise.
            let threads = SentryDependencyContainer.sharedInstance().threadInspector
                .getCurrentThreadsWithStackTrace()
            // Displays asleep: counted, not sent (`HangReportPolicy`). The marker
            // and log line stay, so a real force-quit is still reported.
            if TelemetryController.crashAllowed, HangReportPolicy.admit() { capture(hang, threads: threads) }
            Log.write("Hang", "main thread stuck \(Int(hang.duration * 1000)) ms and counting (\(phase(hang)))"
                      + (topFrames(of: threads).map { " · top frames: \($0)" } ?? ""))
        case .continuing:
            guard let url = HangMarker.defaultURL(), var marker = HangMarker.read(at: url) else { return }
            marker.lastSeenAt = Date()
            try? marker.write(to: url)
        case .ended(let hang):
            if let url = HangMarker.defaultURL() { HangMarker.remove(at: url) }
            let ms = hang.duration * 1000
            Telemetry.distribution("main_thread.hang_ms", ms, unit: .millisecond,
                                   attributes: ["phase": .string(phase(hang)), "ended": .string("recovered")])
            Telemetry.breadcrumb("hang", "\(Int(ms)) ms (\(phase(hang)))")
            Log.write("Hang", "main thread was stuck \(Int(ms)) ms (\(phase(hang)))")
        }
    }

    /// A marker the previous process left: it ended while its main thread was
    /// stuck. Its "began" event went when the hang passed 2 s; this adds that
    /// it never came out. Call once at launch, after the sink is installed and
    /// before this process's own watch starts.
    static func reportLeftover() {
        guard let url = HangMarker.defaultURL(), let marker = HangMarker.takeLeftover(at: url) else { return }
        let ms = marker.duration * 1000
        let phase = marker.atLaunch ? "launch" : "running"
        Telemetry.distribution("main_thread.hang_ms", ms, unit: .millisecond,
                               attributes: ["phase": .string(phase), "ended": .string("terminated"),
                                            "version": .string(TelemetryScrubber.scrub(marker.version))])
        Telemetry.breadcrumb("hang", "previous run ended while stuck, \(Int(ms)) ms or more (\(phase))")
        Log.write("Hang", "previous run (\(marker.version)) ended while its main thread was stuck, \(Int(ms)) ms or more (\(phase))")
    }

    private static func phase(_ hang: HangWatch.Hang) -> String { hang.atLaunch ? "launch" : "running" }

    private static func writeMarker(for hang: HangWatch.Hang) {
        guard let url = HangMarker.defaultURL() else { return }
        let now = Date()
        let marker = HangMarker(startedAt: now.addingTimeInterval(-hang.duration), lastSeenAt: now,
                                atLaunch: hang.atLaunch, version: AnalyticsController.appVersion)
        try? marker.write(to: url)
    }

    /// The event `SentryHangTrackingIntegration.anrDetected` builds on macOS,
    /// with a phase tag. Sent even without stacks: a hang with no stack still
    /// says that and when it happened.
    private static func capture(_ hang: HangWatch.Hang, threads: [SentryThread]) {
        let container = SentryDependencyContainer.sharedInstance()
        // Index 0 is the main thread (the inspector puts it first).
        let exception = Exception(value: message, type: "App Hanging")
        exception.mechanism = Mechanism(type: "AppHang")
        if let main = threads.first {
            exception.stacktrace = main.stacktrace
            exception.stacktrace?.snapshot = true
        }
        for (index, thread) in threads.enumerated() { thread.current = NSNumber(value: index == 0) }
        let event = Event(level: .error)
        event.exceptions = [exception]
        if !threads.isEmpty {
            event.threads = threads
            event.debugMeta = container.debugImageProvider.getDebugImagesFromCacheForThreads(threads: threads)
        }
        event.tags = ["hang.phase": phase(hang)]
        SentrySDK.capture(event: event)
    }

    /// The main thread's innermost frames, names only (`HangStackSummary`).
    private static func topFrames(of threads: [SentryThread]) -> String? {
        guard let frames = threads.first?.stacktrace?.frames else { return nil }
        return HangStackSummary.format(frames: frames.map { ($0.function, $0.instructionAddress) })
    }

    /// A debugger stopped at a breakpoint is not a hang.
    private static var isBeingTraced: Bool { DebuggerProbe.isAttached }
}
