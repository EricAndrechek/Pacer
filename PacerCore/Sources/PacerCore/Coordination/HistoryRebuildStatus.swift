import Foundation
import Observation

/// Whether the scan is rebuilding history, and which step it is on (#328).
///
/// The first cycle after a `currentScanVersion` or `costRecomputeVersion` bump
/// re-reads every transcript and rebuilds every rollup: minutes on a large
/// history, during which the tabs show the old numbers, then some of the new
/// ones. Nothing said so. The toolbar's freshness pill reads `step` and says
/// "Updating history…", with the step in its tooltip.
///
/// Written only by `ScanCoordinator`, from the scan actor, through
/// `publish(_:source:generation:)`; read on the main actor. Kept per
/// coordinator: the app has one, but a test process runs many at once, and
/// one finishing must not clear another's.
@MainActor
@Observable
public final class HistoryRebuildStatus {
    public static let shared = HistoryRebuildStatus()

    public enum Step: Int, Sendable, Equatable {
        case preparing
        case readingTranscripts
        case updatingPrices
        case rebuildingDaily
        case rebuildingHourly
        case rebuildingProjects
        case rebuildingSessions

        /// The tooltip. Terse: what is happening, not why.
        public var detail: String {
            switch self {
            case .preparing: return "Updating history: preparing"
            case .readingTranscripts: return "Updating history: reading transcripts"
            case .updatingPrices: return "Updating history: updating prices"
            case .rebuildingDaily: return "Updating history: rebuilding daily totals"
            case .rebuildingHourly: return "Updating history: rebuilding hourly totals"
            case .rebuildingProjects: return "Updating history: rebuilding projects"
            case .rebuildingSessions: return "Updating history: rebuilding sessions"
            }
        }
    }

    /// Each rebuilding coordinator's latest step, with the generation it was
    /// published at.
    private var running: [UUID: (generation: UInt64, step: Step)] = [:]
    /// The newest generation applied per coordinator, so a publish that runs
    /// late — each is its own task — can't undo a newer one.
    @ObservationIgnored private var applied: [UUID: UInt64] = [:]

    private init() {}

    /// The step under way, or nil when no rebuild is running.
    public var step: Step? {
        running.values.max { $0.generation < $1.generation }?.step
    }

    /// One coordinator's step, or nil when it isn't rebuilding.
    public func step(for source: UUID) -> Step? { running[source]?.step }

    /// Hand a step (nil: done) to the main actor.
    public nonisolated static func publish(_ step: Step?, source: UUID, generation: UInt64) {
        Task { @MainActor in shared.apply(step, source: source, generation: generation) }
    }

    func apply(_ step: Step?, source: UUID, generation: UInt64) {
        guard generation > (applied[source] ?? 0) else { return }
        applied[source] = generation
        if let step {
            running[source] = (generation, step)
        } else if running[source] != nil {
            running[source] = nil
        }
    }
}
