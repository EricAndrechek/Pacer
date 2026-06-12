import Foundation

/// When to (re-)send a burn-rate warning within one rate-limit cycle.
///
/// The old rule — exactly once per cycle — was both too chatty and too quiet:
/// it fired on the first projected crossing however far off, then went silent
/// even if the situation got dramatically worse. This policy is tiered and
/// re-armable:
///
///   - **heads-up** (tier 1): a pre-reset cap hit is projected, however far
///     out. Sent once.
///   - **imminent** (tier 2): the projected hit is within the user's
///     configured imminence window. Escalates once even if a heads-up was
///     already sent.
///   - **re-arm** (optional): a *materially worse* projection re-sends at the
///     current tier — the new ETA must beat the previously-notified one by at
///     least `rearmFraction` of the time that remained (and by an absolute
///     floor), so jitter can't ping anyone.
///
/// Pure decision logic; the coordinator owns persistence (last-notified state
/// per cycle), the opt-in gate, and the ≥50% used floor.
public enum BurnWarningPolicy {

    public enum Tier: Int, Codable, Sendable, Equatable, Comparable {
        case headsUp = 1
        case imminent = 2
        public static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }

    /// What was last notified for a cycle (persisted as JSON by the caller).
    public struct NotifiedState: Codable, Sendable, Equatable {
        public var tier: Tier
        /// Projected-hit instant the user was last told about (unix seconds).
        public var etaUnix: Double

        public init(tier: Tier, etaUnix: Double) {
            self.tier = tier
            self.etaUnix = etaUnix
        }
    }

    /// A new ETA must be earlier than the notified one by at least this
    /// fraction of the time that remained when last notified…
    public static let rearmFraction = 0.25
    /// …and by at least this many seconds, whichever is larger.
    public static let rearmFloorSeconds: TimeInterval = 15 * 60

    public static func tier(etaSeconds: TimeInterval, imminentSeconds: TimeInterval) -> Tier {
        etaSeconds <= imminentSeconds ? .imminent : .headsUp
    }

    /// Decide whether a warning should be sent now. `nil` = stay silent.
    public static func decide(
        prior: NotifiedState?,
        projectedFullAt: Date,
        now: Date,
        imminentSeconds: TimeInterval,
        rearmEnabled: Bool
    ) -> Tier? {
        let eta = projectedFullAt.timeIntervalSince(now)
        guard eta > 0 else { return nil }
        let newTier = tier(etaSeconds: eta, imminentSeconds: imminentSeconds)

        guard let prior else { return newTier }            // first warning of the cycle
        if newTier > prior.tier { return newTier }          // escalation always fires

        guard rearmEnabled else { return nil }
        // Materially worse at the same tier: the projected hit moved earlier
        // by a meaningful share of what remained.
        let priorRemaining = prior.etaUnix - now.timeIntervalSince1970
        let improvementNeeded = max(rearmFloorSeconds, priorRemaining * rearmFraction)
        let movedEarlierBy = prior.etaUnix - projectedFullAt.timeIntervalSince1970
        return movedEarlierBy >= improvementNeeded ? newTier : nil
    }
}
