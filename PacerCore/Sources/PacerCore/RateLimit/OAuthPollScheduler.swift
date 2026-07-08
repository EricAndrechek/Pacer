import Foundation

/// Pure scheduling policy for the multi-token OAuth poller. No I/O, no
/// clock, no token secrets — it takes the current lane state plus `now`
/// and returns "poll lane N" or "wait S seconds". That keeps every
/// cadence/backoff decision unit-testable the same way the old
/// single-token backoff math was.
///
/// ## What it's balancing
///
/// The `/api/oauth/usage` endpoint is computed live per request (so
/// polling more often genuinely yields fresher numbers) but rate-limited
/// to roughly **one request per 5 minutes per token**, and it advertises
/// no budget headers — over-poll and you eat a ~30-minute throttle with
/// no `Retry-After` hint. (See `docs/oauth-usage-endpoint.md` for the
/// measurements behind these constants.)
///
/// The lever: an account often has **several independent tokens** (Claude
/// Code + Claude Desktop), each with its own budget. So we spread polls
/// across lanes — each lane no more than once per `perTokenMinInterval`
/// (the hard invariant that keeps us off the throttle) — to hit a tighter
/// *effective* endpoint cadence when it matters:
///
///   - **Active** (recent Claude usage): aim for `activeInterval` (~2.5
///     min). Achievable only with ≥2 lanes; with one lane it floors at
///     `perTokenMinInterval`.
///   - **Idle**: relax to `idleInterval` — nothing's moving, so be
///     polite and bank budget. Poll-on-wake (the poller nudging us when
///     usage resumes) makes the idle→active transition feel instant.
public struct OAuthPollScheduler: Sendable {

    public struct Tuning: Sendable, Equatable {
        /// The invariant. No single token is polled more often than this,
        /// ever — this is what keeps every lane off the ~30-min throttle.
        public var perTokenMinInterval: TimeInterval
        /// Target endpoint cadence while actively burning tokens.
        /// Realized only when there are enough lanes to sustain it.
        public var activeInterval: TimeInterval
        /// Endpoint cadence when idle.
        public var idleInterval: TimeInterval
        /// How recent the last activity must be to count as "active".
        /// Wider than `activeInterval` so a short gap between prompts
        /// doesn't drop us out of fast cadence.
        public var activeWindow: TimeInterval
        /// Floor on any returned wait, so a tiny/near-zero delay doesn't
        /// spin the loop.
        public var minWait: TimeInterval

        public init(
            perTokenMinInterval: TimeInterval = 300,
            activeInterval: TimeInterval = 150,
            idleInterval: TimeInterval = 600,
            activeWindow: TimeInterval = 900,
            minWait: TimeInterval = 1
        ) {
            self.perTokenMinInterval = perTokenMinInterval
            self.activeInterval = activeInterval
            self.idleInterval = idleInterval
            self.activeWindow = activeWindow
            self.minWait = minWait
        }
    }

    /// A lane's account relationship to the pool's primary account,
    /// learned from the `anthropic-organization-id` of its responses.
    public enum AccountStatus: Sendable, Equatable {
        /// Not yet polled — eligible, so we poll it once to learn its org.
        case unknown
        /// Confirmed same account as the pool's primary — full member.
        case primary
        /// A different account — excluded from selection and never
        /// persisted, so interleaving can't mix two accounts' usage.
        case foreign
    }

    public struct LaneState: Sendable, Equatable {
        public var lastPolledAt: Date?
        /// Set after a 429/transport failure; the lane is ineligible until
        /// this passes. The poller grows it per-lane on repeated failures.
        public var cooldownUntil: Date?
        public var account: AccountStatus

        public init(lastPolledAt: Date? = nil, cooldownUntil: Date? = nil, account: AccountStatus = .unknown) {
            self.lastPolledAt = lastPolledAt
            self.cooldownUntil = cooldownUntil
            self.account = account
        }
    }

    public enum Decision: Sendable, Equatable {
        case poll(laneIndex: Int)
        case wait(seconds: TimeInterval)
    }

    public let tuning: Tuning
    public init(tuning: Tuning = Tuning()) { self.tuning = tuning }

    /// Decide the next action. Lanes should be ordered by the poller so
    /// that primary-eligible sources (manual override / Claude Code
    /// keychain) come first — ties in "least-recently-polled" break by
    /// index, so a never-polled primary lane is picked before a
    /// never-polled Desktop lane, letting the primary establish the
    /// account the pool is guarded against.
    public func decide(lanes: [LaneState], lastActivityAt: Date?, now: Date) -> Decision {
        // Non-foreign lanes are the only ones we can ever poll.
        let usableIdx = lanes.indices.filter { lanes[$0].account != .foreign }
        guard !usableIdx.isEmpty else { return .wait(seconds: tuning.idleInterval) }

        let active = lastActivityAt.map { now.timeIntervalSince($0) <= tuning.activeWindow } ?? false
        let target = active ? tuning.activeInterval : tuning.idleInterval

        // When the endpoint-cadence gate next allows a poll: the most
        // recent poll of any usable lane + target. No prior poll ⇒ now.
        let lastEndpointPoll = usableIdx.compactMap { lanes[$0].lastPolledAt }.max()
        let endpointReady = lastEndpointPoll?.addingTimeInterval(target) ?? .distantPast

        // When each lane individually becomes eligible again (per-token
        // invariant + cooldown), and the earliest such time overall.
        func laneReadyAt(_ l: LaneState) -> Date {
            let byInterval = l.lastPolledAt?.addingTimeInterval(tuning.perTokenMinInterval) ?? .distantPast
            let byCooldown = l.cooldownUntil ?? .distantPast
            return max(byInterval, byCooldown)
        }
        let earliestLaneReady = usableIdx.map { laneReadyAt(lanes[$0]) }.min() ?? .distantPast

        // We may poll no sooner than BOTH gates allow.
        let nextPoll = max(endpointReady, earliestLaneReady)
        if now < nextPoll {
            return .wait(seconds: max(tuning.minWait, nextPoll.timeIntervalSince(now)))
        }

        // Due: pick the eligible lane polled longest ago (never-polled
        // sorts oldest), ties broken by index (primary-first ordering).
        let eligible = usableIdx.filter { laneReadyAt(lanes[$0]) <= now }
        let pick = eligible.min { a, b in
            let la = lanes[a].lastPolledAt ?? .distantPast
            let lb = lanes[b].lastPolledAt ?? .distantPast
            return la != lb ? la < lb : a < b
        }
        // `eligible` is non-empty because earliestLaneReady ≤ nextPoll ≤ now.
        return .poll(laneIndex: pick ?? usableIdx[0])
    }
}
