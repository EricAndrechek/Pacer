import CoreFoundation
import Foundation
import Testing
@testable import PacerCore

/// `HangWatch.Core`, driven activity by activity: what counts as one stretch
/// of being stuck, when it is reported, and when the timer stays unarmed.
@Suite("Hang watch bookkeeping")
struct HangWatchCoreTests {

    private typealias Hang = HangWatch.Hang

    /// `check`'s result, comparable.
    private struct Check: Equatable {
        let event: HangWatch.Event?
        let next: TimeInterval?
        init(_ event: HangWatch.Event?, _ next: TimeInterval?) { self.event = event; self.next = next }
        init(_ result: (event: HangWatch.Event?, next: TimeInterval?)) { self.init(result.event, result.next) }
    }

    @Test("launch: busy from the start, through the first entry, until the loop first sleeps")
    func launchStretch() {
        var core = HangWatch.Core(threshold: 2, heartbeat: 5, busySinceLaunch: 0)
        #expect(Check(core.check(at: 1)) == Check(nil, 2))
        let began = core.check(at: 2.1)
        #expect(began.event == .began(Hang(start: 0, duration: 2.1, atLaunch: true)))
        #expect(began.next == 7.1)
        #expect(core.check(at: 7.1).event == .continuing(Hang(start: 0, duration: 7.1, atLaunch: true)))
        // `NSApplication.run` starting the loop is not a chance to handle input.
        #expect(core.record(.entry, at: 8) == nil)
        #expect(core.record(.beforeTimers, at: 8) == nil)
        #expect(core.record(.beforeWaiting, at: 9) == .ended(Hang(start: 0, duration: 9, atLaunch: true)))
        // Asleep: the timer is left unarmed.
        #expect(Check(core.check(at: 12)) == Check(nil, nil))
    }

    @Test("short work between sleeps is never a hang, and leaves the timer unarmed")
    func idleLoop() {
        var core = HangWatch.Core(threshold: 2, heartbeat: 5, busySinceLaunch: nil)
        #expect(core.record(.afterWaiting, at: 0) == nil)
        #expect(core.record(.beforeWaiting, at: 1.5) == nil)
        #expect(Check(core.check(at: 2)) == Check(nil, nil))
        #expect(core.record(.afterWaiting, at: 30) == nil)
        #expect(Check(core.check(at: 31)) == Check(nil, 32))
        #expect(core.record(.beforeWaiting, at: 31.5) == nil)
    }

    @Test("a hang after launch is reported once, then ends with its whole length")
    func runningHang() {
        var core = HangWatch.Core(threshold: 2, heartbeat: 5, busySinceLaunch: nil)
        _ = core.record(.afterWaiting, at: 100)
        #expect(Check(core.check(at: 101)) == Check(nil, 102))
        #expect(core.check(at: 102.5).event == .began(Hang(start: 100, duration: 2.5, atLaunch: false)))
        #expect(core.check(at: 107.5).event == .continuing(Hang(start: 100, duration: 7.5, atLaunch: false)))
        #expect(core.record(.beforeWaiting, at: 110) == .ended(Hang(start: 100, duration: 10, atLaunch: false)))
    }

    @Test("polling without sleeping starts a new stretch, as in the stall meter")
    func pollingSplits() {
        var core = HangWatch.Core(threshold: 2, heartbeat: 5, busySinceLaunch: nil)
        _ = core.record(.afterWaiting, at: 0)
        #expect(core.record(.beforeTimers, at: 0.1) == nil)   // woke and came round: same stretch
        #expect(core.record(.beforeTimers, at: 1.5) == nil)   // polled: a new one from here
        #expect(Check(core.check(at: 2.2)) == Check(nil, 3.5))
    }

    @Test("a nested loop (a menu, a modal alert) ends the stretch it interrupted")
    func nestedLoopEnds() {
        var core = HangWatch.Core(threshold: 2, heartbeat: 5, busySinceLaunch: nil)
        _ = core.record(.entry, at: 0)
        _ = core.record(.afterWaiting, at: 1)
        _ = core.check(at: 3.5)
        #expect(core.record(.entry, at: 4) == .ended(Hang(start: 1, duration: 3, atLaunch: false)))
        #expect(core.record(.beforeWaiting, at: 4.1) == nil)
    }
}

