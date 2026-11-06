import Foundation
import Testing
import SwiftData
@testable import PacerCore

/// The scorer's progress, as the compare sheet reads it
/// (`ArenaScoringProgressBoard`): per account, by phase, cycles taken off the
/// queue of those planned, the models still being scored, gone when the pass
/// has no more work for the account. Read from inside a model's forecast, so
/// every snapshot is taken while the scorer's actor is busy.
@Suite("Arena runtime: the scorer's progress", .serialized)
struct RuntimeScoringProgressTests {

    typealias Fixtures = RuntimeEngineTests

    struct Snapshot {
        let forecasting: String
        let model: String
        let progress: [String: ArenaScoringProgress]
    }

    /// What every snooper saw, and the board it reads.
    final class Seen: @unchecked Sendable {
        let lock = NSLock()
        var board = ArenaScoringProgressBoard()
        var accounts: [String] = []
        var snapshots: [Snapshot] = []
        func reset(accounts: [String]) {
            lock.lock(); board = ArenaScoringProgressBoard(); self.accounts = accounts; snapshots = []; lock.unlock()
        }
        func take(forecasting: String, model: String) {
            lock.lock(); defer { lock.unlock() }
            var p: [String: ArenaScoringProgress] = [:]
            for a in accounts { p[a] = board.progress(account: a) }
            snapshots.append(Snapshot(forecasting: forecasting, model: model, progress: p))
        }
        var all: [Snapshot] { lock.lock(); defer { lock.unlock() }; return snapshots }
    }
    static let seen = Seen()

