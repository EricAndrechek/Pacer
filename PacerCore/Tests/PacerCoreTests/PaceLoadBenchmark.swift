import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// What the pace chart's cold load actually costs, per account, on the real
/// store. Opt-in — it reads this machine's data, so it is meaningless on CI
/// and would be a lie as an assertion:
///
///     PACER_PACE_BENCH=1 swift test --package-path PacerCore --filter PaceLoadBenchmark
///
/// It exists because the per-account rate-limit work turned this load from
/// something that happened on appear into something that happens when you pick
/// an account from a menu, and the two have very different budgets. Read-only
/// (`allowsSave: false`), so it cannot disturb the running app.
@Suite("Pace chart cold-load cost", .enabled(if: ProcessInfo.processInfo.environment["PACER_PACE_BENCH"] != nil))
struct PaceLoadBenchmark {

    @MainActor
    @Test func costPerAccount() throws {
        let url = try PacerStore.storeURL()
        let container = try ModelContainer(
            for: Schema(PacerStore.allModelTypes),
            configurations: ModelConfiguration(url: url, allowsSave: false))
        let context = ModelContext(container)
        let cutoff = Date().addingTimeInterval(-8 * 86400)

        let accounts = (try context.fetch(FetchDescriptor<Account>())).map(\.id)
        let fiveHourCutoff = Date().addingTimeInterval(-12 * 3600)
        let five = RateLimitWindowName.fiveHour
        let seven = RateLimitWindowName.sevenDay

        for account in accounts {
            // Mirrors `PaceChartCard.load` exactly — both bounds included, so
            // the number is what a scope switch actually pays.
            let started = Date()
            var f: [LimitSamplePoint] = []
            for (window, since) in [(five, fiveHourCutoff), (seven, cutoff)] {
                var d = FetchDescriptor<RateLimitSample>(
                    predicate: #Predicate {
                        $0.accountId == account && $0.window == window && $0.sampledAt >= since
                    })
                d.propertiesToFetch = [\.window, \.sampledAt, \.resetsAt, \.usedPercentage]
                f += ((try? context.fetch(d)) ?? []).map(\.limitPoint)
            }
            var sd = FetchDescriptor<UsageLimitSample>(
                predicate: #Predicate {
                    $0.accountId == account && $0.sampledAt >= cutoff
                        && ($0.modelId != nil || $0.modelDisplayName != nil || $0.surface != nil)
                })
            sd.propertiesToFetch = [\.identity, \.sampledAt, \.resetsAt, \.percent]
            let sc = ((try? context.fetch(sd)) ?? []).map(\.scopedPoint)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            print("  \(account.suffix(4)): \(f.count) fixed + \(sc.count) scoped = \(ms)ms")
        }
    }
}
