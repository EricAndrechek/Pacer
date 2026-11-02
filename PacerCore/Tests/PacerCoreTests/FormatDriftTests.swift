import Foundation
import Testing
@testable import PacerCore

@Suite(.serialized) struct FormatDriftTests {
    private func store() -> UserDefaults {
        let suite = "pacer.formatdrift.\(UUID().uuidString)"
        FormatDrift.resetLaunchState()
        return UserDefaults(suiteName: suite)!
    }

    @Test func reportsOnlyTheFirstSighting() {
        let s = store()
        #expect(FormatDrift.firstSighting("model", "claude-x-1", store: s))
        #expect(!FormatDrift.firstSighting("model", "claude-x-1", store: s))
        #expect(FormatDrift.firstSighting("cc_version", "claude-x-1", store: s))
    }

    @Test func rememberedAcrossLaunches() {
        let s = store()
        #expect(FormatDrift.firstSighting("model", "m1", store: s))
        FormatDrift.resetLaunchState()
        #expect(!FormatDrift.firstSighting("model", "m1", store: s))
    }

    @Test func refusesFreeTextAndPaths() {
        let s = store()
        #expect(!FormatDrift.firstSighting("model", "my secret project", store: s))
        #expect(!FormatDrift.firstSighting("model", "/Users/someone/x", store: s))
        #expect(!FormatDrift.firstSighting("model", "", store: s))
        #expect(FormatDrift.firstSighting("cc_version", "2.1.5", store: s))
    }

    @Test func stopsAtCapacity() {
        let s = store()
        for i in 0..<FormatDrift.capacity { #expect(FormatDrift.firstSighting("model", "m\(i)", store: s)) }
        #expect(!FormatDrift.firstSighting("model", "one-too-many", store: s))
    }

    @Test func clickBuckets() {
        #expect(FormatDrift.clickBucket(delaySeconds: 0.01) == "lt50")
        #expect(FormatDrift.clickBucket(delaySeconds: 0.07) == "50_100")
        #expect(FormatDrift.clickBucket(delaySeconds: 0.2) == "100_250")
        #expect(FormatDrift.clickBucket(delaySeconds: 0.5) == "250_1000")
        #expect(FormatDrift.clickBucket(delaySeconds: 3) == "gt1000")
    }
}