/// The real observers and the real timer, on a run loop of their own thread,
/// with work of known length.
@Suite("Hang watch, on a real run loop")
struct HangWatchRunLoopTests {

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [HangWatch.Event] = []
        func add(_ e: HangWatch.Event) { lock.lock(); events.append(e); lock.unlock() }
        var values: [HangWatch.Event] { lock.lock(); defer { lock.unlock() }; return events }
    }

    /// Run a loop for `seconds` with a timer at each `(at, blocksFor)`. With
    /// `blockBeforeRun`, the thread is stuck that long before the loop runs at
    /// all, like `PacerAppDelegate.init` before `NSApplication.run`.
    private func run(for seconds: TimeInterval, timers: [(at: TimeInterval, blocksFor: TimeInterval)],
                     blockBeforeRun: TimeInterval? = nil, threshold: TimeInterval = 0.3,
                     heartbeat: TimeInterval = 0.2) -> [HangWatch.Event] {
        let collected = Collected()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            let loop = CFRunLoopGetCurrent()!
            let watch = HangWatch(runLoop: loop, threshold: threshold, heartbeat: heartbeat,
                                  startsBusy: blockBeforeRun != nil) { collected.add($0) }
            if let blockBeforeRun { usleep(useconds_t(blockBeforeRun * 1_000_000)) }
            let now = CFAbsoluteTimeGetCurrent()
            for t in timers {
                let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, now + t.at, 0, 0, 0) { _ in
                    usleep(useconds_t(t.blocksFor * 1_000_000))
                }
                CFRunLoopAddTimer(loop, timer, .defaultMode)
            }
            let keepAlive = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, now + seconds + 60, 0, 0, 0) { _ in }
            CFRunLoopAddTimer(loop, keepAlive, .defaultMode)
            CFRunLoopRunInMode(.defaultMode, seconds, false)
            watch.invalidate()
            done.signal()
        }
        thread.start()
        done.wait()
        // `.ended` is delivered on the watch's queue after the loop moved on.
        Thread.sleep(forTimeInterval: 0.3)
        return collected.values
    }

    private func ended(_ events: [HangWatch.Event]) -> [HangWatch.Hang] {
        events.compactMap { if case .ended(let h) = $0 { h } else { nil } }
    }

    @Test("work that blocks past the threshold is reported while it lasts, then with its length")
    func blockingWorkIsAHang() {
        let events = run(for: 2.0, timers: [(at: 0.1, blocksFor: 1.0)])
        guard case .began(let began)? = events.first else {
            Issue.record("no .began: \(events)"); return
        }
        #expect(began.duration >= 0.3 && !began.atLaunch)
        #expect(events.contains { if case .continuing = $0 { true } else { false } })
        let done = ended(events)
        #expect(done.count == 1)
        // A lower bound: a loaded machine can only make it longer.
        #expect(done.allSatisfy { $0.duration >= 0.95 && $0.start == began.start })
    }

    @Test("an idle loop with short work reports nothing")
    func idleLoopIsQuiet() {
        let events = run(for: 1.5, timers: [(at: 0.1, blocksFor: 0.02), (at: 0.8, blocksFor: 0.02)])
        #expect(events.isEmpty)
    }

    @Test("a thread stuck before its loop ever runs is a launch hang")
    func stuckBeforeTheLoopRuns() {
        let events = run(for: 0.6, timers: [], blockBeforeRun: 0.8)
        guard case .began(let began)? = events.first else {
            Issue.record("no .began: \(events)"); return
        }
        #expect(began.atLaunch)
        let done = ended(events)
        #expect(done.count == 1)
        #expect(done.allSatisfy { $0.atLaunch && $0.duration >= 0.75 })
    }
}

@Suite("Hang marker")
struct HangMarkerTests {

    private func tempURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pacer-hang-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(HangMarker.fileName)
    }

    @Test("a leftover marker is read once, then gone")
    func leftoverIsTakenOnce() throws {
        let url = try tempURL()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let marker = HangMarker(startedAt: start, lastSeenAt: start.addingTimeInterval(62),
                                atLaunch: true, version: "0.8.1")
        try marker.write(to: url)
        let taken = try #require(HangMarker.takeLeftover(at: url))
        #expect(taken == marker)
        #expect(taken.duration == 62)
        #expect(HangMarker.takeLeftover(at: url) == nil)
    }

    @Test("a torn marker is removed without a report")
    func tornMarker() throws {
        let url = try tempURL()
        try Data("{\"startedAt\":".utf8).write(to: url)
        #expect(HangMarker.takeLeftover(at: url) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
