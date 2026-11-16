import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// Views key incremental reloads on `generation` and full reloads on
/// `historyGeneration`. A fold must move both; a live write only the first,
/// or every poll would throw away the pace chart's loaded window (#142).
@MainActor
@Test func aFoldRewritesHistoryAndALiveWriteDoesNot() {
    let signal = RateLimitWriteSignal.shared
    let generation = signal.generation, history = signal.historyGeneration

    signal.note(Date())
    #expect(signal.generation == generation &+ 1)
    #expect(signal.historyGeneration == history)

    signal.noteHistoryRewritten(Date(timeIntervalSince1970: 0))
    #expect(signal.generation == generation &+ 2)
    #expect(signal.historyGeneration == history &+ 1)
}

/// The launch seed reads the store off the main thread (#413) and lands as
/// one write naming no account, so every account's series reloads.
@MainActor
@Test func theLaunchSeedReadsTheNewestRowOffMain() async throws {
    let container = try PacerStore.makeInMemoryContainer()
    let ctx = ModelContext(container)
    let older = Date(timeIntervalSince1970: 1_700_000_000)
    let newer = older.addingTimeInterval(3600)
    ctx.insert(RateLimitSample(sampledAt: older, window: "five_hour", usedPercentage: 10,
                               resetsAt: nil, source: "oauth", accountId: "org-a"))
    ctx.insert(UsageLimitSample(sampledAt: newer, identity: "session||", kind: "session",
                                group: "session", label: "Session", percent: 12, resetsAt: nil,
                                severity: "normal", isActive: true, source: "oauth", accountId: "org-a"))
    try ctx.save()
    #expect(RateLimitWriteSignal.newestSampledAt(in: ModelContext(container)) == newer)

    let signal = RateLimitWriteSignal.shared
    let before = signal.generation
    await signal.seedInBackground(from: container).value
    #expect(signal.generation != before)
    // It names no account, so it counts for one nothing else has written.
    #expect(signal.generation(of: "org-seed-test-\(UUID().uuidString)") > before)
}

@Test func anEmptyStoreHasNoNewestRow() throws {
    let container = try PacerStore.makeInMemoryContainer()
    #expect(RateLimitWriteSignal.newestSampledAt(in: ModelContext(container)) == nil)
}
