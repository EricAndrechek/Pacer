import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// The launch path's store open (#376) on a frozen COPY of a real store
/// (AGENTS.md rule 8): what the metadata check says and costs on the main
/// thread, how long `prepareStore` takes off it, and how long the open after
/// it takes.
///
///     sqlite3 "<store>" ".backup '/tmp/prepare/pristine.sqlite'"
///     cp -c /tmp/prepare/pristine.sqlite /tmp/prepare/pacer.sqlite
///     PACER_PREPARE_PROBE_STORE=/tmp/prepare/pacer.sqlite \
///     swift test --filter RealStorePrepareProbe
///
/// `PACER_PREPARE_PROBE_DOWNGRADE=1` first opens the copy without this
/// build's two newest model types, so the prepare has a real migration to do
/// on real data: the shape of a release that adds a `@Model`. It writes the
/// copy; clone a fresh one per run.
@Suite("Real-store prepare probe",
       .enabled(if: ProcessInfo.processInfo.environment["PACER_PREPARE_PROBE_STORE"] != nil))
struct RealStorePrepareProbe {

    private static func ms(_ seconds: Double) -> String { String(format: "%.1f ms", seconds * 1000) }

    private static func timed<T>(_ work: () throws -> T) rethrows -> (T, Double) {
        let began = Date()
        let value = try work()
        return (value, Date().timeIntervalSince(began))
    }

    @Test func probe() async throws {
        let env = ProcessInfo.processInfo.environment
        let url = URL(fileURLWithPath: try #require(env["PACER_PREPARE_PROBE_STORE"]))
        // A copy, never the live store: the downgrade writes it, and even the
        // prepare would migrate the owner's data under the running app.
        try #require(!url.path.contains("Group Containers"), "point the probe at a copy")

        if env["PACER_PREPARE_PROBE_DOWNGRADE"] == "1" {
            let older = Array(PacerStore.allModelTypes.dropLast(2))
            let (_, s) = try Self.timed { _ = try PacerStore.makeModelContainer(at: url, types: older) }
            print("[probe] downgraded the copy to \(older.count) model types in \(Self.ms(s))")
        }

        // What the app's `init` runs on the main thread at every launch.
        for pass in 1...3 {
            let (state, s) = Self.timed { PacerStore.schemaState(at: url) }
            print("[probe] schemaState pass \(pass): \(state.rawValue) in \(Self.ms(s))")
        }

        let prepared = try await Task.detached { try PacerStore.prepareStore(at: url) }.value
        print("[probe] prepareStore: \(Self.ms(prepared.seconds)) "
              + "\(prepared.onMainThread ? "ON main" : "off main"), migrated: \(prepared.migrated), "
              + "\(prepared.before.rawValue) → \(prepared.after.rawValue)")
        let samples = try ModelContext(prepared.container).fetchCount(FetchDescriptor<TokenSample>())
        print("[probe] TokenSample rows: \(samples)")
        #expect(prepared.after == .current)

        let (_, reopen) = try Self.timed { _ = try PacerStore.makeModelContainer(at: url) }
        print("[probe] open after prepare: \(Self.ms(reopen))")
    }
}
