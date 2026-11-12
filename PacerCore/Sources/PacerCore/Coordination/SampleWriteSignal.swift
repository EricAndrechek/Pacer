import Foundation
import Observation

/// Bumped once for every scan cycle that wrote turns or their rollups: the
/// "read again" trigger for an always-mounted view that shows today's spend,
/// today's tokens or the newest turn's model (the menu-bar label).
///
/// The source is the scan notification (`pacerScanCycleDidComplete` with
/// `samplesChanged`), which every writer of `TokenSample` and the daily
/// rollups posts after its save. This turns it into a value a view reads in
/// its `body`, the way `RateLimitWriteSignal` does for rate-limit rows, so the
/// view depends on it and keys its reload on it (AGENTS.md, "Reload signals
/// change on every write").
///
/// A `@Query` follows the same data, but it re-fetches on every save of the
/// store, whatever changed, on the main thread. The menu-bar label's did, all
/// day, and on a Mac under memory pressure one of those one-row fetches held
/// the main thread for over two seconds (PACER-19).
///
/// Only a cycle that changed samples counts: a rate-limit poll, a cursor-only
/// save or a project re-attribution leaves the daily totals and the newest
/// turn where they were. A notification without a summary counts, so a
/// writer that forgets to say what it wrote can only cause a read, never hide
/// one.
@MainActor
@Observable
public final class SampleWriteSignal {

    public static let shared = SampleWriteSignal(center: .default)

    /// Bumped on every cycle that wrote samples. A counter, not a timestamp,
    /// for the reason `RateLimitWriteSignal.generation` gives: two cycles in
    /// the same second, or one that rebuilt older rows, must each move it.
    public private(set) var generation: UInt64 = 0

    /// Registered once and never removed: the block holds the signal weakly,
    /// so it outlives a released instance as a no-op.
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    /// `center` is the default one in the app; a test passes its own so it
    /// can post without reaching anything else listening.
    init(center: NotificationCenter) {
        observer = center.addObserver(
            forName: .pacerScanCycleDidComplete, object: nil, queue: .main
        ) { [weak self] note in
            guard (note.object as? ScanCycleSummary)?.samplesChanged ?? true else { return }
            MainActor.assumeIsolated { self?.note() }
        }
    }

    /// Record a write of samples.
    public func note() {
        generation &+= 1
    }
}
