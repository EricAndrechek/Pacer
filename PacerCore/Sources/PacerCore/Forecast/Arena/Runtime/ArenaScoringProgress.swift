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

    public init(phase: Phase, cyclesDone: Int, cyclesTotal: Int, models: [String], updatedAt: Date) {
        self.phase = phase; self.cyclesDone = cyclesDone; self.cyclesTotal = cyclesTotal
        self.models = models; self.updatedAt = updatedAt
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

    public init() {}

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
