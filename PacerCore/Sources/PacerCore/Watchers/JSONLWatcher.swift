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

    public init(mode: Mode = .live(latencySeconds: 0.5, backstopInterval: 60)) {
        self.mode = mode
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
            FileHandle.standardError.write(
                Data("[JSONLWatcher] FSEventStream failed to start; relying on backstop only\n".utf8)
            )
        }

        // 60s backstop. Always emits — no coalesce — so even if FSEvents
        // drops events, the consumer sees something to process.
        backstopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(backstopInterval * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.emitDirect()
            }
        }
    }

    /// Called from the FS callback when any path-changed event arrives.
    /// Sets a pending timestamp and (re)arms the coalesce task. If
    /// further events arrive within the coalesce window, the task is
    /// restarted — only the trailing edge fires a trigger.
    private func coalesceTrigger() {
        pendingFSEventArrivedAt = Date()
        coalesceTask?.cancel()
        coalesceTask = Task { [weak self] in
            // 500ms window. Burst writes (many JSONL appends in quick
            // succession) collapse into a single trigger; isolated
            // writes still fire after 500ms latency.
            try? await Task.sleep(nanoseconds: 500_000_000)
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
