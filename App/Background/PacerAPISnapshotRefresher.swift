import Foundation
import Observation
import PacerCore

/// Keeps the HTTP API's `PacerAPISnapshotCache` current, so no request ever
/// waits on the store (#191).
///
/// Builds run one at a time on their own serial queue — never the server's
/// listener queue, never a request worker, never the main actor — and each
/// build makes its own `ModelContext` there, so nothing non-`Sendable` crosses
/// a thread. What comes back is a value, swapped into the cache whole.
///
/// **What asks for a rebuild**, and why each one:
/// - `start`, so the first answer is not a 503 for longer than one build;
/// - `.pacerScanCycleDidComplete` — new turns, and also every rate-limit
///   write: `OAuthPoller` posts it (with `rateLimitsChanged`) after each save
///   that inserted rows, at the same moment it bumps `RateLimitWriteSignal`,
///   and the archive fold posts it too;
/// - `.pacerEngineDidRecompute` — fresh projections. This one also re-sends
///   the SSE snapshot, which is when the stream has always pushed;
/// - an active-login change. Nothing posts one, so this watches
///   `UsageScope.activeAccountId` through Observation — the unscoped
///   payload's limits are whichever login that names;
/// - a 15 s timer, for what changes with no event at all: a session ageing
///   out of "active", the day rolling over, an engine export going stale.
///
/// **Coalesced.** At most one build in flight; any number of triggers during
/// it become exactly one more build after it. A burst of notifications
/// arriving together (a poll lands, then the scan cycle it caused) is one
/// rebuild, not three, and a store stall produces one stuck build rather than
/// a pile of them.
///
/// **A failed build keeps the previous snapshot.** Stale is the whole point:
/// it beats a 503, and its age is on every answer.
final class PacerAPISnapshotRefresher: @unchecked Sendable {

    /// Backstop cadence for state that changes without an event.
    static let interval: TimeInterval = 15
    /// Least time between the starts of two builds. A trigger that lands just
    /// after one finished waits out the rest of this rather than starting a
    /// second pass over the same rows.
    static let minimumSpacing: TimeInterval = 2
    /// A timer tick this soon after a build started skips: that build already
    /// did the tick's job.
    static let timerSkipWindow: TimeInterval = 5
    /// Builds slower than this are logged — the symptom #191 left no trace of.
    static let slowBuild: TimeInterval = 2

    let cache: PacerAPISnapshotCache

    /// `.workItem` so the SwiftData objects a build autoreleases are drained
    /// after every build rather than whenever the thread exits.
    private let buildQueue = DispatchQueue(label: "com.ericandrechek.pacer.http.snapshot",
                                           qos: .utility,
                                           autoreleaseFrequency: .workItem)

    private let lock = NSLock()
    // Everything below is guarded by `lock`.
    private var running = false
    /// Bumped by every start and stop, so a build that straddles one cannot
    /// land a snapshot read before it.
    private var generation: UInt64 = 0
    private var inFlight = false
    private var pending = false
    private var pendingBroadcast = false
    private var lastStartedAt: Date?
    private var announcedFirstBuild = false
    private var onBroadcast: (@Sendable (PacerAPISnapshot) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var timer: DispatchSourceTimer?
    private var accountWatch: Task<Void, Never>?

    init(cache: PacerAPISnapshotCache) {
        self.cache = cache
    }

    // MARK: - Lifecycle

    /// Start refreshing; `onBroadcast` receives each snapshot the SSE stream
    /// should push, on the build queue. Restarting replaces the previous run.
    func start(onBroadcast: @escaping @Sendable (PacerAPISnapshot) -> Void) {
        stop()

        let center = NotificationCenter.default
        // `queue: nil`: the handler only flips flags under a lock, so it runs
        // on the poster's thread rather than hopping anywhere.
        let newObservers = [
            center.addObserver(forName: .pacerScanCycleDidComplete, object: nil, queue: nil) {
                [weak self] _ in self?.trigger()
            },
            center.addObserver(forName: .pacerEngineDidRecompute, object: nil, queue: nil) {
                [weak self] _ in self?.trigger(broadcast: true)
            },
        ]

        let newTimer = DispatchSource.makeTimerSource(queue: buildQueue)
        newTimer.schedule(deadline: .now() + Self.interval, repeating: Self.interval,
                          leeway: .seconds(1))
        newTimer.setEventHandler { [weak self] in self?.timerFired() }

        let watch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await Self.nextActiveAccountChange()
                guard !Task.isCancelled, let self else { return }
                self.trigger()
            }
        }

