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
///   - **Active** (recent Claude usage): the fastest *even* cadence the
///     lanes can sustain — `perTokenMin/lanes` (no floor by default).
///     5 tokens → ~1 min, 10 → ~30s, 2 → ~2.5 min, 1 → 5 min.
///   - **Idle**: relax to `idleInterval` — nothing's moving, so be
///     polite and bank budget. Poll-on-wake (the poller nudging us when
///     usage resumes) makes the idle→active transition feel instant.
///   - **Non-active accounts** (`decideSweep`): every lane at the
///     per-token floor, the account's polls kept `interval / lanes` apart.
public struct OAuthPollScheduler: Sendable {

    public struct Tuning: Sendable, Equatable {
        /// The invariant. No single token is polled more often than this,
        /// ever — this is what keeps every lane off the ~30-min throttle.
        public var perTokenMinInterval: TimeInterval
        /// Optional floor on the active endpoint cadence. Default 0 — no
        /// floor, so more tokens poll strictly faster. The realized active
        /// interval is `max(this, perTokenMinInterval / usableLanes)`; the
        /// per-token invariant (each lane ≤ perTokenMinInterval) is what
        /// actually keeps us off the throttle regardless of this value.
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
        /// The longest Pacer will go without polling a lane itself while
        /// standing aside for another client.
        ///
        /// Standing aside is usually the right trade — the other client's
        /// answer is on disk and costs no budget — but it must not be
        /// unconditional. A client that asks constantly and never succeeds
        /// would otherwise hold a lane down forever, and on an account with a
        /// single token that means Pacer watching its own reading age with no
        /// way out. Fifteen minutes: rare enough not to perpetuate a throttle
        /// (well under one request per five minutes on its own), often enough
        /// to bound staleness and to notice the other client has gone.
        public var externalYieldMax: TimeInterval

        public init(
            perTokenMinInterval: TimeInterval = 300,
            activeInterval: TimeInterval = 0,
            idleInterval: TimeInterval = 600,
            activeWindow: TimeInterval = 900,
            minWait: TimeInterval = 1,
            externalYieldMax: TimeInterval = 900
        ) {
            self.perTokenMinInterval = perTokenMinInterval
            self.activeInterval = activeInterval
            self.idleInterval = idleInterval
            self.activeWindow = activeWindow
            self.minWait = minWait
            self.externalYieldMax = externalYieldMax
        }
    }

    /// A lane's account relationship to the pool, learned from the
    /// `anthropic-organization-id` of its responses.
    public enum AccountStatus: Sendable, Equatable {
        /// Not yet polled — eligible on the fast pool, so we poll it once
        /// to learn its org (and classify it primary vs secondary).
        case unknown
        /// Belongs to the **active** account — a full member of the fast
        /// pool, and the account whose samples drive the live timeline and
        /// all display.
        case primary
        /// Belongs to a tracked **non-active** account. Still polled, but on
        /// the slow background sweep, and its samples are cached on the
        /// `Account` row rather than written into the active timeline — so
        /// interleaving can't mix two accounts' usage. (Legacy rows persist
        /// this as `"foreign"`; it decodes here.)
        case secondary
    }

    public struct LaneState: Sendable, Equatable {
        public var lastPolledAt: Date?
        /// When another client on this machine will next spend this token's
        /// budget, if it publishes a schedule.
        ///
        /// The budget Anthropic enforces is per token, and Pacer is not the
        /// only thing holding these: `cswap` polls the same credentials. Two
        /// clients each politely respecting `perTokenMinInterval` still land
        /// requests seconds apart and both take 429s, because neither counts
        /// the other's.
        ///
        /// Knowing when the other one will go is what turns that from a
        /// collision into a schedule — see `laneReadyAt`. nil when nothing else
        /// is known to be polling, which is the ordinary case.
        public var externalNextPollAt: Date?

        /// When another client last *spent* this token's budget, successfully
        /// or not.
        ///
        /// Separate from `lastPolledAt`, which is Pacer's own poll and nothing
        /// else. Folding the two together — which is what the poller used to do
        /// — loses the distinction the probe floor needs, and leaks one
        /// account's external activity onto the endpoint-cadence gate that all
        /// its lanes share, delaying tokens the other client never touches.
        public var externalLastPollAt: Date?

