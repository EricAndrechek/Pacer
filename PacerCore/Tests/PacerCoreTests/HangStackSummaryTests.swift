import Testing
@testable import PacerCore

@Suite("Hang stack summary")
struct HangStackSummaryTests {
    @Test func innermostFrameComesFirst() {
        let line = HangStackSummary.format(frames: [("main", nil), ("runloop", nil), ("fault_in", nil)])
        #expect(line == "fault_in < runloop < main")
    }

    @Test func keepsOnlyTheTopTwelve() {
        let frames = (0..<30).map { (function: Optional("f\($0)"), address: String?.none) }
        let parts = HangStackSummary.format(frames: frames)!.components(separatedBy: " < ")
        #expect(parts.count == 12)
        #expect(parts.first == "f29")
        #expect(parts.last == "f18")
    }

    @Test func unnamedFramesFallBackToTheirAddress() {
        #expect(HangStackSummary.format(frames: [("a", nil), (nil, "0x1abc"), ("  ", nil)]) == "? < 0x1abc < a")
    }

    @Test func longNamesAreClippedAndAnEmptyStackIsNil() {
        let long = String(repeating: "x", count: 200)
        #expect(HangStackSummary.format(frames: [(long, nil)])!.count == 91)
        #expect(HangStackSummary.format(frames: []) == nil)
    }
}
