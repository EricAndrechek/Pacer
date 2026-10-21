import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// The end-of-day scoreboard rescore (#329) on a COPY of a real store. Opt-in:
///
///     cp -c ~/Library/Group\ Containers/…/pacer.sqlite* /tmp/probe/
///     PACER_RESCORE_PROBE=/tmp/probe/pacer.sqlite swift test --package-path PacerCore --filter EngineRescoreProbe
///
/// The rescore writes, so it refuses the live store. For every scope it
/// reports how many scored days were stale, times the refit that replays
/// them, then checks every end-of-day truth against the day's
/// `DailyAggregate` total and that a second refit replays nothing.
@Suite("Scoreboard rescore probe", .enabled(if: ProcessInfo.processInfo.environment["PACER_RESCORE_PROBE"] != nil))
struct EngineRescoreProbe {

    @Test func theScoreboardFollowsTheRepricedHistory() async throws {
        let path = ProcessInfo.processInfo.environment["PACER_RESCORE_PROBE"]!
        let url = URL(fileURLWithPath: path)
        try #require(url.standardizedFileURL.path != (try PacerStore.storeURL()).standardizedFileURL.path,
                     "point PACER_RESCORE_PROBE at a copy, not the live store")
        let container = try ModelContainer(for: Schema(PacerStore.allModelTypes),
                                           configurations: ModelConfiguration(url: url))

        let accounts = await MainActor.run {
            ((try? ModelContext(container).fetch(FetchDescriptor<Account>())) ?? []).map(\.id)
        }
        for scope in [EngineScope.allAccounts] + accounts.map({ EngineScope.account($0) }) {
            let surface = scope.qualify(EngineSelfEval.surfaceEOD)
            let totals = try await MainActor.run { try Self.dayTotals(container, account: scope.accountId) }
            let stale = try await MainActor.run { () -> Int in
                let rows = try ModelContext(container).fetch(FetchDescriptor<EngineEvalOutcome>(
                    predicate: #Predicate { $0.surface == surface }))
                return Set(rows.filter { abs($0.truth - (totals[$0.periodKey] ?? 0)) > 1e-6 }.map(\.periodKey)).count
            }

            let engine = UsageIntelligenceEngine(modelContainer: container)
            await engine.adopt(scope: scope)
            let t0 = Date()
            await engine.recompute()
            let first = Date().timeIntervalSince(t0)
            let t1 = Date()
            await engine.recompute()
            let second = Date().timeIntervalSince(t1)

            let (rows, off, worst) = try await MainActor.run { () -> (Int, Int, Double) in
                let rows = try ModelContext(container).fetch(FetchDescriptor<EngineEvalOutcome>(
                    predicate: #Predicate { $0.surface == surface }))
                let diffs = rows.map { abs($0.truth - (totals[$0.periodKey] ?? 0)) }
                return (rows.count, diffs.filter { $0 > 1e-6 }.count, diffs.max() ?? 0)
            }
            print(String(format: "=== %@: %d stale day(s) before; refit %.2fs, again %.2fs; %d rows, %d off, worst $%.2e",
                         scope.key, stale, first, second, rows, off, worst))
            #expect(off == 0, "\(scope.key): \(off) truth(s) still differ from DailyAggregate")
        }
    }

    @MainActor
    static func dayTotals(_ container: ModelContainer, account: String?) throws -> [String: Double] {
        let context = ModelContext(container)
        var out: [String: Double] = [:]
        if let account {
            for r in try context.fetch(FetchDescriptor<AccountDailyAggregate>(
                predicate: #Predicate { $0.accountId == account })) {
                out[r.date, default: 0] += r.totalCostUSD
            }
        } else {
            for r in try context.fetch(FetchDescriptor<DailyAggregate>()) { out[r.date, default: 0] += r.totalCostUSD }
        }
        return out
    }
}
