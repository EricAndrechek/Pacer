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
        Log.sink.withLock { $0 = Log.Sink(write: { c.sink($0) }) }
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

    /// The 0.9.0 crash: the sink was a bare closure in a `Mutex`, and every
    /// `withLock { $0 }` stored it two reabstraction thunks deeper, so the
    /// writer's stack grew two frames per log line until it overflowed (6,672
    /// deep in the owner's crash report). Pushing 1,500 lines through an
    /// installed sink must leave the stack depth inside it where it started.
    /// Under the old shape it grows by about 3,000 frames.
    @Test("sink round trips do not deepen the writer's stack")
    func sinkRoundTripsDoNotDeepenTheStack() {
        let depths = Mutex<[Int]>([])
        let old = Log.sink.withLock { $0 }
        Log.sink.withLock {
            $0 = Log.Sink(write: { data in
                guard String(decoding: data, as: UTF8.self).contains("[Depth] ") else { return }
                let depth = Thread.callStackReturnAddresses.count
                depths.withLock { $0.append(depth) }
            })
        }
        defer { Log.flush(); Log.sink.withLock { $0 = old } }
        for i in 0..<1_500 { Log.write("Depth", "line \(i)") }
        #expect(Log.flush(timeout: 10))
        let seen = depths.withLock { $0 }
        #expect(seen.count == 1_500)
        if let first = seen.first, let last = seen.last {
            #expect(last <= first + 2, "stack grew from \(first) to \(last) frames over \(seen.count) lines")
        }
    }

    /// `writeAll` is plain `write(2)`: it must write every byte of a payload
    /// far larger than one `write` call takes at a time, from any thread,
    /// including one with a deliberately tiny stack.
    @Test("writeAll writes every byte from a thread with a tiny stack")
    func writeAllOnASmallStack() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pacer-log-writeall-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        try #require(fd >= 0)
        let payload = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            Log.writeAll(payload, to: fd)
            done.signal()
        }
        thread.stackSize = 64 * 1024
        thread.start()
        #expect(done.wait(timeout: .now() + 10) == .success)
        close(fd)
        #expect(try Data(contentsOf: url) == payload)
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