    /// The peeker, noting the board each time it forecasts.
    class Snooper: ArenaModel {
        class var name: String { "test-snoop-cheap" }
        let inner: Fixtures.Peeker
        required init(context: ArenaContext) { inner = Fixtures.Peeker(context: context) }
        func fit(_ history: ArenaHistory) { inner.fit(history) }
        func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
            RuntimeScoringProgressTests.seen.take(forecasting: request.accounts.first ?? "", model: Self.name)
            return try inner.forecast(request)
        }
    }
    final class HeavySnooper: Snooper {
        override class var name: String { "test-snoop-heavy" }
    }
    static let cheap = ArenaModelSpec(name: Snooper.name, targets: Fixtures.meters) { Snooper(context: $0) }
    static let heavy = ArenaModelSpec(name: HeavySnooper.name, targets: Fixtures.meters) { HeavySnooper(context: $0) }

    static func runtime(_ container: ModelContainer) -> ArenaRuntime {
        let costs = ArenaModelCosts(defaults: nil)
        costs.record(heavy.name, weekly: false, cpuMs: 5000)
        return ArenaRuntime(container: container, roster: ArenaRoster(registry: [cheap, heavy]),
                            config: Fixtures.noSleep(), costs: costs, progress: seen.board,
                            onRecordLanded: { _, _ in }, onLiveLanded: { _ in })
    }

    /// One account: phase 1 counts the cheap model's cycles up, phase 2 the
    /// heavy one's, each naming only its own models; the moment phase 1 has
    /// no more for the account it shows what phase 2 holds; done, nothing.
    @Test func eachPhaseCountsItsCyclesAndTheBoardEmptiesWhenDone() async throws {
        Self.seen.reset(accounts: [Fixtures.account])
        let container = try Fixtures.seeded(cycles: 12)
        let rt = Self.runtime(container)
        #expect(rt.progress.progress(account: Fixtures.account) == nil)
        _ = await rt.scorer.pass(accounts: [Fixtures.account], now: Fixtures.now)

        let snaps = Self.seen.all.compactMap { s in s.progress[Fixtures.account].map { (s.model, $0) } }
        #expect(snaps.count == Self.seen.all.count, "every forecast saw progress for its account")
        let cheapSeen = snaps.filter { $0.0 == Self.cheap.name }.map(\.1)
        let heavySeen = snaps.filter { $0.0 == Self.heavy.name }.map(\.1)
        #expect(!cheapSeen.isEmpty && !heavySeen.isEmpty)

        #expect(cheapSeen.allSatisfy { $0.phase == .cheap && $0.cyclesTotal == 12 && $0.models == [Self.cheap.name] })
        // Taken during each cycle, so before it is counted: 0 through 11.
        #expect(Set(cheapSeen.map(\.cyclesDone)) == Set(0..<12))
        #expect(cheapSeen.map(\.cyclesDone) == cheapSeen.map(\.cyclesDone).sorted())

        #expect(heavySeen.allSatisfy { $0.phase == .heavy && $0.cyclesTotal == 12 && $0.models == [Self.heavy.name] })
        #expect(Set(heavySeen.map(\.cyclesDone)) == Set(0..<12))
        #expect(heavySeen.first?.fraction == 0)

        #expect(rt.progress.progress(account: Fixtures.account) == nil)
        // A pass with nothing to score publishes nothing.
        Self.seen.reset(accounts: [Fixtures.account])
        _ = await rt.scorer.pass(accounts: [Fixtures.account], now: Fixtures.now)
        #expect(Self.seen.all.isEmpty)
        #expect(rt.progress.progress(account: Fixtures.account) == nil)
    }

    /// Two accounts take turns: one done with phase 1 while the other is not
    /// shows phase 2's plan for it, not a finished phase 1; each account's
    /// counts are its own.
    @Test func anAccountWaitingForPhaseTwoSaysSo() async throws {
        let accounts = ["acct-progress-a", "acct-progress-b"]
        Self.seen.reset(accounts: accounts)
        let container = try RuntimeCostOrderTests.seeded(accounts: accounts, cycles: 12)
        let rt = Self.runtime(container)
        _ = await rt.scorer.pass(accounts: accounts, now: Fixtures.now)

        let all = Self.seen.all
        // Every snapshot of the account forecasting is its own phase's.
        for s in all {
            let mine = try #require(s.progress[s.forecasting])
            #expect(mine.cyclesTotal == 12)
            #expect(mine.phase == (s.model == Self.cheap.name ? .cheap : .heavy))
        }
        // While one account is still in phase 1, the other has either some
        // of phase 1 left or is waiting on phase 2, none of it done.
        let waiting = all.filter { $0.model == Self.cheap.name }.compactMap { s -> ArenaScoringProgress? in
            let other = accounts.first { $0 != s.forecasting }!
            return s.progress[other]
        }
        #expect(waiting.allSatisfy { $0.phase == .cheap ? $0.cyclesDone < 12 : $0.cyclesDone == 0 && $0.cyclesTotal == 12 })
        #expect(waiting.contains { $0.phase == .heavy && $0.models == [Self.heavy.name] })
        for a in accounts { #expect(rt.progress.progress(account: a) == nil) }
    }

    /// A stopped scorer leaves nothing behind.
    @Test func aCancelledPassClearsItsAccounts() async throws {
        Self.seen.reset(accounts: [Fixtures.account])
        let container = try Fixtures.seeded(cycles: 12)
        let rt = Self.runtime(container)
        let pass = Task { await rt.scorer.pass(accounts: [Fixtures.account], now: Fixtures.now) }
        // Wait until it is visibly under way, then stop it.
        for _ in 0..<2000 where Self.seen.all.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        #expect(!Self.seen.all.isEmpty)
        await rt.stop()
        _ = await pass.value
        #expect(rt.progress.progress(account: Fixtures.account) == nil)
    }

    /// Every progress value a scorer's checkpoints saw: the CPU budget's
    /// clock is read at each, from the history build to every forecast.
    final class Checkpoints: @unchecked Sendable {
        let lock = NSLock()
        var seen: [ArenaScoringProgress?] = []
        func note(_ p: ArenaScoringProgress?) { lock.lock(); seen.append(p); lock.unlock() }
        var all: [ArenaScoringProgress?] { lock.lock(); defer { lock.unlock() }; return seen }
    }

    /// A scorer on its own budget whose clock notes `account`'s progress at
    /// every checkpoint; nothing is ever spent, so nothing sleeps.
    static func watchedPass(budgetRate: Double, accounts: [String]) async throws
        -> (seen: [String: [ArenaScoringProgress?]], board: ArenaScoringProgressBoard) {
        let board = ArenaScoringProgressBoard()
        let notes = Dictionary(uniqueKeysWithValues: accounts.map { ($0, Checkpoints()) })
        let clock = ArenaCPUBudget.Clock(
            wall: { ArenaCPUBudget.Clock.system.wall() },
            threadCPU: { for (a, n) in notes { n.note(board.progress(account: a)) }; return 0 },
            threadID: { 1 }, sleep: { _ in })
        let budget = ArenaCPUBudget(rate: budgetRate, burst: 1000, clock: clock)
        let container = try RuntimeCostOrderTests.seeded(accounts: [accounts[0]], cycles: 6)
        let spec = ArenaModelSpec(name: "test-progress-flat", targets: Fixtures.meters) { NaiveFlat(context: $0) }
        let scorer = ArenaRecordScorer(container: container, roster: ArenaRoster(registry: [spec]),
                                       history: ArenaHistoryCache(container: container), services: ArenaServices(),
                                       budget: budget, cancel: ArenaCancelFlag(), config: ArenaRecordScorer.Config(),
                                       progress: board, landed: { _, _ in })
        _ = await scorer.pass(accounts: accounts, now: Fixtures.now)
        return (notes.mapValues(\.all), board)
    }

    /// A full pass says it is reading before anything is planned; an account
    /// found to have nothing to grade is cleared as soon as it is read, not
    /// left reading while the rest of the pass runs; the pass leaves nothing.
    @Test func aFullPassSaysItIsReadingFirst() async throws {
        let accounts = ["acct-progress-read", "acct-progress-empty"]
        let (seen, board) = try await Self.watchedPass(budgetRate: 0.2, accounts: accounts)
        let mine = seen[accounts[0]] ?? []
        let empty = seen[accounts[1]] ?? []
        #expect(mine.first??.readingHistory == true)
        #expect(mine.contains { $0?.readingHistory == false && ($0?.cyclesTotal ?? 0) > 0 })
        // Read after the first account: reading until then, cleared once read.
        #expect(empty.contains { $0?.readingHistory == true })
        let lastReading = empty.lastIndex { $0?.readingHistory == true } ?? 0
        #expect(empty[(lastReading + 1)...].allSatisfy { $0 == nil })
        #expect(!board.hasWork)
    }

    /// Each cycle's time counts at the budget's rate when it ended, so the
    /// estimate at either rate is that rate's own: here the everyday share,
    /// then the full core, each measured and the other left unknown.
    @Test func thePaceIsMeasuredAtEachRateApart() async throws {
        let account = "acct-progress-pace"
        let atShare = (try await Self.watchedPass(budgetRate: 0.2, accounts: [account])).seen[account] ?? []
        let timed = atShare.compactMap { $0 }.filter { !$0.readingHistory && $0.pace != .init() }
        #expect(!timed.isEmpty)
        #expect(timed.allSatisfy { $0.pace.secondsPerCycle(.share) != nil && $0.pace.secondsPerCycle(.cores(1)) == nil })
        #expect(timed.allSatisfy { $0.cyclesAhead > 0 })
        #expect(timed.allSatisfy { $0.eta(rate: .share) != nil && $0.eta(rate: .cores(1)) == nil })

        let atFull = (try await Self.watchedPass(budgetRate: 1, accounts: [account])).seen[account] ?? []
        let fast = atFull.compactMap { $0 }.filter { !$0.readingHistory && $0.pace != .init() }
        #expect(!fast.isEmpty)
        #expect(fast.allSatisfy { $0.pace.secondsPerCycle(.cores(1)) != nil && $0.pace.secondsPerCycle(.share) == nil })
    }

    /// The time left counts down through the cycle under way, by at most
    /// one cycle's time, and is never negative.
    @Test func theTimeLeftCountsDownWithinACycle() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let p = ArenaScoringProgress(phase: .cheap, cyclesDone: 1, cyclesTotal: 9, models: ["m"], updatedAt: at,
                                     pace: .init(seconds: [.share: 120, .cores(1): 20]), cyclesAhead: 8)
        func eta(_ full: Bool, after s: TimeInterval) -> Double { p.eta(rate: full ? .cores(1) : .share, now: at.addingTimeInterval(s)) ?? -1 }
        #expect(abs(eta(false, after: 0) - 960) < 1e-6)
        #expect(abs(eta(false, after: 60) - 900) < 1e-6)
        #expect(abs(eta(false, after: 3600) - 840) < 1e-6)
        #expect(abs(eta(true, after: 5) - 155) < 1e-6)
        #expect(abs(eta(false, after: -60) - 960) < 1e-6)
        let none = ArenaScoringProgress(phase: .cheap, cyclesDone: 0, cyclesTotal: 9, models: [], updatedAt: at)
        #expect(none.eta(rate: .share) == nil && none.eta(rate: .cores(1)) == nil)
        #expect(ArenaScoringProgress(phase: .cheap, cyclesDone: 8, cyclesTotal: 9, models: ["m"], updatedAt: at,
                                     pace: .init(seconds: [.share: 10]), cyclesAhead: 0).eta(rate: .share, now: at) == 0)
    }

    @Test func theBoardIsPerAccountAndFractionIsBounded() {
        let board = ArenaScoringProgressBoard()
        let p = ArenaScoringProgress(phase: .heavy, cyclesDone: 3, cyclesTotal: 12, models: ["m"], updatedAt: .now)
        board.set(p, account: "a")
        #expect(board.progress(account: "a") == p)
        #expect(board.progress(account: "b") == nil)
        #expect(p.fraction == 0.25)
        #expect(ArenaScoringProgress(phase: .cheap, cyclesDone: 0, cyclesTotal: 0, models: [], updatedAt: .now)
            .fraction == 1)
        board.clear(accounts: ["a"])
        #expect(board.progress(account: "a") == nil)
    }
}
