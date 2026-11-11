import Foundation
import Testing
@testable import PacerCore

/// The compare sheet's Speed up (`ArenaSpeedUp`), through the governor that
/// honours it: the full core while in use or on battery, never against heat
/// or Low Power Mode, until the catch-up is done or an hour has passed, then
/// the everyday rule. Signals, the clock and "work pending" are injected;
/// nothing here reads the machine.
@Suite("Arena runtime: the user's speed-up")
struct RuntimeSpeedUpTests {
    typealias Policy = ArenaBudgetPolicy
    static let signals = RuntimeBudgetGovernorTests.signals

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ s: TimeInterval) { lock.lock(); value = value.addingTimeInterval(s); lock.unlock() }
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool
        init(_ v: Bool) { value = v }
        var get: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
    }

    struct Rig {
        let budget: ArenaCPUBudget
        let speedUp: ArenaSpeedUp
        let signals: RuntimeBudgetGovernorTests.Signals
        let clock: Clock
        let pending: Flag
        let governor: ArenaBudgetGovernor
    }

    static func rig(_ s: ArenaBudgetSignals = signals(true, false, .nominal, 10)) -> Rig {
        let budget = ArenaCPUBudget(rate: 0.2, burst: 0, clock: RuntimeBudgetTests.Script().clock)
        let speedUp = ArenaSpeedUp()
        let sig = RuntimeBudgetGovernorTests.Signals()
        sig.set(s)
        let clock = Clock()
        let pending = Flag(true)
        let g = ArenaBudgetGovernor(budget: budget, shareRate: 0.2, fullRate: 1, speedUp: speedUp,
                                    pending: { pending.get }, now: { clock.now },
                                    read: { sig.get() }, log: { sig.log($0) })
        return Rig(budget: budget, speedUp: speedUp, signals: sig, clock: clock, pending: pending, governor: g)
    }

    /// Never pressed, the rule is the everyday one in every state, a governor
    /// with a speed-up attached included.
    @Test func theDefaultIsUnchangedWhenTheControlIsNotUsed() {
        for ac in [true, false] {
            for low in [true, false] {
                for thermal in [ProcessInfo.ThermalState.nominal, .fair, .serious, .critical] {
                    for idle in [0.0, 119, 120, 600] {
                        let s = Self.signals(ac, low, thermal, idle)
                        #expect(Policy.mode(s) == Policy.mode(s, spedUp: false))
                    }
                }
            }
        }
        let r = Self.rig()
        #expect(r.governor.evaluate() == .share(.inUse))
        #expect(r.budget.rate == 0.2)
        r.signals.set(Self.signals(true, false, .nominal, 300))
        #expect(r.governor.evaluate() == .fullCore)
        #expect(r.budget.rate == 1)
        r.signals.set(Self.signals(false, false, .nominal, 300))
        #expect(r.governor.evaluate() == .share(.battery))
        #expect(r.budget.rate == 0.2)
        r.clock.advance(4 * 3600)
        r.pending.set(false)
        #expect(r.governor.evaluate() == .share(.battery))
        #expect(r.speedUp.until == nil)
        #expect(r.signals.logged == ["budget: 20% of a core (in use)", "budget: full core (plugged in, idle)",
                                     "budget: 20% of a core (on battery)"])
    }

    /// It lifts the user's gates (in use, on battery), never the Mac's own.
    @Test func itLiftsInUseAndBatteryNotHeatOrLowPower() {
        #expect(Policy.mode(Self.signals(true, false, .nominal, 0), spedUp: true) == .fullCore)
        #expect(Policy.mode(Self.signals(false, false, .nominal, 0), spedUp: true) == .fullCore)
        #expect(Policy.mode(Self.signals(true, true, .nominal, 600), spedUp: true) == .share(.lowPower))
        #expect(Policy.mode(Self.signals(true, false, .serious, 600), spedUp: true) == .share(.thermal))
        #expect(Policy.mode(Self.signals(false, false, .critical, 0), spedUp: true) == .share(.thermal))
        #expect(Policy.describe(.fullCore, shareRate: 0.2, spedUp: true) == "full core (sped up)")
        #expect(Policy.scorerQoS(Policy.mode(Self.signals(true, false, .nominal, 0), spedUp: true), spedUp: true)
                == QOS_CLASS_USER_INITIATED)
    }

    /// On: the full core while the Mac is in use. The catch-up finishes: off,
    /// and back to the share.
    @Test func onUntilTheCatchUpIsDoneThenTheDefault() {
        let r = Self.rig()
        #expect(r.governor.evaluate() == .share(.inUse))
        r.speedUp.start(now: r.clock.now)
        #expect(r.speedUp.until == r.clock.now.addingTimeInterval(ArenaSpeedUp.limit))
        #expect(r.governor.evaluate() == .fullCore)
        #expect(r.budget.rate == 1)
        #expect(r.budget.scorerQoS == QOS_CLASS_USER_INITIATED)
        r.clock.advance(20 * 60)
        #expect(r.governor.evaluate() == .fullCore)
        // On battery now: still the full core, as asked.
        r.signals.set(Self.signals(false, false, .nominal, 0))
        #expect(r.governor.evaluate() == .fullCore)
        // Too hot: the share, sped up or not.
        r.signals.set(Self.signals(true, false, .serious, 0))
        #expect(r.governor.evaluate() == .share(.thermal))
        #expect(r.speedUp.until != nil)
        r.signals.set(Self.signals(true, false, .nominal, 0))
        #expect(r.governor.evaluate() == .fullCore)
        // Nothing left to catch up.
        r.pending.set(false)
        #expect(r.governor.evaluate() == .share(.inUse))
        #expect(r.budget.rate == 0.2)
        #expect(r.budget.scorerQoS == QOS_CLASS_BACKGROUND)
        #expect(r.speedUp.until == nil)
        // New work later is not sped up again on its own.
        r.pending.set(true)
        #expect(r.governor.evaluate() == .share(.inUse))
        #expect(r.signals.logged == ["budget: 20% of a core (in use)", "budget: full core (sped up)",
                                     "budget: 20% of a core (thermal)", "budget: full core (sped up)",
                                     "budget: 20% of a core (in use)"])
    }

    /// At most an hour, then the default, work left or not; asking for more
    /// gets the hour.
    @Test func atMostAnHour() {
        let r = Self.rig()
        r.speedUp.start(now: r.clock.now)
        #expect(r.governor.evaluate() == .fullCore)
        r.clock.advance(ArenaSpeedUp.limit - 1)
        #expect(r.governor.evaluate() == .fullCore)
        r.clock.advance(1)
        #expect(r.governor.evaluate() == .share(.inUse))
        #expect(r.speedUp.until == nil)
        #expect(r.budget.rate == 0.2)

        r.speedUp.start(now: r.clock.now, duration: 5 * 3600)
        #expect(r.speedUp.until == r.clock.now.addingTimeInterval(ArenaSpeedUp.limit))
        // Started again while on: the hour starts over.
        r.clock.advance(1800)
        r.speedUp.start(now: r.clock.now)
        r.clock.advance(1800)
        #expect(r.governor.evaluate() == .fullCore)
    }

    /// Turned off: the default at once; how long it held is what it reports.
    @Test func turnedOffByTheUser() {
        let r = Self.rig()
        r.speedUp.start(now: r.clock.now)
        #expect(r.governor.evaluate() == .fullCore)
        r.clock.advance(300)
        #expect(r.speedUp.end(.stopped, now: r.clock.now) == 300)
        #expect(r.speedUp.end(.stopped, now: r.clock.now) == nil)
        #expect(r.governor.evaluate() == .share(.inUse))
        // Already plugged in and idle: the speed-up changes no rate, and
        // ending it leaves the full core the Mac has anyway.
        r.signals.set(Self.signals(true, false, .nominal, 600))
        #expect(r.governor.evaluate() == .fullCore)
        r.speedUp.start(now: r.clock.now)
        #expect(r.governor.evaluate() == .fullCore)
        r.speedUp.stop(now: r.clock.now)
        #expect(r.governor.evaluate() == .fullCore)
    }

    /// The pace the sheet reads: the mode, and until when a speed-up holds.
    @Test func thePaceIsPublished() {
        let r = Self.rig()
        #expect(r.speedUp.currentPace == nil)
        r.governor.evaluate()
        #expect(r.speedUp.currentPace == ArenaPace(mode: .share(.inUse)))
        r.speedUp.start(now: r.clock.now)
        r.governor.evaluate()
        let until = r.clock.now.addingTimeInterval(ArenaSpeedUp.limit)
        #expect(r.speedUp.currentPace == ArenaPace(mode: .fullCore, speedUpUntil: until))
        #expect(r.speedUp.currentPace?.isSpedUp == true)
        r.signals.set(Self.signals(false, false, .nominal, 0))
        r.speedUp.stop(now: r.clock.now)
        r.governor.evaluate()
        #expect(r.speedUp.currentPace == ArenaPace(mode: .share(.battery)))
    }

    /// The main actor's copy follows, for the sheet's body to read.
    @MainActor @Test func theStatusFollowsOnTheMainActor() async {
        let r = Self.rig()
        r.governor.evaluate()
        r.speedUp.start(now: r.clock.now)
        r.governor.evaluate()
        let want = ArenaPace(mode: .fullCore, speedUpUntil: r.clock.now.addingTimeInterval(ArenaSpeedUp.limit))
        for _ in 0..<400 where r.speedUp.status.pace != want { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(r.speedUp.status.pace == want)
    }

    /// A running governor takes a speed-up at once, not at its next tick
    /// (30 s at the share), and drops it at once when turned off.
    @Test func aRunningGovernorTakesItAtOnce() async {
        let r = Self.rig()
        r.governor.start()
        defer { r.governor.stop() }
        for _ in 0..<400 where r.governor.current == nil { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(r.budget.rate == 0.2)
        r.speedUp.start(now: r.clock.now)
        for _ in 0..<400 where r.budget.rate != 1 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(r.budget.rate == 1)
        r.speedUp.stop(now: r.clock.now)
        for _ in 0..<400 where r.budget.rate != 0.2 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(r.budget.rate == 0.2)
    }

    /// "Catch-up pending" is any account with progress on the board.
    @Test func pendingIsAnyAccountWithWork() {
        let board = ArenaScoringProgressBoard()
        #expect(!board.hasWork)
        board.set(.reading(at: Date()), account: "a")
        #expect(board.hasWork)
        board.set(ArenaScoringProgress(phase: .cheap, cyclesDone: 0, cyclesTotal: 4, models: ["m"], updatedAt: Date()),
                  account: "b")
        board.clear(accounts: ["a"])
        #expect(board.hasWork)
        board.set(nil, account: "b")
        #expect(!board.hasWork)
    }

    /// What the speed-up sends: enum words and coarse minutes only.
    @Test func itsAnalyticsEvent() {
        let start = AnalyticsEvent.arenaSpeedUp(.start, from: ArenaSpeedUp.telemetryFrom(.share(.inUse)))
        #expect(start.name == "arena_speed_up")
        #expect(start.properties == ["action": .string("start"), "from": .string("in_use")])
        // The Mac's most workers, as a band: never the exact core count.
        for (n, band) in [(1, "1"), (2, "2-4"), (4, "2-4"), (5, "5-8"), (8, "5-8"), (9, "9+"), (15, "9+")] {
            #expect(AnalyticsEvent.arenaSpeedUp(.start, workers: n).properties["workers"] == .string(band))
        }
        #expect(ArenaSpeedUp.telemetryFrom(.cores(9)) == .full)
        #expect(ArenaSpeedUp.telemetryFrom(.paused) == .lowMemory)
        #expect(ArenaSpeedUp.telemetryFrom(.share(.lowMemory)) == .lowMemory)
        let done = AnalyticsEvent.arenaSpeedUp(ArenaSpeedUp.telemetryAction(.caughtUp), heldSeconds: 1234)
        #expect(done.properties == ["action": .string("caught_up"), "minutes": .int(21)])
        #expect(ArenaSpeedUp.telemetryAction(.timeUp) == .timeUp)
        #expect(ArenaSpeedUp.telemetryAction(.stopped) == .stop)
        #expect(ArenaSpeedUp.telemetryFrom(nil) == .unknown)
        #expect(ArenaSpeedUp.telemetryFrom(.fullCore) == .full)
        #expect(ArenaSpeedUp.telemetryFrom(.share(.battery)) == .battery)
    }
}
