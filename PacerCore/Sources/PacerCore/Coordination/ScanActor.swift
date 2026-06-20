import Foundation

/// Serial background executor for Pacer's scan pipeline.
///
/// Everything that touches the scan-loop `ModelContext` — the
/// `ScanCoordinator`, the `SamplePersister`, the per-pair recomputers,
/// the auto-aliaser, and the stats-cache probe — is isolated to this one
/// global actor so the entire scan cycle runs off the main thread on a
/// **single serial executor**. The serial part is mandatory: SwiftData's
/// `ModelContext` is thread-affine, so the context can only be created
/// and used from one consistent isolation domain.
///
/// Why a custom global actor instead of `@MainActor`: the scan loop used
/// to run on `@MainActor`, so any slow cycle (a big migration, a busy
/// insert cycle whose `await` resumed behind the previous save's
/// `@Query` refresh fan-out) stalled scrolling. Moving the loop here
/// frees the main thread entirely.
///
/// Why not per-object `@ModelActor`s: the per-pair recompute fast path
/// must read the persister's *uncommitted* inserts within the same
/// cycle, which only works if they share one context — i.e. one
/// executor. The `@ModelActor` bulk workers (separate context,
/// save-first) keep their own executors and are awaited from here; their
/// saves already prove SwiftData fans committed changes out to MainActor
/// `@Query` subscribers at the container level, independent of which
/// executor did the save.
@globalActor
public actor ScanActor {
    public static let shared = ScanActor()
}