        /// When another client last *got an answer* on this token: a reading
        /// Pacer has also taken in. That is fresh data Pacer didn't have to
        /// spend budget on, so it counts toward "Pacer has a recent reading" in
        /// `overdueForOwnPoll`.
        ///
        /// Without it, an account whose only token cswap polls looked
        /// permanently overdue: every sample came from cswap, Pacer's own
        /// `lastPolledAt` never moved, so Pacer kept probing straight past
        /// cswap's announced schedule. On 2026-10-07 the two polled the active
        /// account's token 38 s apart, both took a 429, and its reading went
        /// 14 minutes stale (#207).
        public var externalLastSuccessAt: Date?

        /// Set after a 429/transport failure; the lane is ineligible until
        /// this passes. The poller grows it per-lane on repeated failures.
        public var cooldownUntil: Date?
        public var account: AccountStatus

        /// The lane holds the token Claude Code is billing now, has never been
        /// polled, and its account is unknown. `decide` polls it ahead of the
        /// endpoint-cadence gate: the poll that says who is signed in (#214).
        public var probeFirst: Bool

        public init(lastPolledAt: Date? = nil, cooldownUntil: Date? = nil,
                    externalNextPollAt: Date? = nil, externalLastPollAt: Date? = nil,
                    externalLastSuccessAt: Date? = nil,
                    account: AccountStatus = .unknown,
                    probeFirst: Bool = false) {
            self.probeFirst = probeFirst
            self.externalNextPollAt = externalNextPollAt
            self.externalLastPollAt = externalLastPollAt
            self.externalLastSuccessAt = externalLastSuccessAt
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
        // The *fast pool* the scheduler drives is the active account's lanes
        // (`.primary`) plus not-yet-classified ones (`.unknown`, polled once
        // to learn their org). `.secondary` lanes belong to non-active
        // accounts and are swept separately (`decideSweep`), so they never
        // dilute the active account's freshness.
        let usableIdx = lanes.indices.filter { lanes[$0].account == .primary || lanes[$0].account == .unknown }
        guard !usableIdx.isEmpty else { return .wait(seconds: tuning.idleInterval) }

        let active = lastActivityAt.map { now.timeIntervalSince($0) <= tuning.activeWindow } ?? false
        // Active target = the fastest EVEN cadence the usable lanes can
        // sustain (each lane ≤ perTokenMinInterval), floored at
        // activeInterval. More tokens ⇒ faster (5 tokens → 1 min), fewer
        // ⇒ slower (2 → 2.5 min, 1 → 5 min), never below the floor. Using
        // the lane-count-aware target here (not the raw floor) keeps the
        // cadence evenly spaced instead of bunching quick polls then idling.
        // Counted over the lanes actually in rotation (`rotationSpacing`), so
        // a lane in a long cooldown does not set a pace the rest cannot keep.
        let target: TimeInterval = active
            ? max(tuning.activeInterval,
                  rotationSpacing(usableIdx.map { lanes[$0] },
                                  interval: tuning.perTokenMinInterval, now: now))
            : tuning.idleInterval

        // The token Claude Code is billing now, never polled: poll it ahead of
        // the endpoint-cadence gate. That gate spreads one account's polls
        // across its tokens; it has no reason to hold back the first poll of
        // the signed-in token, which spends only that token's own budget and
        // is the poll that says who is signed in. On 2026-10-08 a new account
        // was signed in at 19:06:58Z and not polled until 19:10:41Z, because
        // the idle cadence (600 s from 19:00:40) held it (#214). The per-token
        // rules (cooldown, external-client schedule) still apply via readyAt.
        if let first = usableIdx.first(where: {
            lanes[$0].probeFirst && lanes[$0].lastPolledAt == nil
                && readyAt(lanes[$0], interval: tuning.perTokenMinInterval, now: now) <= now
        }) {
            return .poll(laneIndex: first)
        }

        // When the endpoint-cadence gate next allows a poll: the most
        // recent poll of any usable lane + target. No prior poll ⇒ now.
        let lastEndpointPoll = usableIdx.compactMap { lanes[$0].lastPolledAt }.max()
        let endpointReady = lastEndpointPoll?.addingTimeInterval(target) ?? .distantPast

        // When each lane individually becomes eligible again (per-token
        // invariant + cooldown), and the earliest such time overall.
        func laneReadyAt(_ l: LaneState) -> Date {
            readyAt(l, interval: tuning.perTokenMinInterval, now: now)
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

    /// The sweep of non-active accounts' lanes: which one to poll now, or how
    /// long until one is due. nil when no lane is `.secondary`.
    ///
    /// `accountKeys[i]` is the account lane `i` belongs to. Each account is
    /// spaced on its own; different accounts are different tokens with
    /// different budgets and may poll in the same second.
    ///
    /// **Per lane, deliberately — that is the multi-token design working.**
    /// Every lane still goes at its own per-token floor (`interval`), so an
    /// account holding n tokens is read n times per interval. The budget
    /// Anthropic enforces is per token, and throttling by account was tried
    /// once and rightly reverted: the 429s it was meant to stop were another
    /// client polling the *same* token. This does not change how often an
    /// account is read, only when.
    ///
    /// **What it adds is the spacing the fast pool already had**: consecutive
    /// polls of one account at least `interval / n` apart (`rotationSpacing`).
    /// Without it nothing spread the lanes (#350). Each came due exactly one
    /// interval after its own last poll and was polled the moment it did, so
    /// whatever phases the lanes had were kept forever, and anything that made
    /// them due together — a launch after more than an interval away, a wake
    /// from sleep, a switch that moved the account to this sweep, a batch of
    /// new tokens classified at once — aligned them for good. On a real store
    /// that was seven Desktop tokens read inside one minute, every five
    /// minutes: seven identical readings, then nothing, a single token's
    /// freshness. With the gap, the first round after any of those already
    /// comes out evenly spaced, and a lane that joins, leaves or backs off is
    /// absorbed within a round, because the gap is recomputed from the lanes
    /// in rotation on every decision. No state is kept for it: the gap is
    /// measured from the account's last poll, which is persisted per lane.
    public func decideSweep(
        lanes: [LaneState], accountKeys: [String?], interval: TimeInterval, now: Date
    ) -> Decision? {
        var byAccount: [String: [Int]] = [:]
        for i in lanes.indices where lanes[i].account == .secondary {
            let key = i < accountKeys.count ? accountKeys[i] : nil
            byAccount[key ?? "", default: []].append(i)
        }
        guard !byAccount.isEmpty else { return nil }

        // Least recently polled first (never-polled sorts oldest), ties by
        // index, so the order does not depend on dictionary iteration.
        func polledEarlier(_ a: Int, _ b: Int) -> Bool {
            let la = lanes[a].lastPolledAt ?? .distantPast
            let lb = lanes[b].lastPolledAt ?? .distantPast
            return la != lb ? la < lb : a < b
        }

        var due: [Int] = []
        var nextAt = Date.distantFuture
        for members in byAccount.values {
            let ready = members.map { readyAt(lanes[$0], interval: interval, now: now) }
            let spacing = rotationSpacing(members.map { lanes[$0] }, interval: interval, now: now)
            // Pacer's own polls only. Another client's request on one shared
            // token already spaces that token (`readyAt`); letting it push the
            // whole account would delay tokens the other client never touches,
            // which is the stagger collapse `sharesBudgetWithSwitcher` exists
            // to prevent.
            let gate = members.compactMap { lanes[$0].lastPolledAt }.max()?
                .addingTimeInterval(spacing) ?? .distantPast
            let accountNext = max(gate, ready.min() ?? .distantFuture)
            if accountNext <= now {
                if let pick = zip(members, ready).filter({ $0.1 <= now }).map(\.0)
                    .min(by: polledEarlier) {
                    due.append(pick)
                }
            } else {
                nextAt = min(nextAt, accountNext)
            }
        }
        if let pick = due.min(by: polledEarlier) { return .poll(laneIndex: pick) }
        return .wait(seconds: max(tuning.minWait, nextAt.timeIntervalSince(now)))
    }

    /// The gap to keep between one account's polls so its lanes stay evenly
    /// spaced: one interval shared between the lanes in rotation.
    ///
    /// "In rotation" is a lane that can be polled within one interval from
    /// now — every lane polled in the last interval, and any that is due. A
    /// lane cooling off a second failure, or standing aside for another
    /// client's announced poll, is out. Counting it would set a pace the other
    /// lanes cannot keep: they run ahead at the shorter gap, reach their own
    /// floors together, and the account goes quiet for the missing lane's
    /// turn — the same bunching, one lane at a time.
    ///
    /// The per-token invariant does not depend on this. A lane is never polled
    /// before its own `readyAt`; the gap only decides *when* among the lanes
    /// that are ready, so it can make an account slower, never a token faster.
    func rotationSpacing(_ lanes: [LaneState], interval: TimeInterval, now: Date) -> TimeInterval {
        let horizon = now.addingTimeInterval(interval)
        let inRotation = lanes.filter { readyAt($0, interval: interval, now: now) <= horizon }.count
        return interval / Double(max(inRotation, 1))
    }

    /// When one lane may next be polled: the per-token invariant, its own
    /// cooldown, and whatever another client on the same token is doing.
    ///
    /// Public and parameterised on `interval` because the fast pool is not the
    /// only caller — `OAuthPoller` sweeps secondary lanes on its own cadence
    /// and has to obey exactly the same rules. It used to carry a partial copy
    /// of them, which is how a lane could keep its spacing from Pacer's own
    /// polls and still land on top of another client's.
    public func readyAt(_ l: LaneState, interval: TimeInterval, now: Date) -> Date {
        let byCooldown = l.cooldownUntil ?? .distantPast

        // Past the floor, another client's schedule stops being a reason to
        // wait: Pacer is owed a reading of its own. Its cooldown still applies
        // — a throttled token is not helped by asking again.
        if overdueForOwnPoll(l, now: now) {
            let byOwnInterval = l.lastPolledAt?.addingTimeInterval(interval) ?? .distantPast
            // Owed a reading is not the same as owed it this second. Still step
            // around a request the other client has just made, since landing on
            // top of one is how both end up with nothing — observed at 68
            // seconds behind cswap's attempt, and both took a 429.
            //
            // Capped at one interval so this cannot become the pin again: a
            // client asking every minute forever delays the probe once, not
            // indefinitely.
            let afterExternal = l.externalLastPollAt?.addingTimeInterval(interval) ?? .distantPast
            let politeness = min(afterExternal, now.addingTimeInterval(interval))
            return max(byCooldown, byOwnInterval, politeness)
        }

        // The per-token invariant counts every request on the token, not just
        // Pacer's — so the interval runs from whichever client asked last.
        let lastRequest = [l.lastPolledAt, l.externalLastPollAt].compactMap { $0 }.max()
        let byInterval = lastRequest?.addingTimeInterval(interval) ?? .distantPast
        let own = max(byInterval, byCooldown)
        return max(own, byExternalSchedule(l, earliest: own, interval: interval, now: now))
    }

    /// True when this token has gone without a reading for longer than Pacer
    /// will stand aside. Only meaningful where another client is known to be
    /// on the token. The reading can be Pacer's own poll or one the other
    /// client got and Pacer took in. Either is data, and only a token nobody
    /// is getting answers from needs Pacer to step in. With no reading from
    /// either, the lane qualifies at once: the first reading is what proves
    /// the token works at all.
    private func overdueForOwnPoll(_ l: LaneState, now: Date) -> Bool {
        guard l.externalNextPollAt != nil || l.externalLastPollAt != nil else { return false }
        guard let freshest = [l.lastPolledAt, l.externalLastSuccessAt].compactMap({ $0 }).max()
        else { return true }
        return now.timeIntervalSince(freshest) >= tuning.externalYieldMax
    }

    /// Keep clear of another client's known request on the same token.
    ///
    /// The rule is the per-token invariant applied in both directions:
    /// requests on one token must be `interval` apart no matter who makes
    /// them. Backwards is `externalLastPollAt`, folded into the interval above.
    /// This is forwards: do not poll so close in front of a known upcoming
    /// request that the pair breaches the same spacing.
    ///
    /// It stays adaptive rather than fixed. A wide external interval leaves
    /// room and Pacer slots in at its own floor; a narrow one leaves none and
    /// Pacer waits until after the other request, then resumes. No hard-coded
    /// "poll at the midpoint" — that was an earlier attempt, and it threw away
    /// the lane-count and backoff logic this scheduler already does well.
    private func byExternalSchedule(
        _ l: LaneState, earliest: Date, interval: TimeInterval, now: Date
    ) -> Date {
        guard let announced = l.externalNextPollAt else { return .distantPast }
        // An overdue time means the other client wants to poll *now* and has
        // not managed to — which is precisely when it needs the room, not when
        // it stops deserving it. Treating a past time as "no upcoming poll" had
        // Pacer crowd a client that was already failing: cswap's next poll ran
        // 24 minutes overdue while it took 429 after 429, and Pacer, seeing a
        // stale timestamp, kept taking the budget.
        //
        // Bounded by `externalYieldMax` in `readyAt`, so a client that is
        // overdue forever cannot park this lane forever.
        let external = max(announced, now)
        // Room in front of it: polling at the soonest Pacer actually could —
        // `earliest`, but never before now — still leaves a full interval
        // before the other client goes. Measuring from `earliest` alone was
        // right only while a lane was polled the moment it became ready; a
        // lane the account's spacing holds back (`rotationSpacing`, or the
        // fast pool's cadence gate) goes later than that, and a past
        // `earliest` then reported room that the actual poll no longer had.
        let at = max(earliest, now)
        if external.timeIntervalSince(at) >= interval { return .distantPast }
        return external.addingTimeInterval(interval)
    }
}
