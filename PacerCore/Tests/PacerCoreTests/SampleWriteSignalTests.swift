import Foundation
import Testing
@testable import PacerCore

/// `SampleWriteSignal.generation` is what the menu-bar label keys its reads of
/// today's totals and the newest turn on (PACER-19). It must move on every
/// cycle that wrote samples, and on nothing else, or the label either misses
/// a turn or reads the store for nothing.
@Suite("Sample write signal")
@MainActor
struct SampleWriteSignalTests {

    private static func post(_ center: NotificationCenter, _ summary: ScanCycleSummary?) {
        center.post(name: .pacerScanCycleDidComplete, object: summary)
    }

    @Test func aCycleThatWroteSamplesMovesIt() {
        let center = NotificationCenter()
        let signal = SampleWriteSignal(center: center)
        #expect(signal.generation == 0)

        Self.post(center, ScanCycleSummary(samplesChanged: true))
        #expect(signal.generation == 1)
        // Every one counts, however close together: two cycles in the same
        // second are two writes.
        Self.post(center, ScanCycleSummary(samplesChanged: true, projectAttributionChanged: true))
        #expect(signal.generation == 2)
    }

    @Test func aPollOrARebucketingAloneLeavesIt() {
        let center = NotificationCenter()
        let signal = SampleWriteSignal(center: center)

        // A poll writes rate-limit rows; the label reloads those on
        // `RateLimitWriteSignal`, not on this.
        Self.post(center, ScanCycleSummary(rateLimitsChanged: true, rateLimitAccountId: "orgA"))
        // An alias edit moves turns between projects, not between days,
        // models or accounts.
        Self.post(center, ScanCycleSummary(projectAttributionChanged: true))
        #expect(signal.generation == 0)
    }

    /// A post that does not say what changed can only cause a read.
    @Test func aPostWithoutASummaryCounts() {
        let center = NotificationCenter()
        let signal = SampleWriteSignal(center: center)
        Self.post(center, nil)
        #expect(signal.generation == 1)
    }
}
