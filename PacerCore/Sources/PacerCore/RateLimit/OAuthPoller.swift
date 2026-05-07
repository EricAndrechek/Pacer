import Foundation
import SwiftData

/// Abstraction over wall-clock time for the poller's loop. Production
/// uses `SystemPollerClock`. Tests inject a controllable clock so they
/// can drive cadence and backoff without real-time `Task.sleep` calls.
///
/// We don't use Swift's built-in `Clock` protocol here because its
/// associated-type design would force the poller to be generic over
/// `Clock`, which complicates storing and stopping the loop task; a
/// Sendable existential is simpler for a single use site.
public protocol PollerClock: Sendable {
    /// Wall-clock time. Used to compute `nextPollAt` and timestamp
    /// log lines; we never compare clock readings across actors.
    func now() -> Date

    /// Suspend for `seconds`. Must respect `Task.isCancelled` —
    /// `stop()` cancels the loop task and the next sleep needs to
    /// throw `CancellationError` so the loop unwinds quickly.
    func sleep(seconds: TimeInterval) async throws
}

/// Production clock — `Date()` and cooperative `Task.sleep`. Marked
/// `@unchecked Sendable` because it has no mutable state; the
/// `Task.sleep` call participates correctly in cooperative cancellation.
public struct SystemPollerClock: PollerClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(seconds: TimeInterval) async throws {
        // Negative or zero — return immediately. Task.sleep would
        // accept zero but on some platforms negative is undefined.
        if seconds <= 0 {
            try Task.checkCancellation()
            return
        }
        let nanos = UInt64((seconds * 1_000_000_000).rounded())
        try await Task.sleep(nanoseconds: nanos)
    }
}

