import Foundation

// Where the background scorer is with each account's record, for the compare
// sheet: a first launch scores for hours (days on a slow Mac), and until a
// model has its cycles it is listed under "More models" with no line, which
// read as broken rather than as "not yet".
//
// The scorer's actor is busy for minutes at a time inside a pass (its work is
// synchronous, paced by sleeping its thread), so asking it would wait that
// long. It writes here instead, under a lock, at each phase and cycle; anyone
// reads without waiting.

/// One account's place in the scorer's current pass.
public struct ArenaScoringProgress: Sendable, Equatable {
    public typealias Phase = ArenaRecordScorer.Phase

    public let phase: Phase
    /// This account's cycles the phase has taken off its queue (scored, or
    /// dropped with a model that fell behind), of those it planned.
    public let cyclesDone: Int
    public let cyclesTotal: Int
    /// The models this phase is still scoring for the account, by id, sorted.
    public let models: [String]
    public let updatedAt: Date
    /// Each of the account's windows' completed cycles in the shared depth
    /// (`EngineSelfEval.rlDepth`), by window key: how many cycles every model
    /// will have been graded on there.
    public let windowDepth: [String: Int]
    /// Wall seconds per cycle graded since the phase began, every account's
    /// cycles counted: the pace the estimate is made from. Nil until one is.
    public let secondsPerCycle: Double?

    /// How long until the phase is done with this account, at the measured
    /// pace (the CPU budget's sleeps included), counting the other windows'
    /// cycles graded in between (each window takes its turn); nil before any
    /// cycle has been timed.
    public let eta: TimeInterval?

    public init(phase: Phase, cyclesDone: Int, cyclesTotal: Int, models: [String], updatedAt: Date,
                windowDepth: [String: Int] = [:], secondsPerCycle: Double? = nil, eta: TimeInterval? = nil) {
        self.phase = phase; self.cyclesDone = cyclesDone; self.cyclesTotal = cyclesTotal
        self.models = models; self.updatedAt = updatedAt
        self.windowDepth = windowDepth; self.secondsPerCycle = secondsPerCycle; self.eta = eta
    }

    /// Done over planned, 0 to 1.
    public var fraction: Double { cyclesTotal > 0 ? min(1, Double(cyclesDone) / Double(cyclesTotal)) : 1 }
}

/// What the scorer publishes and the sheet reads (see the file header). One
/// per runtime; the app's is `shared`, which `ArenaRuntime` writes by default.
public final class ArenaScoringProgressBoard: @unchecked Sendable {
    public static let shared = ArenaScoringProgressBoard()

    private let lock = NSLock()
    private var byAccount: [String: ArenaScoringProgress] = [:]
    /// The accounts a pass has graded through, with the pass's fingerprint
    /// (`ArenaRecordScorer.fingerprint`): a later pass under other inputs
    /// replaces it.
    private var gradedThrough: [String: String] = [:]
    private var currentFingerprint: String?

    public init() {}

    /// Whether a pass under the current grading and inputs has graded every
    /// cycle of `account`'s depth.
    public func isGradedThrough(account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let f = gradedThrough[account] else { return false }
        return f == currentFingerprint
    }

    func setCurrentFingerprint(_ fingerprint: String) {
        lock.lock(); defer { lock.unlock() }
        currentFingerprint = fingerprint
    }

    func setGradedThrough(accounts: some Sequence<String>, fingerprint: String) {
        lock.lock(); defer { lock.unlock() }
        currentFingerprint = fingerprint
        for a in accounts { gradedThrough[a] = fingerprint }
    }

    /// The account's progress while the scorer still has work for it; nil
    /// once it has none (or before its first pass has planned any).
    public func progress(account: String) -> ArenaScoringProgress? {
        lock.lock(); defer { lock.unlock() }
        return byAccount[account]
    }

    func set(_ progress: ArenaScoringProgress?, account: String) {
        lock.lock(); defer { lock.unlock() }
        byAccount[account] = progress
    }

    func clear(accounts: some Sequence<String>) {
        lock.lock(); defer { lock.unlock() }
        for a in accounts { byAccount[a] = nil }
    }
}
