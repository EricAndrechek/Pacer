import Foundation
import Synchronization
import Testing
@testable import PacerCore

/// `Log.write` must not wait on the sink, and must keep order.
@Suite("Log writes", .serialized)
struct LogAsyncTests {
    private final class Collector: @unchecked Sendable {
        let lines = Mutex<[String]>([])
        let gate = DispatchSemaphore(value: 0)
        let blocked: Bool
        init(blocked: Bool) { self.blocked = blocked }
        /// A one-shot gate, not a per-line semaphore: the sink is process-wide,
        /// so while it is swapped in, lines from suites running in parallel
        /// pass through it too. Counting one signal per expected line let
        /// those strangers use up the signals, the writer waited forever, and
        /// `Log.flush()` hung the whole `swift test` run. Each line that gets
        /// through re-signals for the next, so one `open()` lets everything
        /// through, however many lines arrive.
        func sink(_ data: Data) {
            if blocked { gate.wait(); gate.signal() }
            lines.withLock { $0.append(String(decoding: data, as: UTF8.self)) }
        }
        func open() { gate.signal() }
    }

    private func withSink<T>(_ c: Collector, _ body: () -> T) -> T {
        let old = Log.sink.withLock { $0 }
        Log.sink.withLock { $0 = { c.sink($0) } }
        defer { Log.flush(); Log.sink.withLock { $0 = old } }
        return body()
    }

    @Test("a burst of writes returns while the sink is blocked, then lands in order")
    func nonBlockingAndOrdered() {
        let c = Collector(blocked: true)
        let n = 500
        let elapsed = withSink(c) { () -> TimeInterval in
            let start = Date()
            for i in 0..<n { Log.write("T", "line \(i)") }
            let took = Date().timeIntervalSince(start)
            // Open the gate once; every queued line, ours or another suite's,
            // then drains.
            c.open()
            Log.flush()
            return took
        }
        #expect(elapsed < 1.0, "write blocked on the sink: \(elapsed)s")
        // Other suites may log meanwhile; only this test's tag counts.
        let lines = c.lines.withLock { $0 }.filter { $0.contains("] [T] ") || $0.contains("[T] ") }
        #expect(lines.count == n)
        for (i, l) in lines.enumerated() { #expect(l.hasSuffix("[T] line \(i)\n")) }
    }

    @Test("flush waits for lines already queued")
    func flushDrains() {
        let c = Collector(blocked: false)
        withSink(c) {
            Log.write("T", "a"); Log.write("T", "b")
            Log.flush()
            #expect(c.lines.withLock { $0.filter { $0.contains("[T] ") }.count } == 2)
        }
    }
}
