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

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Int] = []
        private var sawMain = false
        func append(_ i: Int, main: Bool) { lock.lock(); items.append(i); sawMain = sawMain || main; lock.unlock() }
        func snapshot() -> ([Int], Bool) { lock.lock(); defer { lock.unlock() }; return (items, sawMain) }
    }
}
