import Foundation
import SwiftData

/// Shared `@Query` fetch descriptors that act as "scan-completed"
/// triggers for views.
///
/// **Problem this solves**: SwiftData's `@Query` re-fetches on every
/// `context.save()` that touches its model. A view bound to
/// `@Query var aggregates: [DailyAggregate]` re-fetches the entire
/// `DailyAggregate` table on every scan cycle even if nothing relevant
/// changed — and views with derived-data computed properties in `body`
/// then re-run their O(n) grouping/sorting passes on every refetch.
///
/// **The trick**: every `ScanCoordinator` cycle writes
/// `ClaudeCodeMetaKey.lastIncrementalScanAt` exactly once. Subscribing
/// to a `@Query` predicate-scoped to that single row gives a view a
/// "scan finished" notification at most once per cycle, with no
/// dependence on which tables actually changed and no whole-table
/// refetch cost.
///
/// **Usage**:
///
///     @Query(ScanMetaFetchDescriptor.scanCompletedProbe)
///     private var scanMeta: [ClaudeCodeMeta]
///     @State private var cached: [Row] = []
///
///     var body: some View {
///         Group { /* uses cached */ }
///             .onAppear { refreshCache() }
///             .onChange(of: scanMeta.first?.value) { _, _ in refreshCache() }
///     }
///
/// The `.first?.value` change-tracking key is a String (ISO-8601
/// timestamp); SwiftUI's diff against a String is cheap and fires
/// exactly when a new scan committed.
public enum ScanMetaFetchDescriptor {

    /// `@Query`-ready descriptor matching the one
    /// `lastIncrementalScanAt` row. The predicate is a constant string
    /// equality, so SwiftData treats this as a singleton fetch — no
    /// table scan, no model-level refetch storm.
    public static let scanCompletedProbe: FetchDescriptor<ClaudeCodeMeta> = {
        let key = ClaudeCodeMetaKey.lastIncrementalScanAt
        return FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key }
        )
    }()
}
