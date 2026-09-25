import Foundation
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
