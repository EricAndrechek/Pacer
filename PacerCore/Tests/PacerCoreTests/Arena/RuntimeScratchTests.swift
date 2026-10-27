import Foundation
import Testing
@testable import PacerCore

/// The networks' scratch (`FMScratch`, `FMWorkspacePool`, `FMWorkspace`): one
/// workspace kept a network, at most `keepBytes` of it; a call that needed
/// more gives its large buffers back and the next one allocates them at once
/// at the size they reached.
@Suite("Arena runtime: network scratch is bounded", .serialized)
struct RuntimeScratchTests {

    enum Slot: Int, CaseIterable { case small, large }
    typealias Workspace = FMWorkspace<Slot>
    static let floats = MemoryLayout<Float>.size

    @Test func aWorkspaceFreesItsLargeBuffersAndRemembersTheirSize() {
        let ws = Workspace()
        _ = ws.buf(.small, 1000)
        _ = ws.buf(.large, 4_000_000)
        #expect(ws.bytes == (1000 + 4_000_000) * Self.floats)
        #expect(ws.shrink(above: FMScratch.slotBytes))
        #expect(ws.bytes == 1000 * Self.floats)
        #expect(!ws.shrink(above: FMScratch.slotBytes))
        // Asked again for less, it comes back at the size it reached: one
        // allocation for the call, not a chain of growths.
        _ = ws.buf(.large, 10)
        #expect(ws.bytes == (1000 + 4_000_000) * Self.floats)
        // Within capacity: the same buffer.
        let a = ws.buf(.small, 500), b = ws.buf(.small, 1000)
        #expect(a == b)
    }

    @Test func onePoolKeepsOneWorkspaceUnderTheCap() {
        let pool = FMWorkspacePool<Workspace>()
        var first: Workspace?
        pool.with { ws in _ = ws.buf(.small, 1 << 18); first = ws }
        #expect(pool.keptBytes == (1 << 18) * Self.floats)
        // Reused, not remade.
        pool.with { ws in #expect(ws === first) }
        // Two at once (the scorer and the live forecaster): one kept after.
        pool.with { _ in pool.with { ws in _ = ws.buf(.small, 1 << 10) } }
        #expect(pool.keptBytes <= (1 << 18) * Self.floats)
        // A call past the cap: its large buffer goes, the workspace stays
        // with the small one.
        pool.with { ws in _ = ws.buf(.large, FMScratch.keepBytes / Self.floats + 1) }
        #expect(pool.keptBytes <= (1 << 18) * Self.floats)
        #expect(pool.stats.overCap == 1)
        #expect(pool.stats.largest > FMScratch.keepBytes)
        FMScratch.release()
        #expect(pool.keptBytes == 0)
    }
}
