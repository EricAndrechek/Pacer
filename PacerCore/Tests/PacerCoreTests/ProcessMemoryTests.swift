import Foundation
import Testing
@testable import PacerCore

@Suite("Process memory (#337)")
struct ProcessMemoryTests {

    @Test func readsTheLiveProcess() {
        let m = ProcessMemory.current()
        #expect(m.footprint > 0)
        #expect(m.peakFootprint >= m.footprint)
        #expect(m.mallocLive > 0)
        #expect(m.mallocDirty > 0)
    }

    @Test func summaryHasTheGreppableShape() {
        let m = ProcessMemory(footprint: 412_000_000, peakFootprint: 2_190_000_000,
                              mallocLive: 244_000_000, mallocDirty: 566_000_000)
        #expect(m.summary == "footprint 412 MB peak 2190 MB malloc live 244 MB dirty 566 MB")
        #expect(m.mallocFragmentation == 322_000_000)
        let clean = ProcessMemory(footprint: 1, peakFootprint: 1, mallocLive: 9, mallocDirty: 5)
        #expect(clean.mallocFragmentation == 0)
    }
}
