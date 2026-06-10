import Foundation
import SwiftData

/// Housekeeping for the on-disk SwiftData store.
///
/// SwiftData turns Core Data **persistent-history tracking** on by
/// default for a SQLite store, so every write appends to a transaction
/// log (`ATRANSACTION` / `ACHANGE`). That log is meant to be pruned once
/// every reader has caught up — but Pacer never reads history tokens
/// (widgets refresh off the explicit `pacerScanCycleDidComplete`
/// notification, not history), so nothing ever prunes it and it grows
/// unbounded. At Pacer's data scale this isn't urgent — it's a backstop
/// against pathological multi-year accumulation, not active management,
/// so the defaults are intentionally gentle.
public enum StoreMaintenance {

    /// Keep this much history. 30 days is ~two orders of magnitude more
    /// than SwiftData's own cross-context `@Query` catch-up ever needs
    /// (hours at most), so pruning older than this can't disturb any
    /// live context — it only ever trims truly stale entries. Generous
    /// on purpose: the goal is bounding worst-case growth, not reclaiming
    /// space (the data is small).
    public static let historyRetention: TimeInterval = 30 * 24 * 60 * 60

    /// Delete persistent-history transactions older than `retention`.
    /// Best-effort: logs and returns on failure rather than throwing, so
    /// a housekeeping hiccup never affects the data path. Note this frees
    /// pages *inside* the SQLite file (reused by future writes) but does
    /// not shrink the file on disk — that would need a VACUUM, which we
    /// deliberately don't do here.
    @MainActor
    public static func pruneHistory(
        container: ModelContainer,
        olderThan retention: TimeInterval = historyRetention,
        now: Date = Date()
    ) {
        let cutoff = now.addingTimeInterval(-retention)
        let context = ModelContext(container)
        do {
            let descriptor = HistoryDescriptor<DefaultHistoryTransaction>(
                predicate: #Predicate { $0.timestamp < cutoff }
            )
            try context.deleteHistory(descriptor)
            Log.write("StoreMaintenance", "pruned persistent history older than \(Int(retention / 86_400))d")
        } catch {
            Log.write("StoreMaintenance", "history prune failed: \(error)")
        }
    }
}
