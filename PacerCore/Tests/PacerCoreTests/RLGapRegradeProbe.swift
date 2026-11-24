import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// The first launch of the reading-gap build (#424) on a COPY of a real
/// store: the full-history record pass runs once per account (its fingerprint
/// moved), grades whatever the record is missing and takes out every row that
/// has no grade now. Opt-in, and it writes, so it refuses the live
/// store:
///
///     sqlite3 ~/Library/Group\ Containers/…/pacer.sqlite ".backup '/tmp/probe/pacer.sqlite'"
///     PACER_GAP_REGRADE_PROBE=/tmp/probe/pacer.sqlite swift test --package-path PacerCore --filter RLGapRegradeProbe
///
/// Per account: the rate-limit rows before and after, the pass's time at the
/// app's batch size and pause (and without the pause), and a second pass that
/// must do nothing.
@Suite("Reading-gap re-grade probe",
       .enabled(if: ProcessInfo.processInfo.environment["PACER_GAP_REGRADE_PROBE"] != nil))
struct RLGapRegradeProbe {

    @Test func theFirstLaunchRegradesOncePerAccount() async throws {
        let path = ProcessInfo.processInfo.environment["PACER_GAP_REGRADE_PROBE"]!
        let url = URL(fileURLWithPath: path)
        try #require(url.standardizedFileURL.path != (try PacerStore.storeURL()).standardizedFileURL.path,
                     "point PACER_GAP_REGRADE_PROBE at a copy, not the live store")
        let container = try ModelContainer(for: Schema(PacerStore.allModelTypes),
                                           configurations: ModelConfiguration(url: url))
        let accounts = await MainActor.run {
            ((try? ModelContext(container).fetch(FetchDescriptor<Account>())) ?? []).map(\.id).sorted()
        }
        func rlRows(_ account: String) async -> (rows: Int, engine: Int) {
            await MainActor.run {
                let suffix = EngineScope.account(account).suffix
                let rows = (try? ModelContext(container).fetch(FetchDescriptor<EngineEvalOutcome>(
                    predicate: #Predicate { $0.surface.contains(suffix) }))) ?? []
                let rl = rows.filter { $0.surface.hasPrefix("rl-") }
                let engine = Set(RateLimitRoster.engineIds)
                return (rl.count, rl.filter { engine.contains($0.method) }.count)
            }
        }
        var total = 0.0
        for account in accounts {
            let before = await rlRows(account)
            let engine = UsageIntelligenceEngine(modelContainer: container)
            await engine.adopt(scope: .account(account))
            let clock = ContinuousClock()
            // The first refit of a launch, then the steady cost.
            let r0 = clock.now
            await engine.recompute()
            let firstRefit = clock.now - r0
            let r1 = clock.now
            await engine.recompute()
            let secondRefit = clock.now - r1
            let t0 = clock.now
            let added = await engine.backfillRateLimitRecordIfNeeded()     // the app's batch and pause
            let pass = clock.now - t0
            await engine.settleRecordCleanup()
            let withCleanup = clock.now - t0
            let after = await rlRows(account)
            let again = UsageIntelligenceEngine(modelContainer: container)
            await again.adopt(scope: .account(account))
            await again.recompute()
            let second = await again.backfillRateLimitRecordIfNeeded(pause: .zero)
            total += Double(withCleanup.components.seconds) + Double(withCleanup.components.attoseconds) / 1e18
            print("=== …\(account.suffix(4)): rl rows \(before.rows) → \(after.rows) (engine \(before.engine) → "
                  + "\(after.engine)); refit \(firstRefit) then \(secondRefit); +\(added) graded by the pass in "
                  + "\(pass), with the delete \(withCleanup); second pass +\(second)")
            #expect(second == 0)
        }
        print("=== every account: \(String(format: "%.1f", total)) s")
    }
}
