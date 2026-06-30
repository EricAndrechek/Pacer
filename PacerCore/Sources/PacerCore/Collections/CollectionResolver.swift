import Foundation

/// Resolves a `ProjectCollection`'s reference graph (direct projects,
/// sub-collections, rules, exclusions) into the de-duped set of leaf
/// project paths it currently contains.
///
/// This is the collection-side analogue of
/// `ProjectPathCanonicalizer.resolveAlias`: a transitive walk with both
/// **cycle detection** (a node currently on the recursion stack is
/// skipped) and a **hard depth cap** (a pathological graph terminates
/// with the best partial result and a log line — never a crash, never a
/// hang). We reuse that proven shape rather than inventing new
/// cycle-safety for nesting.
///
/// Resolution is read-time and cheap (set operations over ~tens of
/// projects and a handful of collections), so the view memoizes it once
/// per scan rather than materializing leaves into storage.
public enum CollectionResolver {

    /// Max nesting depth. Mirrors `ProjectPathCanonicalizer.maxAliasChainDepth`.
    /// A legitimate hierarchy is 2–3 deep; 32 is far past anything a user
    /// builds by hand and well under the depth at which recursion would
    /// degrade a scan tick.
    public static let maxNestingDepth = 32

    /// Resolve one collection to its current leaf project paths.
    ///
    /// - Parameters:
    ///   - collectionID: the collection to resolve.
    ///   - collections: id → collection map (every known collection, so
    ///     child references can be followed). A missing id resolves to
    ///     nothing (dangling reference = safe no-op).
    ///   - knownPaths: every current leaf project path (typically the
    ///     distinct `projectPath`s in `ProjectDailyAggregate`). Needed to
    ///     expand directory-prefix rules into concrete members. Direct
    ///     `includePaths` are returned whether or not they appear here, so
    ///     a hand-added project with no recent usage still counts as a
    ///     member.
    public static func resolve(
        _ collectionID: String,
        collections: [String: ProjectCollection],
        knownPaths: [String]
    ) -> Set<String> {
        // Recursion stack for cycle detection. A collection already being
        // resolved higher in the stack contributes nothing on revisit —
        // its members are gathered by the in-progress call.
        var onStack: Set<String> = []

        func walk(_ id: String, _ depth: Int) -> Set<String> {
            guard depth < maxNestingDepth else {
                Log.write("CollectionResolver",
                          "nesting exceeded depth \(maxNestingDepth) resolving \(collectionID)")
                return []
            }
            guard let collection = collections[id] else { return [] } // dangling ref
            if onStack.contains(id) { return [] }                     // cycle
            onStack.insert(id)
            defer { onStack.remove(id) }

            var paths = Set(collection.includePaths)

            let rules = collection.rules
            if !rules.isEmpty {
                for path in knownPaths
                where rules.contains(where: { CollectionRuleMatcher.matches(path: path, rule: $0) }) {
                    paths.insert(path)
                }
            }

            for childID in collection.childCollectionIDs {
                paths.formUnion(walk(childID, depth + 1))
            }

            // Excludes applied LAST at this level: a parent's exclude wins
            // over anything its rules or children contributed.
            paths.subtract(collection.excludePaths)
            return paths
        }

        return walk(collectionID, 0)
    }
}

/// Interprets a collection rule string. For v1 a rule is a **directory
/// prefix**: a project belongs to the rule when it is that directory or
/// lives underneath it. Stored as a string (not a structured type) so a
/// richer grammar (globs, name patterns) can be added later as a decode
/// change rather than a schema migration.
public enum CollectionRuleMatcher {

    /// `path` matches `rule` when, after tilde-expansion and
    /// trailing-slash trimming, `path == rule` or `path` is under `rule`.
    /// Boundary-aware via the explicit "/" so rule `/a/foo` does NOT
    /// match `/a/foobar`.
    public static func matches(path: String, rule: String) -> Bool {
        let p = normalize(path)
        let r = normalize(rule)
        guard !r.isEmpty else { return false }
        if p == r { return true }
        return p.hasPrefix(r + "/")
    }

    static func normalize(_ value: String) -> String {
        var t = (value as NSString).expandingTildeInPath
        while t.count > 1, t.hasSuffix("/") { t.removeLast() }
        return t
    }
}
