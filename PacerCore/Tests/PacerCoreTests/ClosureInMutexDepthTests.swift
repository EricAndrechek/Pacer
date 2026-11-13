import Foundation
import Synchronization
import Testing
@testable import PacerCore

/// A bare closure stored in a `Mutex` and read with `withLock { $0 }` comes
/// back two reabstraction thunks deeper on every read, so each later call runs
/// two frames deeper. That is how 0.9.0's log writer overflowed its stack.
/// Every closure Pacer keeps in a lock must be read back without that growth.
@Suite("Closures kept in a Mutex", .serialized)
struct ClosureInMutexDepthTests {
    @Test("reading ArenaBudgetGovernor.onModeChange does not deepen later calls")
    func governorObserverDepthIsFlat() {
        let old = ArenaBudgetGovernor.onModeChange
        defer { ArenaBudgetGovernor.onModeChange = old }
        let depths = Mutex<[Int]>([])
        ArenaBudgetGovernor.onModeChange = { _ in
            let depth = Thread.callStackReturnAddresses.count
            depths.withLock { $0.append(depth) }
        }
        for _ in 0..<1_000 { ArenaBudgetGovernor.onModeChange("probe") }
        let seen = depths.withLock { $0 }
        #expect(seen.count == 1_000)
        if let first = seen.first, let last = seen.last {
            #expect(last <= first + 2, "depth grew from \(first) to \(last) over 1,000 reads")
        }
    }
}