        lock.withLock {
            running = true
            generation &+= 1
            announcedFirstBuild = false
            // The first build is pushed to the stream as well: a client that
            // connected before any snapshot existed got headers and nothing
            // else, and would otherwise wait for the next engine refit.
            pendingBroadcast = true
            self.onBroadcast = onBroadcast
            observers = newObservers
            timer = newTimer
            accountWatch = watch
        }
        newTimer.resume()
        trigger()
    }

    /// Stop refreshing and drop the snapshot: the API is off, and one kept
    /// until it is switched back on could be hours old.
    func stop() {
        let (oldObservers, oldTimer, oldWatch) = lock.withLock {
            running = false
            generation &+= 1
            pending = false
            pendingBroadcast = false
            onBroadcast = nil
            // Under the lock, so a build finishing now sees the new generation
            // and cannot put its snapshot back after this.
            cache.clear()
            let old = (observers, timer, accountWatch)
            observers = []
            timer = nil
            accountWatch = nil
            return old
        }
        for observer in oldObservers { NotificationCenter.default.removeObserver(observer) }
        oldTimer?.cancel()
        // The watch is parked on an observation that only resumes on the next
        // change; it exits then, without triggering, because it was cancelled.
        oldWatch?.cancel()
    }

    // MARK: - Triggers

    /// Ask for a rebuild. Cheap and callable from any thread: it never builds
    /// on the caller's thread and never waits on one in progress.
    func trigger(broadcast: Bool = false) {
        let delay: TimeInterval? = lock.withLock {
            guard running else { return nil }
            pending = true
            if broadcast { pendingBroadcast = true }
            guard !inFlight else { return nil }
            inFlight = true
            return delayBeforeNextBuild(now: Date())
        }
        if let delay { schedule(after: delay) }
    }

    private func timerFired() {
        let recent = lock.withLock {
            lastStartedAt.map { Date().timeIntervalSince($0) < Self.timerSkipWindow } ?? false
        }
        if !recent { trigger() }
    }

    /// Must hold `lock`.
    private func delayBeforeNextBuild(now: Date) -> TimeInterval {
        guard let lastStartedAt else { return 0 }
        return max(0, Self.minimumSpacing - now.timeIntervalSince(lastStartedAt))
    }

    private func schedule(after delay: TimeInterval) {
        buildQueue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.runBuild() }
    }

    @MainActor
    private static func nextActiveAccountChange() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = UsageScope.shared.activeAccountId
            } onChange: {
                continuation.resume()
            }
        }
    }

    // MARK: - Build (on `buildQueue`)

    private func runBuild() {
        let job: (generation: UInt64, broadcast: Bool)? = lock.withLock {
            guard running, pending else {
                inFlight = false
                return nil
            }
            pending = false
            let broadcast = pendingBroadcast
            pendingBroadcast = false
            lastStartedAt = Date()
            return (generation, broadcast)
        }
        guard let job else { return }

        let startedAt = Date()
        let result = Result { try PacerAPISnapshot.build(now: startedAt) }
        let elapsed = Date().timeIntervalSince(startedAt)

        typealias Outcome = (wanted: Bool, first: Bool,
                             broadcast: PacerAPISnapshot?,
                             handler: (@Sendable (PacerAPISnapshot) -> Void)?,
                             next: TimeInterval?)
        let outcome: Outcome = lock.withLock {
            // A stop or restart while this was building: its rows may predate
            // whatever the user changed, so it is dropped rather than served.
            let wanted = running && generation == job.generation
            var first = false
            if wanted, case .success(let snapshot) = result {
                // Swapped in under the lock that `stop` clears under, so the
                // two cannot interleave. Readers only ever take the cache's
                // own lock, never this one.
                cache.store(snapshot)
                first = !announcedFirstBuild
                announcedFirstBuild = true
            }
            // On a failure the previous snapshot is still the best answer, and
            // a recompute is still worth telling subscribers about. With no
            // snapshot at all the push waits for the next build that lands.
            var broadcast: PacerAPISnapshot?
            if wanted && job.broadcast {
                broadcast = cache.current
                if broadcast == nil { pendingBroadcast = true }
            }
            var next: TimeInterval?
            if running && pending {
                next = delayBeforeNextBuild(now: Date())
            } else {
                inFlight = false
            }
            return (wanted, first, broadcast, onBroadcast, next)
        }

        if outcome.wanted {
            let ms = Int(elapsed * 1000)
            switch result {
            case .success:
                if outcome.first {
                    Log.write("HTTPServer", "snapshot ready in \(ms) ms")
                } else if elapsed >= Self.slowBuild {
                    Log.write("HTTPServer", "snapshot build took \(ms) ms")
                }
            case .failure(let error):
                Log.write("HTTPServer", "snapshot build failed after \(ms) ms, keeping the previous one: \(error)")
            }
        }
        if let snapshot = outcome.broadcast, let handler = outcome.handler {
            handler(snapshot)
        }
        if let next = outcome.next { schedule(after: next) }
    }
}
