import Foundation
import PacerCore
import SwiftData

/// Runs the data canary (#353) shortly after launch and then once per local
/// day: Claude Code's own session totals against Pacer's, so an upstream change
/// that stops writing what Pacer counts is noticed within a day, not a month.
///
/// Not per scan cycle: it judges sessions that finished at least a quarter of
/// an hour ago, so nothing is gained by running it more often, and tying it to
/// a cycle would put a config parse on the scan's cadence. Off the main actor,
/// on a context of its own (`DataCanary.run`).
///
/// The launch run waits long enough for the first scan cycle to land what
/// Claude Code wrote while Pacer was closed; a session it still has not read to
/// the end is skipped, not misjudged, and the next day's run picks it up.
@MainActor
final class DataCanaryScheduler {

    private let container: ModelContainer
    private var task: Task<Void, Never>?

    /// After launch: past the first scan cycle and the launch's own work.
    private static let launchDelay: Duration = .seconds(600)
    /// How often to look for a new local day. Short, so a Mac that slept
    /// through midnight runs within a quarter hour of waking.
    private static let checkInterval: Duration = .seconds(900)

    init(container: ModelContainer) {
        self.container = container
    }

    func start() {
        guard task == nil else { return }
        let container = self.container
        task = Task { @MainActor in
            do { try await Task.sleep(for: Self.launchDelay) } catch { return }
            var ranDay: String?
            while !Task.isCancelled {
                let today = TokenSample.formatDate(Date())
                // A rebuild rewrites the session rollup the canary reads; a
                // half-rebuilt one would be judged as a mismatch.
                if today != ranDay, HistoryRebuildStatus.shared.step == nil {
                    _ = await Task.detached(priority: .utility) {
                        DataCanary.runAndPublish(container: container, sources: .machine())
                    }.value
                    ranDay = today
                }
                do { try await Task.sleep(for: Self.checkInterval) } catch { return }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
