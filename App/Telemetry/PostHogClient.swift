import Foundation
import PacerCore
import Synchronization

/// Pacer's own PostHog client: a small on-disk queue posted to `/batch/`.
/// Usage data only ("Usage data" toggle); crash and performance data go to
/// Sentry (`TelemetryController`). Plan and every event:
/// docs/telemetry-plan.md, "PostHog".
///
/// **Why not posthog-ios.** It supports macOS via SPM, but its package links a
/// vendored PLCrashReporter (a second crash reporter beside Sentry's signal
/// handlers), libwebp for session replay, and swizzling and remote-config /
/// feature-flag fetches that are on by default. We need none of it, and we
/// would still have to wrap every call for the send caps, the scrubber, the
/// live toggle and per-event timestamps (CLI runs are sent with the time they
/// ran). The capture API this needs is one documented POST.
///
/// **Behaviour**:
/// - `enqueue` appends to memory and to `queue.json` in the App Group
///   container (`PostHog/`), so a quit or crash loses nothing; at most
///   `maxQueued` events are kept (oldest dropped, counted).
/// - A send is scheduled `flushDelay` after the first queued event (or at
///   once past `flushAt` events): no timer runs while the queue is empty, so
///   idle CPU stays at zero.
/// - 2xx or a 4xx other than 429 removes the batch (a payload the server
///   refuses would otherwise retry forever); anything else keeps it and backs
///   off, doubling up to an hour.
/// - The toggle is read again when sending: off clears the queue unsent.
final class PostHogClient: Sendable {

    static let maxQueued = 1_000
    static let batchSize = 100
    static let flushAt = 20
    static let flushDelay: Duration = .seconds(30)

    struct Config: Sendable {
        let token: String
        let batchURL: URL
        let queueURL: URL?
        let context: AnalyticsPayload.Context
        let allowed: @Sendable () -> Bool
    }

    private struct State {
        var queue: [Data] = []
        var loaded = false
        var scheduled = false
        var inFlight = false
        var backoff: TimeInterval = 0
        var nextAttempt = Date.distantPast
    }

    private let config: Config
    private let state = Mutex(State())
    private let session: URLSession

    init(config: Config) {
        self.config = config
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.httpAdditionalHeaders = ["Content-Type": "application/json"]
        session = URLSession(configuration: c)
    }

    // MARK: - Queue

    func enqueue(_ event: AnalyticsEvent) {
        let item = AnalyticsPayload.item(event, context: config.context)
        guard let data = try? JSONSerialization.data(withJSONObject: item) else { return }
        let (dropped, flushNow) = state.withLock { s -> (Int, Bool) in
            load(&s)
            s.queue.append(data)
            let over = max(s.queue.count - Self.maxQueued, 0)
            if over > 0 { s.queue.removeFirst(over) }
            return (over, s.queue.count >= Self.flushAt)
        }
        if dropped > 0 { TelemetryCounters.add("telemetry.analytics.queue_dropped", dropped) }
        persist()
        if flushNow { flush() } else { scheduleFlush() }
    }

    /// Called at start: events left from the last run go out soon.
    func resume() {
        let pending = state.withLock { s -> Bool in load(&s); return !s.queue.isEmpty }
        if pending { scheduleFlush() }
    }

    /// The usage toggle went off: nothing queued may leave.
    func discardAll() {
        state.withLock { s in load(&s); s.queue.removeAll() }
        persist()
    }

    private func scheduleFlush() {
        let schedule = state.withLock { s -> Bool in
            guard !s.scheduled else { return false }
            s.scheduled = true
            return true
        }
        guard schedule else { return }
        Task.detached(priority: .utility) { [self] in
            try? await Task.sleep(for: Self.flushDelay)
            state.withLock { $0.scheduled = false }
            flush()
        }
    }

    // MARK: - Send

    /// Sends one batch. `completion` runs when the request finishes (or at
    /// once when there was nothing to send).
    func flush(completion: (@Sendable () -> Void)? = nil) {
        guard config.allowed() else {
            discardAll()
            completion?()
            return
        }
        let batch = state.withLock { s -> [Data]? in
            load(&s)
            guard !s.inFlight, !s.queue.isEmpty, Date() >= s.nextAttempt else { return nil }
            s.inFlight = true
            return Array(s.queue.prefix(Self.batchSize))
        }
        guard let batch else { completion?(); return }
        let items = batch.compactMap { try? JSONSerialization.jsonObject(with: $0) }
        guard let body = try? JSONSerialization.data(
            withJSONObject: ["api_key": config.token, "batch": items]) else {
            state.withLock { $0.inFlight = false }
            completion?()
            return
        }
        var request = URLRequest(url: config.batchURL)
        request.httpMethod = "POST"
        request.httpBody = body
        session.dataTask(with: request) { [self] _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            let delivered = error == nil && status.map { (200..<300).contains($0) } == true
            let refused = status.map { (400..<500).contains($0) && $0 != 429 } == true
            let more = state.withLock { s -> Bool in
                s.inFlight = false
                if delivered || refused {
                    s.queue.removeFirst(min(batch.count, s.queue.count))
                    s.backoff = 0
                    s.nextAttempt = .distantPast
                } else {
                    s.backoff = min(max(s.backoff * 2, 300), 3_600)
                    s.nextAttempt = Date().addingTimeInterval(s.backoff)
                }
                return (delivered || refused) && !s.queue.isEmpty
            }
            if refused { TelemetryCounters.add("telemetry.analytics.refused_\(status ?? 0)", batch.count) }
            persist()
            if more { scheduleFlush() }
            completion?()
        }.resume()
    }

    /// On quit: write the queue, then give one send up to `timeout`. Events
    /// that do not make it go with the next launch, with their own timestamps.
    func flushBeforeExit(timeout: TimeInterval) {
        persist(wait: true)
        let done = DispatchSemaphore(value: 0)
        flush { done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }

    // MARK: - Disk

    private func load(_ s: inout State) {
        guard !s.loaded else { return }
        s.loaded = true
        guard let url = config.queueURL, let data = try? Data(contentsOf: url),
              let list = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return }
        let saved = list.compactMap { try? JSONSerialization.data(withJSONObject: $0) }
        s.queue = Array((saved + s.queue).suffix(Self.maxQueued))
    }

    /// Writes run one at a time, each taking the queue as it is when it
    /// runs, so an older snapshot never lands after a newer one.
    private let disk = DispatchQueue(label: "com.ericandrechek.pacer.posthog-queue", qos: .utility)

    private func persist(wait: Bool = false) {
        if wait { disk.sync { write() } } else { disk.async { [self] in write() } }
    }

    private func write() {
        guard let url = config.queueURL else { return }
        let snapshot = state.withLock { $0.queue }
        let items = snapshot.compactMap { try? JSONSerialization.jsonObject(with: $0) }
        guard let data = try? JSONSerialization.data(withJSONObject: items) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
