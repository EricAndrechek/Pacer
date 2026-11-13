import Foundation
import Testing
@testable import PacerCore

@Suite struct OffMainQueueTests {
    @Test func runsOffTheMainThreadAndInOrder() async {
        let q = OffMainQueue(label: "test.offmain")
        let result = await withCheckedContinuation { (c: CheckedContinuation<([Int], Bool), Never>) in
            let box = Box()
            for i in 0..<5 { q.run { box.append(i, main: Thread.isMainThread) } }
            q.run { c.resume(returning: box.snapshot()) }
        }
        #expect(result.0 == [0, 1, 2, 3, 4])
        #expect(result.1 == false)
    }

    /// `perform` returns only after its work has run, so what the caller does
    /// next (posting a reset notice) lands after it (removing the old alert).
    @Test("perform waits for its work, which runs off the main thread")
    @MainActor
    func performWaits() async {
        let q = OffMainQueue(label: "test.offmain.perform")
        let box = Box()
        // Something already queued must also finish first: the queue is serial.
        q.run { Thread.sleep(forTimeInterval: 0.05); box.append(1, main: Thread.isMainThread) }
        await q.perform { box.append(2, main: Thread.isMainThread) }
        let (items, sawMain) = box.snapshot()
        #expect(items == [1, 2])
        #expect(sawMain == false)
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Int] = []
        private var sawMain = false
        func append(_ i: Int, main: Bool) { lock.lock(); items.append(i); sawMain = sawMain || main; lock.unlock() }
        func snapshot() -> ([Int], Bool) { lock.lock(); defer { lock.unlock() }; return (items, sawMain) }
    }
}