/// Polls `/api/oauth/usage` on a 5-minute cadence (the server's
/// aggregation interval — faster polling returns stale data) and
/// persists each successful observation as one or two
/// `RateLimitSample` rows (one per window present in the response).
///
/// Backoff state machine on errors:
///
///   - 200 OK with rows                     →  reset backoff, sleep `baseInterval ± jitter`
///   - 429 with Retry-After                  →  sleep max(retryAfter, baseInterval), capped at maxBackoff
///   - 429 without Retry-After               →  exponential backoff (baseInterval × 2^consecutive429s),
///                                              capped at maxBackoff
///   - 401 / network / schema error          →  sleep `baseInterval ± jitter`, no backoff growth
///                                              (these recover on next poll without our help)
///   - credentials missing / token expired   →  sleep `baseInterval ± jitter`, no log spam
///   - keychain access denied                →  sleep `baseInterval ± jitter` (one warn-once
///                                              log; user must approve in foreground app)
///
/// Each successful 200 resets `consecutive429s`. The actor is
/// `start()`/`stop()` symmetrical and safe to call from any context.
public actor OAuthPoller {

    public struct Configuration: Sendable {
        /// Steady-state cadence. 5 minutes matches the server's
        /// aggregation interval — faster polls just return the same
        /// numbers and waste rate-limit budget.
        public var baseInterval: TimeInterval
        /// Jitter range applied to each sleep, ±. Defaults to ±30s so
        /// a fleet of Pacer instances can't synchronize their wakeups
        /// (which would create thundering-herd load on Anthropic's
        /// usage endpoint).
        public var jitterSeconds: TimeInterval
        /// Hard cap on any sleep duration. Even on persistent 429s we
        /// won't sleep longer than this — at the cap, we keep
        /// re-attempting once an hour so a recovering server is
        /// noticed within reasonable time.
        public var maxBackoff: TimeInterval
        /// Optional delay before the first poll. Useful if the daemon
        /// wants the JSONL scanner to settle before kicking off a
        /// network call. Default 0.
        public var startupDelay: TimeInterval

        public init(
            baseInterval: TimeInterval = 5 * 60,
            jitterSeconds: TimeInterval = 30,
            maxBackoff: TimeInterval = 60 * 60,
            startupDelay: TimeInterval = 0
        ) {
            self.baseInterval = baseInterval
            self.jitterSeconds = jitterSeconds
            self.maxBackoff = maxBackoff
            self.startupDelay = startupDelay
        }
    }

    /// Categorized outcome of one poll cycle, surfaced for tests and
    /// for the daemon UI's debug view.
    public enum PollOutcome: Sendable, Equatable {
        case success(fiveHourPct: Double?, sevenDayPct: Double?)
        case credentialsNotFound
        case keychainAccessDenied
        case keychainMalformed
        case keychainStatus(OSStatus)
        case tokenExpired
        case unauthorized
        case rateLimited(retryAfter: TimeInterval?)
        case http(status: Int)
        case transport
        case responseSchemaMismatch
    }

    /// Snapshot of poller state, useful for logging and tests.
    public struct Snapshot: Sendable {
        public let lastOutcome: PollOutcome?
        public let consecutive429s: Int
        public let nextPollAt: Date?
        public let lastPollAt: Date?
    }

    public typealias RandomSource = @Sendable () -> Double

    private let client: OAuthClient
    private let container: ModelContainer
    private let configuration: Configuration
    private let clock: PollerClock
    /// Returns a uniform random value in [0,1). Injected so tests can
    /// freeze jitter to a known value.
    private let random: RandomSource

    private var loopTask: Task<Void, Never>?
    private var consecutive429s: Int = 0
    private var lastOutcome: PollOutcome?
    private var nextPollAt: Date?
    private var lastPollAt: Date?

    public init(
        client: OAuthClient = OAuthClient(),
        container: ModelContainer,
        configuration: Configuration = Configuration(),
        clock: PollerClock = SystemPollerClock(),
        random: @escaping RandomSource = { Double.random(in: 0..<1) }
    ) {
        self.client = client
        self.container = container
        self.configuration = configuration
        self.clock = clock
        self.random = random
    }

    /// Spawn the loop task. Idempotent — calling start twice does
    /// nothing the second time. The loop runs until `stop()` cancels
    /// it.
    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            await self?.loop()
        }
    }

    /// Cancel the loop and wait for it to unwind. Safe to call from
    /// anywhere; idempotent.
    public func stop() async {
        guard let task = loopTask else { return }
        loopTask = nil
        task.cancel()
        await task.value
    }

    /// Test entry — run exactly one fetch + persist + state-update.
    /// Returns the categorized outcome. Does NOT sleep, does NOT loop.
    @discardableResult
    public func runOnce() async -> PollOutcome {
        await runOneCycle()
    }

    /// Read-only view of current poller state. Tests assert against
    /// `nextPollAt` to verify backoff math.
    public func snapshot() -> Snapshot {
        Snapshot(
            lastOutcome: lastOutcome,
            consecutive429s: consecutive429s,
            nextPollAt: nextPollAt,
            lastPollAt: lastPollAt
        )
    }

    // MARK: - Loop

    private func loop() async {
        if configuration.startupDelay > 0 {
            do {
                try await clock.sleep(seconds: configuration.startupDelay)
            } catch {
                return
            }
        }

        while !Task.isCancelled {
            _ = await runOneCycle()

            // sleep until nextPollAt (computed inside runOneCycle).
            let targetDate = nextPollAt ?? clock.now().addingTimeInterval(configuration.baseInterval)
            let remaining = targetDate.timeIntervalSince(clock.now())
            do {
                try await clock.sleep(seconds: remaining)
            } catch {
                // CancellationError or anything else — exit cleanly.
                return
            }
        }
    }

    // MARK: - One cycle

    private func runOneCycle() async -> PollOutcome {
        let result = await client.fetchUsage()
        let now = clock.now()
        lastPollAt = now

        let outcome = await categorize(result)
        lastOutcome = outcome
        let delay = nextDelaySeconds(for: outcome, result: result)
        nextPollAt = now.addingTimeInterval(delay)
        return outcome
    }

    private func categorize(_ result: Result<RateLimitSnapshot, OAuthClientError>) async -> PollOutcome {
        switch result {
        case .success(let snapshot):
            await persist(snapshot)
            consecutive429s = 0
            return .success(
                fiveHourPct: snapshot.fiveHour?.usedPercentage,
                sevenDayPct: snapshot.sevenDay?.usedPercentage
            )
        case .failure(.credentialsNotFound):
            return .credentialsNotFound
        case .failure(.keychainAccessDenied):
            return .keychainAccessDenied
        case .failure(.keychainMalformed):
            return .keychainMalformed
        case .failure(.keychainStatus(let status)):
            return .keychainStatus(status)
        case .failure(.tokenExpired):
            return .tokenExpired
        case .failure(.unauthorized):
            return .unauthorized
        case .failure(.rateLimited(let retryAfter)):
            consecutive429s += 1
            return .rateLimited(retryAfter: retryAfter)
        case .failure(.http(let status, _)):
            return .http(status: status)
        case .failure(.transport):
            return .transport
        case .failure(.responseSchemaMismatch):
            return .responseSchemaMismatch
        }
    }

    // MARK: - Backoff math

    private func nextDelaySeconds(
        for outcome: PollOutcome,
        result: Result<RateLimitSnapshot, OAuthClientError>
    ) -> TimeInterval {
        switch outcome {
        case .rateLimited(let retryAfter):
            // 429 path. Use Retry-After if larger than our exponential
            // schedule; otherwise grow exponentially.
            let exponential = configuration.baseInterval * pow(2.0, Double(consecutive429s - 1))
            let chosen = max(retryAfter ?? 0, exponential)
            return min(chosen, configuration.maxBackoff)
        case .success, .credentialsNotFound, .keychainAccessDenied,
             .keychainMalformed, .keychainStatus, .tokenExpired,
             .unauthorized, .http, .transport, .responseSchemaMismatch:
            return baseIntervalWithJitter()
        }
    }

    private func baseIntervalWithJitter() -> TimeInterval {
        let r = max(0.0, min(1.0, random()))
        let offset = (r * 2.0 - 1.0) * configuration.jitterSeconds
        return max(0, configuration.baseInterval + offset)
    }

    // MARK: - Persistence

    /// Write one row per present window. Called from inside the actor;
    /// hops to the main actor for SwiftData since `ModelContext` is
    /// `@MainActor` in our setup.
    private func persist(_ snapshot: RateLimitSnapshot) async {
        let container = self.container
        let captured = snapshot
        await MainActor.run {
            let context = ModelContext(container)
            if let window = captured.fiveHour {
                context.insert(RateLimitSample(
                    sampledAt: captured.sampledAt,
                    window: RateLimitWindowName.fiveHour,
                    usedPercentage: window.usedPercentage,
                    resetsAt: window.resetsAt,
                    source: RateLimitSource.oauth
                ))
            }
            if let window = captured.sevenDay {
                context.insert(RateLimitSample(
                    sampledAt: captured.sampledAt,
                    window: RateLimitWindowName.sevenDay,
                    usedPercentage: window.usedPercentage,
                    resetsAt: window.resetsAt,
                    source: RateLimitSource.oauth
                ))
            }
            do {
                try context.save()
            } catch {
                // Disk full / migration mid-flight — log to stderr and
                // move on. The next successful poll will write fresh
                // samples; we deliberately don't stop the poller for
                // a single persistence failure.
                Log.write("OAuthPoller", "persist failed: \(error)")
            }
        }
    }
}
