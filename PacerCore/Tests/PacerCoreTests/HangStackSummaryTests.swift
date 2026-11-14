import Darwin
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
        // 0x1abc is in no loaded image, so it stays an address.
        #expect(HangStackSummary.format(frames: [("a", nil), (nil, "0x1abc"), ("  ", nil)]) == "? < 0x1abc < a")
    }

    @Test func anAddressInsideALoadedImageIsNamedWithoutItsPath() {
        // A libc function's own address: dladdr names its image and symbol.
        let address = unsafeBitCast(strlen as @convention(c) (UnsafePointer<CChar>) -> Int, to: UInt.self)
        let named = HangStackSummary.locate("0x" + String(address, radix: 16))
        #expect(named.contains("strlen"))
        #expect(!named.contains("/"))
    }

    @Test func longNamesAreClippedAndAnEmptyStackIsNil() {
        let long = String(repeating: "x", count: 200)
        #expect(HangStackSummary.format(frames: [(long, nil)])!.count == 91)
        #expect(HangStackSummary.format(frames: []) == nil)
    }
}
