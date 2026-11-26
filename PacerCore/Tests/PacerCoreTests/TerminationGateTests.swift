import Foundation
import Observation
import Testing
@testable import PacerCore

/// Quit stops view work (#475): once `TerminationGate.begin()` runs, the
/// dashboard's refresh signals are never delivered again, asleep or awake,
/// its clock loops stay parked, and a view frozen with `TerminationFreeze`
/// stops depending on anything but the gate.
@Suite("Termination gate")
@MainActor
struct TerminationGateTests {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Coalescer

    @Test func theCoalescerRefusesEverythingOnceQuitBegins() {
        var c = ViewRefreshCoalescer()
        _ = c.setDisplays(.awake, now: t0)
        do { let passed = c.offer(.scanCycle); #expect(passed) }
        c.beginTermination()
        #expect(c.isTerminating)
        #expect(c.isHolding)
        for signal in ViewRefreshSignal.allCases {
            do { let passed = c.offer(signal); #expect(!passed) }
        }
        // Refused, not held: there is nothing to deliver later.
        #expect(c.held.isEmpty)
        #expect(c.heldScan == nil)
    }

    @Test func aWakeAfterQuitBeganDeliversNothingHeldBeforeIt() {
        var c = ViewRefreshCoalescer()
        _ = c.setDisplays(.asleep, now: t0)
        do { let passed = c.offer(.rateLimitWrite); #expect(!passed) }
        do { let passed = c.offer(.scanCycle, summary: ScanCycleSummary(samplesChanged: true)); #expect(!passed) }
        c.beginTermination()
        #expect(c.held.isEmpty)
        #expect(c.setDisplays(.awake, now: t0.addingTimeInterval(60)) == nil)
        #expect(c.setDisplays(.unknown, now: t0.addingTimeInterval(61)) == nil)
        #expect(c.isHolding)
    }

    // MARK: - Gate

    /// A gate on its own center, with a display probe the test controls.
    @MainActor
    private final class Rig {
        let center = NotificationCenter()
        var allAsleep = false
        var lines: [String] = []
        var scans = 0
        var engines = 0
        var observers: [NSObjectProtocol] = []
        private(set) var gate: ViewRefreshGate!

        init() {
            gate = ViewRefreshGate(center: center,
                                   allDisplaysAsleep: { [unowned self] in self.allAsleep },
                                   log: { [unowned self] in self.lines.append($0) })
            observers = [
                center.addObserver(forName: .pacerViewScanCycleDidComplete, object: nil, queue: nil) { [unowned self] _ in
                    MainActor.assumeIsolated { self.scans += 1 }
                },
                center.addObserver(forName: .pacerViewEngineDidRecompute, object: nil, queue: nil) { [unowned self] _ in
                    MainActor.assumeIsolated { self.engines += 1 }
                },
            ]
        }

        func postScan() { center.post(name: .pacerScanCycleDidComplete, object: ScanCycleSummary(samplesChanged: true)) }
        func postEngine() { center.post(name: .pacerEngineDidRecompute, object: nil) }
    }

    @Test func dashboardSignalsStopWhileAwakeOnceQuitBegins() {
        let rig = Rig()
        rig.gate.displaysReported(asleep: false)
        rig.postScan()
        rig.postEngine()
        var writes = 0
        rig.gate.offer(.rateLimitWrite) { _ in writes += 1 }
        #expect(rig.scans == 1)
        #expect(rig.engines == 1)
        #expect(writes == 1)

        rig.gate.beginTermination()
        #expect(rig.gate.isTerminating)
        #expect(rig.lines.last == "quit began — dashboard refreshes stop")
        rig.postScan()
        rig.postEngine()
        for signal in ViewRefreshSignal.allCases {
            rig.gate.offer(signal) { _ in writes += 1 }
        }
        #expect(rig.scans == 1)
        #expect(rig.engines == 1)
        #expect(writes == 1)

        // A display report, either way, delivers nothing.
        rig.gate.displaysReported(asleep: false)
        rig.gate.displaysMayHaveChanged()
        #expect(rig.scans == 1)
        #expect(writes == 1)
    }

    @Test func whatWasHeldAsleepIsNotDeliveredByAWakeDuringQuit() {
        let rig = Rig()
        rig.allAsleep = true
        rig.gate.displaysReported(asleep: true)
        rig.postScan()
        var writes = 0
        rig.gate.offer(.liveMeter) { _ in writes += 1 }
        rig.gate.beginTermination()
        #expect(rig.lines.last == "quit began — dashboard refreshes stop (they were held: displays asleep)")

        rig.allAsleep = false
        rig.gate.displaysReported(asleep: false)
        #expect(rig.scans == 0)
        #expect(writes == 0)
        #expect(!rig.lines.contains { $0.hasPrefix("displays awake — delivered") })
    }

    @Test func beginningTwiceLogsOnce() {
        let rig = Rig()
        rig.gate.beginTermination()
        rig.gate.beginTermination()
        #expect(rig.lines.filter { $0.hasPrefix("quit began") }.count == 1)
    }

    /// A dashboard clock loop: parked while quitting even with every display
    /// awake, and still released by cancelling its task (a view going away).
    @Test func clockLoopsStayParkedDuringQuitUntilCancelled() async {
        let rig = Rig()
        rig.gate.displaysReported(asleep: false)
        await rig.gate.untilAwake()  // awake: straight through

        rig.gate.beginTermination()
        var resumed = 0
        let loop = Task { @MainActor in await rig.gate.untilAwake(); resumed += 1 }
        for _ in 0..<10 { await Task.yield() }
        rig.gate.displaysReported(asleep: false)
        for _ in 0..<10 { await Task.yield() }
        #expect(resumed == 0)
        loop.cancel()
        await loop.value
        #expect(resumed == 1)
    }

    @Test func aLoopParkedAsleepIsNotReleasedByAWakeDuringQuit() async {
        let rig = Rig()
        rig.allAsleep = true
        rig.gate.displaysReported(asleep: true)
        var resumed = 0
        let loop = Task { @MainActor in await rig.gate.untilAwake(); resumed += 1 }
        for _ in 0..<10 { await Task.yield() }
        rig.gate.beginTermination()
        rig.allAsleep = false
        rig.gate.displaysReported(asleep: false)
        for _ in 0..<10 { await Task.yield() }
        #expect(resumed == 0)
        loop.cancel()
        await loop.value
        #expect(resumed == 1)
    }

    // MARK: - TerminationGate

    @Test func beginIsOneWayAndRunsItsHookOnce() {
        var hooks = 0
        let gate = TerminationGate(onBegin: { hooks += 1 })
        #expect(!gate.isTerminating)
        #expect(gate.begin(now: t0))
        #expect(!gate.begin(now: t0.addingTimeInterval(1)))
        #expect(gate.isTerminating)
        #expect(gate.beganAt == t0)
        #expect(hooks == 1)
    }

    /// Counts `onChange` calls, which observation makes on whatever thread
    /// mutated (here, this one).
    final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func add() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    @Test func beginningRedrawsWhatReadTheGate() {
        let gate = TerminationGate()
        let changed = Count()
        withObservationTracking { _ = gate.isTerminating } onChange: { changed.add() }
        gate.begin()
        #expect(changed.value == 1)
    }

    // MARK: - TerminationFreeze

    @Observable @MainActor
    final class Source { var value = 0 }

    /// What SwiftUI does with a `body`: track what it reads, redraw when any
    /// of it changes. Before quit the frozen body depends on its inputs;
    /// after, on the gate alone, so an input changing schedules nothing.
    @Test func aFrozenBodyStopsDependingOnItsInputs() {
        let gate = TerminationGate()
        let source = Source()
        let freeze = TerminationFreeze<Int>()
        var lives = 0
        let redraws = Count()
        func body() -> Int {
            withObservationTracking {
                freeze.resolve(isTerminating: gate.isTerminating) { lives += 1; return source.value }
            } onChange: { redraws.add() }
        }

        source.value = 1
        #expect(body() == 1)
        source.value = 2  // an input moved: redraw
        #expect(redraws.value == 1)
        #expect(body() == 2)

        gate.begin()  // quit: one last redraw, for the gate
        #expect(redraws.value == 2)
        #expect(body() == 2)
        #expect(lives == 2)  // the frozen pass did not read the inputs

        source.value = 3  // a publish during the shutdown: no redraw
        source.value = 4
        #expect(redraws.value == 2)
        #expect(body() == 2)
        #expect(lives == 2)
    }

    @Test func aViewFirstDrawnDuringQuitReadsOnceThenHolds() {
        let freeze = TerminationFreeze<Int>()
        var lives = 0
        #expect(freeze.resolve(isTerminating: true) { lives += 1; return 7 } == 7)
        #expect(freeze.resolve(isTerminating: true) { lives += 1; return 8 } == 7)
        #expect(lives == 1)
    }

    // MARK: - Exit guard

    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [String] = []
        func add(_ e: String) { lock.withLock { events.append(e) } }
        var snapshot: [String] { lock.withLock { events } }
    }

    private func guardRecording(_ events: Events) -> QuitExitGuard {
        QuitExitGuard(log: { events.add("log:" + $0) }, exit: { events.add("exit") })
    }

    private func waitFor(_ events: Events, count: Int, within seconds: Double = 5) async {
        let started = Date()
        while events.snapshot.count < count, Date().timeIntervalSince(started) < seconds {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func afterTheReplyTheGuardLogsThenExitsAfterItsGrace() async {
        let events = Events()
        let started = Date()
        guardRecording(events).armAfterReply(grace: .milliseconds(50))
        await waitFor(events, count: 2, within: 30)
        #expect(events.snapshot == ["log:still running 0 s after replying to terminate; exiting", "exit"])
        #expect(Date().timeIntervalSince(started) >= 0.05)
    }

    /// A shutdown that never replies is ended at the backstop.
    @Test func theBackstopEndsAShutdownThatNeverReplies() async {
        let events = Events()
        let started = Date()
        guardRecording(events).armShutdownBackstop(bound: .milliseconds(50))
        await waitFor(events, count: 2, within: 30)
        #expect(events.snapshot == ["log:no reply to terminate 0 s after the quit began; exiting", "exit"])
        #expect(Date().timeIntervalSince(started) >= 0.05)
    }

    /// Once the reply is sent the backstop stands down: only the after-reply
    /// deadline ends the process, once. Checked by what was logged, not by
    /// when: on a loaded Mac the two timers can fire in either order.
    @Test func theBackstopStandsDownOnceTheReplyIsSent() async {
        let events = Events()
        let quit = guardRecording(events)
        quit.armShutdownBackstop(bound: .milliseconds(50))
        quit.armAfterReply(grace: .milliseconds(150))
        await waitFor(events, count: 2, within: 30)
        // Long past both deadlines, so a backstop that did fire has logged.
        try? await Task.sleep(for: .milliseconds(300))
        #expect(events.snapshot == ["log:still running 0 s after replying to terminate; exiting", "exit"])
    }
}
