import Foundation
import Testing
@testable import PacerCore

/// `ViewRefreshCoalescer` and `ViewRefreshGate` (#407): dashboard refresh
/// signals are held only while every display is asleep, and each one held is
/// delivered exactly once on wake. Nothing may be left stale and nothing may
/// wait while anyone could be looking.
@Suite("View refresh coalescer")
struct ViewRefreshCoalescerTests {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    // `offer` is mutating, which `#expect` cannot call: each is taken first.

    @Test func unknownStatePassesEverythingThrough() {
        var c = ViewRefreshCoalescer()
        #expect(c.displays == .unknown)
        for signal in ViewRefreshSignal.allCases {
            do { let passed = c.offer(signal); #expect(passed) }
        }
        #expect(c.held.isEmpty)
        // Leaving unknown is not a wake: nothing to flush.
        #expect(c.setDisplays(.awake, now: t0) == nil)
    }

    @Test func awakePassesStraightThrough() {
        var c = ViewRefreshCoalescer()
        _ = c.setDisplays(.awake, now: t0)
        do { let passed = c.offer(.scanCycle, summary: ScanCycleSummary(samplesChanged: true)); #expect(passed) }
        do { let passed = c.offer(.rateLimitWrite); #expect(passed) }
        #expect(c.held.isEmpty)
        #expect(c.heldScan == nil)
    }

    @Test func asleepHoldsAndWakeDeliversEachDistinctSignalOnce() {
        var c = ViewRefreshCoalescer()
        _ = c.setDisplays(.asleep, now: t0)
        do { let passed = c.offer(.rateLimitWrite); #expect(!passed) }
        do { let passed = c.offer(.scanCycle, summary: ScanCycleSummary(samplesChanged: true)); #expect(!passed) }
        do { let passed = c.offer(.rateLimitWrite); #expect(!passed) }
        do { let passed = c.offer(.engineRecompute); #expect(!passed) }
        do { let passed = c.offer(.scanCycle, summary: ScanCycleSummary(projectAttributionChanged: true)); #expect(!passed) }
        do { let passed = c.offer(.minuteTick); #expect(!passed) }
        do { let passed = c.offer(.minuteTick); #expect(!passed) }

        let flush = c.setDisplays(.awake, now: t0.addingTimeInterval(3600))
        #expect(flush?.signals == [.rateLimitWrite, .scanCycle, .engineRecompute, .minuteTick])
        #expect(flush?.scanSummary == ScanCycleSummary(samplesChanged: true, projectAttributionChanged: true))
        #expect(flush?.heldFor == 3600)
        // Cleared: the next wake has nothing left over.
        #expect(c.held.isEmpty)
        #expect(c.heldScan == nil)
    }

    @Test func aWakeWithNothingHeldDeliversNothing() {
        var c = ViewRefreshCoalescer()
        _ = c.setDisplays(.asleep, now: t0)
        let flush = c.setDisplays(.awake, now: t0.addingTimeInterval(5))
        #expect(flush?.signals == [])
        #expect(flush?.scanSummary == nil)
    }

    @Test func aRepeatedSleepReportKeepsTheFirstStartAndTheHeld() {
        var c = ViewRefreshCoalescer()
        _ = c.setDisplays(.asleep, now: t0)
        do { let passed = c.offer(.engineRecompute); #expect(!passed) }
        #expect(c.setDisplays(.asleep, now: t0.addingTimeInterval(60)) == nil)
        let flush = c.setDisplays(.awake, now: t0.addingTimeInterval(120))
        #expect(flush?.signals == [.engineRecompute])
        #expect(flush?.heldFor == 120)
    }

    @Test func sleepWakeSleepNeitherDropsNorDuplicates() {
        var c = ViewRefreshCoalescer()
        _ = c.setDisplays(.asleep, now: t0)
        do { let passed = c.offer(.scanCycle, summary: ScanCycleSummary(samplesChanged: true)); #expect(!passed) }
        let first = c.setDisplays(.awake, now: t0.addingTimeInterval(10))
        #expect(first?.signals == [.scanCycle])

        // Awake: straight through, not added to anything.
        do { let passed = c.offer(.rateLimitWrite); #expect(passed) }

        _ = c.setDisplays(.asleep, now: t0.addingTimeInterval(20))
        do { let passed = c.offer(.liveMeter); #expect(!passed) }
        let second = c.setDisplays(.awake, now: t0.addingTimeInterval(30))
        // Only what was held in the second sleep: the first's scan cycle was
        // already delivered, and the awake write never held.
        #expect(second?.signals == [.liveMeter])
        #expect(second?.scanSummary == nil)
        #expect(second?.heldFor == 10)
    }

    @Test func goingUnknownFromAsleepFlushes() {
        var c = ViewRefreshCoalescer()
        _ = c.setDisplays(.asleep, now: t0)
        do { let passed = c.offer(.engineRecompute); #expect(!passed) }
        #expect(c.setDisplays(.unknown, now: t0)?.signals == [.engineRecompute])
        do { let passed = c.offer(.engineRecompute); #expect(passed) }
    }

    @Test func aHeldScanWithoutASummaryMeansEverything() {
        var c = ViewRefreshCoalescer()
        _ = c.setDisplays(.asleep, now: t0)
        do { let passed = c.offer(.scanCycle, summary: ScanCycleSummary(samplesChanged: true)); #expect(!passed) }
        do { let passed = c.offer(.scanCycle, summary: nil); #expect(!passed) }
        let flush = c.setDisplays(.awake, now: t0)
        #expect(flush?.scanSummary == .everything)
    }

    @Test func mergingKeepsTheAccountOnlyWhenEveryWriterAgrees() {
        let a = ScanCycleSummary(rateLimitsChanged: true, rateLimitAccountId: "A")
        let a2 = ScanCycleSummary(rateLimitsChanged: true, rateLimitAccountId: "A")
        let b = ScanCycleSummary(rateLimitsChanged: true, rateLimitAccountId: "B")
        let unknown = ScanCycleSummary(rateLimitsChanged: true)
        let samples = ScanCycleSummary(samplesChanged: true)

        #expect(a.merged(with: a2).rateLimitAccountId == "A")
        #expect(a.merged(with: b).rateLimitAccountId == nil)
        #expect(a.merged(with: unknown).rateLimitAccountId == nil)
        // A summary that wrote no rate limits says nothing about whose.
        #expect(samples.merged(with: a).rateLimitAccountId == "A")
        #expect(a.merged(with: samples) == ScanCycleSummary(
            samplesChanged: true, rateLimitsChanged: true, rateLimitAccountId: "A"))
    }
}

@Suite("View refresh gate")
@MainActor
struct ViewRefreshGateTests {

    /// A gate on its own center, with a display probe the test controls.
    @MainActor
    private final class Rig {
        let center = NotificationCenter()
        var allAsleep = true
        var lines: [String] = []
        var scans: [ScanCycleSummary?] = []
        var engines = 0
        var observers: [NSObjectProtocol] = []
        private(set) var gate: ViewRefreshGate!

        init() {
            gate = ViewRefreshGate(center: center,
                                   allDisplaysAsleep: { [unowned self] in self.allAsleep },
                                   log: { [unowned self] in self.lines.append($0) })
            observers = [
                center.addObserver(forName: .pacerViewScanCycleDidComplete, object: nil, queue: nil) { [unowned self] note in
                    let summary = note.object as? ScanCycleSummary
                    MainActor.assumeIsolated { self.scans.append(summary) }
                },
                center.addObserver(forName: .pacerViewEngineDidRecompute, object: nil, queue: nil) { [unowned self] _ in
                    MainActor.assumeIsolated { self.engines += 1 }
                },
            ]
        }

        func postScan(_ summary: ScanCycleSummary?) {
            center.post(name: .pacerScanCycleDidComplete, object: summary)
        }
        func postEngine() { center.post(name: .pacerEngineDidRecompute, object: nil) }
    }

    @Test func beforeAnyReportEverythingPassesThroughSynchronously() {
        let rig = Rig()
        rig.postScan(ScanCycleSummary(samplesChanged: true))
        // Delivered within the post: no added latency.
        #expect(rig.scans == [ScanCycleSummary(samplesChanged: true)])
        rig.postEngine()
        #expect(rig.engines == 1)
        var delivered = 0
        rig.gate.offer(.rateLimitWrite) { _ in delivered += 1 }
        #expect(delivered == 1)
    }

    @Test func awakePassesTheOriginalObjectThrough() {
        let rig = Rig()
        rig.gate.displaysReported(asleep: false)
        rig.postScan(nil)
        // A post without a summary stays one: consumers decide what that means.
        #expect(rig.scans.count == 1)
        #expect(rig.scans[0] == nil)
    }

    @Test func asleepHoldsUntilWakeThenDeliversEachOnceMerged() {
        let rig = Rig()
        rig.gate.displaysReported(asleep: true)
        #expect(rig.gate.isHolding)
        #expect(rig.lines == ["displays asleep — holding view refreshes"])

        rig.postScan(ScanCycleSummary(samplesChanged: true))
        rig.postScan(ScanCycleSummary(rateLimitsChanged: true, rateLimitAccountId: "A"))
        rig.postEngine()
        rig.postEngine()
        var writes = 0
        rig.gate.offer(.rateLimitWrite) { _ in writes += 1 }
        rig.gate.offer(.rateLimitWrite) { _ in writes += 1 }
        #expect(rig.scans.isEmpty)
        #expect(rig.engines == 0)
        #expect(writes == 0)

        rig.allAsleep = false
        rig.gate.displaysReported(asleep: false)
        #expect(!rig.gate.isHolding)
        #expect(rig.scans == [ScanCycleSummary(samplesChanged: true, rateLimitsChanged: true,
                                               rateLimitAccountId: "A")])
        #expect(rig.engines == 1)
        #expect(writes == 1)
        #expect(rig.lines.last?.hasPrefix(
            "displays awake — delivered 3 held signal(s): scan cycle, engine recompute, rate-limit write · held ") == true)

        // A second wake report delivers nothing again.
        rig.gate.displaysReported(asleep: false)
        #expect(rig.scans.count == 1)
        #expect(rig.engines == 1)
        #expect(writes == 1)
    }

    @Test func aWakeWithNothingHeldDeliversNothing() {
        let rig = Rig()
        rig.gate.displaysReported(asleep: true)
        rig.gate.displaysReported(asleep: false)
        #expect(rig.scans.isEmpty)
        #expect(rig.engines == 0)
        #expect(rig.lines.last?.hasPrefix("displays awake — delivered 0 held signal(s) · held ") == true)
    }

    /// The system said "asleep", but a display (an external one, Sidecar)
    /// is still on: nothing is held.
    @Test func aSleepReportNotEveryDisplayConfirmsDoesNotHold() {
        let rig = Rig()
        rig.allAsleep = false
        rig.gate.displaysReported(asleep: true)
        #expect(!rig.gate.isHolding)
        rig.postEngine()
        #expect(rig.engines == 1)
        #expect(rig.lines == ["screens reported asleep, but a display is still awake — not holding"])
    }

    /// A display that wakes without a wake notification is noticed at the
    /// next signal, which is delivered with everything held.
    @Test func aSilentWakeIsCaughtByTheNextSignal() {
        let rig = Rig()
        rig.gate.displaysReported(asleep: true)
        rig.postScan(ScanCycleSummary(samplesChanged: true))
        #expect(rig.scans.isEmpty)
        rig.allAsleep = false
        rig.postEngine()
        #expect(!rig.gate.isHolding)
        #expect(rig.scans == [ScanCycleSummary(samplesChanged: true)])
        #expect(rig.engines == 1)
    }

    @Test func aDisplayChangeReevaluates() {
        let rig = Rig()
        rig.gate.displaysReported(asleep: true)
        rig.postEngine()
        rig.allAsleep = false
        rig.gate.displaysMayHaveChanged()
        #expect(!rig.gate.isHolding)
        #expect(rig.engines == 1)
        // Back to every display asleep while the system still says asleep.
        rig.allAsleep = true
        rig.gate.displaysMayHaveChanged()
        #expect(rig.gate.isHolding)
    }

    @Test func sleepWakeSleepWakeDeliversEachHoldOnce() {
        let rig = Rig()
        rig.gate.displaysReported(asleep: true)
        rig.postEngine()
        rig.gate.displaysReported(asleep: false)
        #expect(rig.engines == 1)
        rig.postEngine()
        #expect(rig.engines == 2)
        rig.gate.displaysReported(asleep: true)
        rig.postScan(ScanCycleSummary(samplesChanged: true))
        rig.gate.displaysReported(asleep: false)
        #expect(rig.engines == 2)
        #expect(rig.scans == [ScanCycleSummary(samplesChanged: true)])
    }

    @Test func untilAwakeReturnsAtOnceWhileAwake() async {
        let rig = Rig()
        await rig.gate.untilAwake()
        rig.gate.displaysReported(asleep: false)
        await rig.gate.untilAwake()
    }

    @Test func untilAwakeWaitsForTheWakeAndResumesOnce() async {
        let rig = Rig()
        rig.gate.displaysReported(asleep: true)
        var resumed = 0
        let loopA = Task { @MainActor in await rig.gate.untilAwake(); resumed += 1 }
        let loopB = Task { @MainActor in await rig.gate.untilAwake(); resumed += 1 }
        // Let both reach their wait.
        for _ in 0..<10 { await Task.yield() }
        #expect(resumed == 0)
        rig.allAsleep = false
        rig.gate.displaysReported(asleep: false)
        await loopA.value
        await loopB.value
        #expect(resumed == 2)
        #expect(rig.lines.last?.contains("minute tick ×2") == true)
    }

    @Test func cancellingAWaitingLoopResumesIt() async {
        let rig = Rig()
        rig.gate.displaysReported(asleep: true)
        let loop = Task { @MainActor in await rig.gate.untilAwake() }
        for _ in 0..<10 { await Task.yield() }
        loop.cancel()
        await loop.value
        #expect(rig.gate.isHolding)
    }

    @Test func durationsReadShort() {
        #expect(ViewRefreshGate.duration(42) == "42s")
        #expect(ViewRefreshGate.duration(725) == "12m 5s")
        #expect(ViewRefreshGate.duration(6 * 3600 + 180) == "6h 3m")
    }
}
