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
    /// `.jsonl` paths observed via FSEvents since the last
    /// `consumeChangedPaths()`. Accumulated in the FS callback and
    /// drained by `ScanCoordinator` immediately before each scan,
    /// then passed to `JSONLScanner.scan` as a hint so the scanner
    /// can stat just those paths instead of walking the whole
    /// `~/.claude/projects/` tree.
    ///
    /// **Stored off-actor under `pathsLock`** rather than on the actor
    /// directly — `consumeChangedPaths()` is on a hot path called once
    /// per scan from MainActor, and going through an actor hop was
    /// adding 100+ ms of suspend/resume latency when MainActor was
    /// contended by SwiftUI rendering. The lock protects a Set<String>
    /// shared between the FS-callback dispatch queue (writes) and
    /// MainActor (reads via consumeChangedPaths). Both critical
    /// sections are microseconds, so contention is negligible.
    private let pathsLock = NSLock()
    /// `nonisolated(unsafe)` because we manage thread-safety via
    /// `pathsLock`, not actor isolation. Reads and writes must take
    /// the lock; nothing else may touch this field.
    nonisolated(unsafe) private var changedPaths: Set<String> = []
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
            // — we hop back into the actor to coalesce + record paths,
            // same as before. The path-recording side feeds
            // `JSONLScanner`'s hinted-paths fast path; without it the
            // restart variant would silently lose hints whenever the
            // user opens/closes the main window (which triggers a
            // latency change).
            let watcher = FSEventStreamWrapper(handler: { [weak self] paths in
                guard let self else { return }
                Task { await self.recordChangedPathsAndCoalesce(paths) }
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
        let watcher = FSEventStreamWrapper(handler: { [weak self] paths in
            guard let self else { return }
            Task { await self.recordChangedPathsAndCoalesce(paths) }
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

    /// Same as `coalesceTrigger` but first records the FS-reported
    /// paths (filtered to `.jsonl`) into `changedPaths`. The scanner
    /// uses this set as a hint so it can stat just the affected files
    /// instead of walking the whole projects tree — the difference
    /// between a ~300ms scan floor and a single-digit-ms one on a
    /// machine with ~900 cursored JSONL files.
    private func recordChangedPathsAndCoalesce(_ paths: [String]) {
        // FSEvents reports any path under the watched root —
        // directories, renames, attribute changes, non-jsonl
        // files. Filter to `.jsonl` here so the hint set never
        // contains paths the scanner would just ignore. The
        // scanner's own existence/stat checks handle further
        // races (file deleted between event and scan).
        //
        // **Suppress the coalesce trigger when no `.jsonl` paths
        // were in this batch** — FSEvents fires on many path types
        // (xattrs, lock files, sibling-directory mtime touches) that
        // can't possibly add usage data, and waking the scan loop
        // for them was producing the cascading-MainActor-pressure
        // we measured under heavy Claude Code activity: every
        // unnecessary scan triggered a context.save, which fanned a
        // @Query refresh storm out to every visible view, which kept
        // MainActor pegged enough that the NEXT scan's phase timings
        // (autoA, prep, scan) inflated 10-50x. Filtering at the
        // trigger source breaks the loop. Backstop ticks still
        // catch anything FSEvents missed.
        var foundJsonl = false
        pathsLock.lock()
        for path in paths where path.hasSuffix(".jsonl") {
            changedPaths.insert(path)
            foundJsonl = true
        }
        pathsLock.unlock()
        if foundJsonl {
            coalesceTrigger()
        }
    }

    /// Drain and return `.jsonl` paths observed since the last call.
    /// Called by `ScanCoordinator` at the top of each cycle before it
    /// hands the set to `JSONLScanner.scan(hintedPaths:)`. An empty
    /// return signals "scan everything" (backstop tick, manual
    /// trigger, or no FS events between this and the prior scan).
    ///
    /// `nonisolated` so MainActor doesn't pay an actor-hop suspend on
    /// every scan cycle. Thread-safety comes from `pathsLock`. This
    /// shaved ~100-150 ms off scan-cycle latency on machines under UI
    /// pressure — the previous actor-isolated form was waiting for
    /// the watcher actor to be free, which serialized behind FSEvents
    /// callbacks during active Claude Code writes.
    public nonisolated func consumeChangedPaths() -> Set<String> {
        pathsLock.lock()
        let out = changedPaths
        changedPaths.removeAll(keepingCapacity: true)
        pathsLock.unlock()
        return out
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
