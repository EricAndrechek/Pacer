import Testing
@testable import PacerCore

@Suite struct UsageBandTests {

    @Test func boundariesRoundUpToWarmerBand() {
        // 49.99 stays green; 50.0 promotes to yellow.
        #expect(UsageBand(percentage: 0) == .green)
        #expect(UsageBand(percentage: 49.99) == .green)
        #expect(UsageBand(percentage: 50.0) == .yellow)
        #expect(UsageBand(percentage: 74.99) == .yellow)
        #expect(UsageBand(percentage: 75.0) == .orange)
        #expect(UsageBand(percentage: 89.99) == .orange)
        #expect(UsageBand(percentage: 90.0) == .red)
        #expect(UsageBand(percentage: 100.0) == .red)
        #expect(UsageBand(percentage: 999) == .red)  // out-of-range still red
    }

    @Test func negativePercentageStaysGreen() {
        // Defensive: shouldn't happen, but a server-side bug returning
        // a negative shouldn't promote to red.
        #expect(UsageBand(percentage: -5) == .green)
    }
}
