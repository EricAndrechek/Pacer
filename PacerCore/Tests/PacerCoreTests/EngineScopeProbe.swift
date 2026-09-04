import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// What each scope's engine actually fits, on the real store. Opt-in:
///
///     PACER_ENGINE_PROBE=1 swift test --package-path PacerCore --filter EngineScopeProbe
///
/// Read-only (`allowsSave: false`), so it cannot disturb the running app.
@Suite("Per-scope engine probe", .enabled(if: ProcessInfo.processInfo.environment["PACER_ENGINE_PROBE"] != nil))
struct EngineScopeProbe {

    @Test func whatEachScopeFits() async throws {
        let url = try PacerStore.storeURL()
        let container = try ModelContainer(
            for: Schema(PacerStore.allModelTypes),
            configurations: ModelConfiguration(url: url, allowsSave: false))

        let accounts = await MainActor.run {
            ((try? ModelContext(container).fetch(FetchDescriptor<Account>())) ?? []).map(\.id)
        }
        var scopes: [EngineScope] = [.allAccounts]
        scopes += accounts.map { EngineScope.account($0) }

        for scope in scopes {
            let engine = UsageIntelligenceEngine(modelContainer: container)
            await engine.adopt(scope: scope)
            await engine.recompute()
            let days = await engine.trainingDayCount()
            print("\n=== scope \(scope.key.suffix(4)) — \(days) training day(s)")
            for spec in await engine.windowSpecsForProbe() {
                let outlook = await engine.burnOutlook(windowKey: spec.key)
                let traj = await engine.rateLimitTrajectories(windowKey: spec.key)
                let history = await engine.rateLimitHistoryCountForProbe(spec.key)
                let cycles = await engine.rateLimitCyclesForProbe(spec.key)
                let name: String = String(spec.key.prefix(26))
                let selected: String = traj.first(where: { $0.isSelected })?.id ?? "-"
                let end: String = outlook.map { String(format: "used=%.0f slope=%.2f", $0.usedPct, $0.slopePercentPerHour) } ?? "nil"
                let models: Int = traj.count
                var line = "  " + name
                line += " samples=" + String(history)
                line += " cycles=" + String(cycles)
                line += " models=" + String(models)
                line += " selected=" + selected
                line += " " + end
                print(line)
                if let selectedTraj = traj.first(where: { $0.isSelected }) ?? traj.first {
                    let pts = selectedTraj.trajectory.points
                    let vals = stride(from: 0, to: pts.count, by: max(1, pts.count / 4))
                        .map { String(format: "%.0f", pts[$0].usedPercentage) }
                    print("      curve: " + vals.joined(separator: " → ")
                          + " (" + String(pts.count) + " pts)")
                }
            }
        }
    }
}
