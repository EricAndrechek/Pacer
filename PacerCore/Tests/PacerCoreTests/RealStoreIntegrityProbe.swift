import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// Measures the daily integrity check on a frozen COPY of a real store
/// (#388): the background read of every sample's buckets, then the
/// comparison with the rollup tables, against what the check used to cost —
/// a whole dedup preload. Read-only; the copy is never written.
///
///     sqlite3 "<store>" ".backup '/tmp/integrity/store.sqlite'"
///     PACER_INTEGRITY_PROBE_STORE=/tmp/integrity/store.sqlite PACER_ISOLATED_DEFAULTS=1 \
///     swift test --filter RealStoreIntegrityProbe
@Suite("Real-store integrity probe",
       .enabled(if: ProcessInfo.processInfo.environment["PACER_INTEGRITY_PROBE_STORE"] != nil))
struct RealStoreIntegrityProbe {

    func log(_ s: String) {
        print("\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) [integrity] \(s)")
    }

    @ScanActor
    @Test func checkTheRollups() throws {
        let env = ProcessInfo.processInfo.environment
        let storeURL = URL(fileURLWithPath: try #require(env["PACER_INTEGRITY_PROBE_STORE"]))
        if let live = try? PacerStore.storeURL() {
            let same = storeURL.resolvingSymlinksInPath().path == live.resolvingSymlinksInPath().path
            #expect(!same)
            guard !same else { return }
        }
        let container = try PacerStore.makeModelContainer(at: storeURL)

        let before = ProcessMemory.current()
        let sampler = ResourceSampler()
        sampler.start()
        var started = Date()
        let stored = try StoredBuckets.read(from: container)
        let readSeconds = Date().timeIntervalSince(started)
        let usage = sampler.stop()
        log(String(format: "read: %d samples → %d daily, %d project, %d hourly buckets, %d sessions · %.1f s · avg %.2f cores · peak footprint %.0f MB (%.0f before)",
                   stored.rows, stored.daily.count, stored.project.count, stored.hourly.count,
                   stored.sessions.count, readSeconds, usage.averageCores,
                   Double(usage.peakFootprint) / 1e6, Double(before.footprint) / 1e6))

        started = Date()
        let persister = try SamplePersister(context: ModelContext(container))
        try persister.checkIntegrity(against: stored)
        log(String(format: "compare: %.0f ms · missing daily %d, project %d, hourly %d, sessions %d · stranded hourly %d",
                   Date().timeIntervalSince(started) * 1000,
                   persister.consumeMissingAggregatePairs().count,
                   persister.consumeMissingProjectAggregatePairs().count,
                   persister.consumeMissingHourBuckets().count,
                   persister.consumeMissingSessionIds().count,
                   persister.consumeStrandedHourBuckets().count))

        // What it cost before: the check came with a whole dedup preload —
        // the same pass plus a SHA-256 and a map entry per keyed row.
        started = Date()
        let preload = try SamplePersister(context: ModelContext(container))
        try preload.ensurePreloaded()
        log(String(format: "dedup preload (the old way to check): %.1f s", Date().timeIntervalSince(started)))
    }
}
