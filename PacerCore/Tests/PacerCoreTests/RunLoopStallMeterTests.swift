import Foundation
import Testing
@testable import PacerCore

// What the meter has to get right is the shape of CFRunLoop's iteration:
// top of loop (`beforeTimers`) → sources → `beforeWaiting` → sleep →
// `afterWaiting` → handle the message → top of loop again. A stall is the
// time between two chances to handle input, which is from waking to the next
// sleep, or to the next top of loop when the loop polled instead of sleeping.

@Suite("Run loop stall meter")
struct RunLoopStallMeterTests {

    /// Feed a script of (activity, seconds) and collect what it reports.
    private func stalls(_ script: [(RunLoopStallMeter.Activity, TimeInterval)],
                        threshold: TimeInterval = 0.1) -> [TimeInterval] {
        var meter = RunLoopStallMeter(threshold: threshold)
        return script.compactMap { meter.record($0.0, at: $0.1) }
    }

    private func ms(_ values: [TimeInterval]) -> [Int] { values.map { Int(($0 * 1000).rounded()) } }

    @Test("a wake that handles its message and sleeps again is one stretch, ending after the commit")
    func oneIterationIsOneStretch() {
        // Woke at 10.000, the handler ran, the top of loop came round, and the
        // late observer saw `beforeWaiting` at 10.180 (after CA's commit).
        let found = stalls([
            (.beforeTimers, 9.990), (.beforeWaiting, 9.991),
            (.afterWaiting, 10.000), (.beforeTimers, 10.120), (.beforeWaiting, 10.180),
        ])
        #expect(ms(found) == [180])
    }

    /// The failure that produced #168: a throttled app's loop wakes late, but
    /// the time it spent asleep is not work. Only the stretches count.
    @Test("time asleep is never a stall, however long")
    func sleepIsNotAStall() {
        var script: [(RunLoopStallMeter.Activity, TimeInterval)] = []
        var t: TimeInterval = 100
        for _ in 0..<50 {                      // wakes every ~220 ms, works 2 ms
            script += [(.afterWaiting, t), (.beforeTimers, t + 0.001), (.beforeWaiting, t + 0.002)]
            t += 0.22
        }
        #expect(stalls(script).isEmpty)
    }

    @Test("an iteration that polls instead of sleeping ends at the next top of loop")
    func pollingSplitsStretches() {
        // Sources handled at 20.000–20.150 so the loop polled the port and went
        // round: that was a chance to take input, so two separate stretches.
        let found = stalls([
            (.afterWaiting, 20.000), (.beforeTimers, 20.010),
            (.beforeTimers, 20.150),                 // polled, no sleep
            (.beforeWaiting, 20.260),
        ])
        #expect(ms(found) == [150, 110])
    }

    @Test("short stretches are not reported")
    func underThresholdIsQuiet() {
        #expect(stalls([(.afterWaiting, 1.0), (.beforeWaiting, 1.099)]).isEmpty)
        #expect(ms(stalls([(.afterWaiting, 1.0), (.beforeWaiting, 1.1)])) == [100])
    }

    /// AppKit handles an event between one run of the loop and the next:
    /// `nextEventMatchingMask` returns (`exit`), `sendEvent` runs the click's
    /// action, then the next `nextEventMatchingMask` starts a run (`entry`).
    /// A slow action has to show up there.
    @Test("work between one run of the loop and the next is measured")
    func sendEventBetweenRuns() {
        let found = stalls([
            (.entry, 5.000), (.beforeTimers, 5.001), (.beforeWaiting, 5.002),
            (.afterWaiting, 5.500), (.exit, 5.503),
            (.entry, 5.903),                          // the action took 400 ms
            (.beforeTimers, 5.904), (.beforeWaiting, 5.905),
        ])
        #expect(ms(found) == [400])
    }

    /// A menu or a modal runs its own loop inside the outer handler, and that
    /// loop handles input. Its time asleep must not be charged to the outer
    /// stretch, and a slow step inside it must still be caught.
    @Test("a nested run is measured on its own terms")
    func nestedRun() {
        let found = stalls([
            (.afterWaiting, 1.000),                   // outer wakes: a click opens a menu
            (.entry, 1.020),                          // menu tracking starts
            (.beforeTimers, 1.021), (.beforeWaiting, 1.022),
            (.afterWaiting, 3.000), (.beforeTimers, 3.250), (.beforeWaiting, 3.260),  // one slow step
            (.afterWaiting, 4.000), (.exit, 4.001),   // menu closes
            (.beforeTimers, 4.010), (.beforeWaiting, 4.020),
        ])
        #expect(ms(found) == [260])
    }
}
