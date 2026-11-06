import Foundation
import Testing
@testable import PacerCore

/// When the grader starts on a launch (`ArenaStartGate`).
@Suite("Arena runtime: the start gate")
struct RuntimeStartGateTests {
    final class Rig: @unchecked Sendable {
        let lock = NSLock()
        var value = Date(timeIntervalSince1970: 1_800_000_000)
        var lines: [String] = []
        var started = 0
        var now: Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ s: TimeInterval) { lock.lock(); value = value.addingTimeInterval(s); lock.unlock() }
        func log(_ l: String) { lock.lock(); lines.append(l); lock.unlock() }
        func go() { lock.lock(); started += 1; lock.unlock() }
        func gate() -> ArenaStartGate { ArenaStartGate(now: { self.now }, log: { self.log($0) }, start: { self.go() }) }
    }

    /// Every signal, in whatever order, and once; the log says how long each
    /// took.
    @Test func itOpensOnTheLastSignalAndSaysWhatItWaitedFor() {
        let r = Rig()
        let g = r.gate()
        g.mark(.store)
        r.advance(2)
        g.mark(.firstRefit)
        r.advance(3)
        g.mark(.recordBackfill)
        #expect(r.started == 0)
        r.advance(5)
        g.mark(.firstScan)
        #expect(r.started == 1)
        #expect(r.lines == ["grader starting after 10.0 s, launch work done (store 0.0 s, first scan 10.0 s, "
                            + "first refit 2.0 s, record backfill 5.0 s)"])
        g.mark(.firstScan)
        g.giveUp()
        #expect(r.started == 1)
        #expect(r.lines.count == 1)
    }

    /// A signal that never comes: it starts anyway and names what never came.
    @Test func theSafetyNetOpensItAndSaysWhatNeverCame() {
        let r = Rig()
        let g = r.gate()
        g.mark(.store)
        g.mark(.firstRefit)
        r.advance(ArenaStartGate.safetyNet)
        g.giveUp()
        #expect(r.started == 1)
        let line = try? #require(r.lines.first)
        #expect(line?.contains("still waiting for first scan, record backfill") == true)
        #expect(line?.hasPrefix("grader starting after 1800.0 s") == true)
    }

    /// The real timer, short.
    @Test func theSafetyNetRunsByItself() async {
        let r = Rig()
        let g = r.gate()
        g.armSafetyNet(after: 0.01)
        // Background priority: on a loaded Mac it can wait a long while for a
        // thread, so this waits generously.
        for _ in 0..<24_000 where r.started == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(r.started == 1)
    }

    @Test func aStoppedAppNeverStartsIt() async {
        let r = Rig()
        let g = r.gate()
        g.armSafetyNet(after: 0.01)
        g.cancel()
        for s in ArenaStartGate.Signal.allCases { g.mark(s) }
        g.giveUp()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(r.started == 0)
        #expect(r.lines.isEmpty)
    }
}
