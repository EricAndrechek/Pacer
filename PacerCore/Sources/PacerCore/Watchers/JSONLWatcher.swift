import Foundation

/// Watches each resolved Claude Code `projects/` directory for changes
/// and emits debounced "scan now" triggers. Two sources push triggers:
///
///   1. `FSEventStreamWrapper` — sub-second reactivity to live writes.
///      A 500ms coalesce window means burst writes (e.g. a session
///      writing many lines in quick succession) collapse into one
///      trigger.
///   2. A 60s polling timer — backstop for missed FSEvents. macOS will
///      coalesce events aggressively under load and occasionally drop
///      them entirely; the timer guarantees we'll re-scan at least
///      once a minute regardless.
///
/// The actor exposes a single `AsyncStream<Date>` that consumers iterate.
/// Yielded values are `Date()` at the moment the trigger fired —
/// purely informational, the consumer ignores the value and just kicks
/// off a scan.
public actor JSONLWatcher {

    /// Test seam: tests inject `.manual` to drive triggers themselves
    /// without spinning up real FSEventStreams or 60s timers.
    public enum Mode: Sendable {
        case live(latencySeconds: CFTimeInterval, backstopInterval: TimeInterval)
        case manual
    }

    private let mode: Mode
    private var fsEvents: FSEventStreamWrapper?
    private var backstopTask: Task<Void, Never>?
    private var coalesceTask: Task<Void, Never>?
    private var continuation: AsyncStream<Date>.Continuation?
    /// Outermost FS event arrival not yet flushed. The coalesce task
    /// reads this when it wakes up to decide whether to emit.
    private var pendingFSEventArrivedAt: Date?
    /// Resolved root paths the live FSEventStream was started against.
    /// Cached so `updateLiveCadence` can restart the stream with a new
    /// latency without re-resolving roots.
    private var liveRootPaths: [String] = []
    /// Live coalesce window in nanoseconds. Used by `coalesceTrigger`
    /// for its `Task.sleep` budget. Tunable at runtime via
    /// `updateLiveCadence(latency:backstopInterval:)` so the
    /// coordinator can widen the window when no user-facing window is
    /// up and snap it back tight when one re-appears.
    private var liveCoalesceNanos: UInt64 = 500_000_000
    /// Live backstop interval — same dynamic update story as
    /// `liveCoalesceNanos`. The backstop task reads this at the top of
    /// each loop iteration, so the next sleep picks up the new value
    /// without restarting the task.
    private var liveBackstopSeconds: TimeInterval = 60

    public init(mode: Mode = .live(latencySeconds: 0.5, backstopInterval: 60)) {
        self.mode = mode
        // Seed the dynamic knobs from the initial config so tests and
        // production share the same start-state semantics.
        if case .live(let lat, let backstop) = mode {
            self.liveCoalesceNanos = UInt64(max(0, lat) * 1_000_000_000)
            self.liveBackstopSeconds = backstop
        }
    }

    /// Adjust the live-mode cadence at runtime. No-op in `.manual` mode
    /// or when `start()` hasn't been called yet (FSEvents latency is
    /// re-applied by tearing down and restarting the stream; backstop
    /// picks up on its next sleep). The coordinator calls this when
    /// the user opens / closes the main window so live-write latency
    /// only stays tight while someone is actually watching.
    public func updateLiveCadence(
        latencySeconds: CFTimeInterval,
        backstopInterval: TimeInterval
    ) {
        guard case .live = mode else { return }
        liveCoalesceNanos = UInt64(max(0, latencySeconds) * 1_000_000_000)
        liveBackstopSeconds = backstopInterval
        // Restart FSEvents with the new latency if we already have a
        // running stream. The wrapper's latency is set at create-time
        // (FSEventStreamCreate) so we can't mutate it in place.
        if fsEvents != nil, !liveRootPaths.isEmpty {
            fsEvents?.stop()
            fsEvents = nil
            // Restart with the same handler shape used in startLive
            // — we hop back into the actor to coalesce, same as before.
            let watcher = FSEventStreamWrapper(handler: { [weak self] _ in
                guard let self else { return }
                Task { await self.coalesceTrigger() }
            })
            if watcher.start(paths: liveRootPaths, latencySeconds: latencySeconds) {
                fsEvents = watcher
            } else {
                Log.write("JSONLWatcher", "FSEventStream failed to restart at latency=\(latencySeconds); relying on backstop only")
            }
        }
    }

    /// Returns the trigger stream. Call this BEFORE `start()` so the
    /// continuation is wired up before any events can arrive.
    public func triggers() -> AsyncStream<Date> {
        // If a previous stream existed, finish it. (Should be rare —
        // typically called once per actor lifetime.)
        continuation?.finish()
        let (stream, continuation) = AsyncStream<Date>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.continuation = continuation
        return stream
    }

    /// Begin watching. For `.live`, opens an FSEventStream over each
    /// root and starts the 60s backstop timer. For `.manual`, no-op
    /// (tests call `manualTrigger()` to push events).
    public func start(roots: [ClaudePathResolver.ResolvedRoot]) {
        switch mode {
        case .live(let latency, let backstop):
            startLive(roots: roots, latency: latency, backstopInterval: backstop)
        case .manual:
            break
        }
    }

    public func stop() {
        fsEvents?.stop()
        fsEvents = nil
        backstopTask?.cancel()
        backstopTask = nil
        coalesceTask?.cancel()
        coalesceTask = nil
        continuation?.finish()
        continuation = nil
        liveRootPaths = []
    }

    /// Test hook: emit a synthetic trigger as if from FSEvents. Only
    /// usable in `.manual` mode (other modes ignore for safety).
    public func manualTrigger() {
        guard case .manual = mode else { return }
        continuation?.yield(Date())
    }

    // MARK: - Live mode

    private func startLive(
        roots: [ClaudePathResolver.ResolvedRoot],
        latency: CFTimeInterval,
        backstopInterval: TimeInterval
    ) {
        let pathStrings = roots.map { $0.projectsDirectory.path }
        guard !pathStrings.isEmpty else { return }
        liveRootPaths = pathStrings

        // FSEvents: arms `coalesceTrigger()` on every batch of
        // file-system events. The handler hops back into the actor
        // because the FS callback fires on its own dispatch queue.
        let watcher = FSEventStreamWrapper(handler: { [weak self] _ in
            guard let self else { return }
            Task { await self.coalesceTrigger() }
        })
        let started = watcher.start(paths: pathStrings, latencySeconds: latency)
        if started {
            self.fsEvents = watcher
        } else {
            Log.write("JSONLWatcher", "FSEventStream failed to start; relying on backstop only")
        }

        // Backstop loop reads the live interval at the top of each
        // iteration so `updateLiveCadence` picks up before the next
        // sleep. Initial value comes from the seeded `mode`.
        liveBackstopSeconds = backstopInterval
        backstopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = await self?.currentBackstopSeconds() else { return }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.emitDirect()
            }
        }
    }

    /// Actor-local read for the backstop loop. Avoids `self?` capture
    /// shenanigans in the Task's `Task.sleep` argument.
    private func currentBackstopSeconds() -> TimeInterval {
        liveBackstopSeconds
    }

    /// Called from the FS callback when any path-changed event arrives.
    /// Sets a pending timestamp and (re)arms the coalesce task. If
    /// further events arrive within the coalesce window, the task is
    /// restarted — only the trailing edge fires a trigger.
    ///
    /// Coalesce window is read from `liveCoalesceNanos`, which
    /// `updateLiveCadence` can widen when the main window is hidden —
    /// no point in sub-second latency to update a UI that nobody is
    /// looking at.
    private func coalesceTrigger() {
        pendingFSEventArrivedAt = Date()
        let nanos = liveCoalesceNanos
        coalesceTask?.cancel()
        coalesceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            if Task.isCancelled { return }
            await self?.flushPending()
        }
    }

    private func flushPending() {
        guard pendingFSEventArrivedAt != nil else { return }
        pendingFSEventArrivedAt = nil
        continuation?.yield(Date())
    }

    private func emitDirect() {
        continuation?.yield(Date())
    }
}
