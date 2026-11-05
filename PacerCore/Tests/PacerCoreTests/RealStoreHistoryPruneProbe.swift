import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// What the launch-time persistent-history prune costs on a frozen COPY of a
/// real store (AGENTS.md rule 8).
///
///     sqlite3 "file:<store>?mode=ro" ".backup '/tmp/prune/pacer.sqlite'"
///     PACER_PRUNE_PROBE_STORE=/tmp/prune/pacer.sqlite \
///     PACER_PRUNE_PROBE_DAYS_AHEAD=16 \
///     swift test --filter RealStoreHistoryPruneProbe
///
/// `PACER_PRUNE_PROBE_DAYS_AHEAD` moves "now" forward, so the prune has the
/// history a launch that many days later would find past the 30-day horizon.
/// It deletes history from the copy; clone a fresh one per run.
@Suite("Real-store history prune probe",
       .enabled(if: ProcessInfo.processInfo.environment["PACER_PRUNE_PROBE_STORE"] != nil))
struct RealStoreHistoryPruneProbe {

    @MainActor
    @Test func pruneACopy() throws {
        let env = ProcessInfo.processInfo.environment
        let url = URL(fileURLWithPath: try #require(env["PACER_PRUNE_PROBE_STORE"]))
        try #require(!url.path.contains("Group Containers"), "point the probe at a copy")
        let ahead = Double(env["PACER_PRUNE_PROBE_DAYS_AHEAD"] ?? "0") ?? 0
        let container = try PacerStore.makeModelContainer(at: url)
        let now = Date().addingTimeInterval(ahead * 86_400)

        let began = Date()
        StoreMaintenance.pruneHistory(container: container, now: now)
        let seconds = Date().timeIntervalSince(began)
        // On the main actor, as the app's launch task runs it.
        print(String(format: "[prune] %.0f day(s) ahead: pruned in %.0f ms on the main actor",
                     ahead, seconds * 1000))
    }
}
