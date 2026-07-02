import Foundation

/// Small shared mutations on a collection's manual membership, so the
/// editor sheet and the "Add to collection…" context menu write the same
/// way. The caller owns the `ModelContext.save()` afterwards.
public enum CollectionsMutator {

    /// Add a project to a collection's hand-picked members (idempotent).
    /// Also clears any matching exclusion so re-adding undoes a removal.
    public static func addProject(_ path: String, to collection: ProjectCollection) {
        if !collection.includePaths.contains(path) {
            collection.includePaths = collection.includePaths + [path]
        }
        if collection.excludePaths.contains(path) {
            collection.excludePaths = collection.excludePaths.filter { $0 != path }
        }
    }

    /// Remove a project from a collection. Drops it from the manual
    /// includes; if it would still arrive via a rule or child, records an
    /// explicit exclusion so the removal sticks.
    public static func removeProject(
        _ path: String,
        from collection: ProjectCollection,
        stillMatchesViaRuleOrChild: Bool
    ) {
        collection.includePaths = collection.includePaths.filter { $0 != path }
        if stillMatchesViaRuleOrChild, !collection.excludePaths.contains(path) {
            collection.excludePaths = collection.excludePaths + [path]
        }
    }
}
