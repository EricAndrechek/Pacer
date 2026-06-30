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

    /// Reverse index: which collection ids each leaf path belongs to.
    /// Inverts `resolve` across every collection so project surfaces can
    /// show "this project is in collections X, Y" (the chip provenance).
    /// Built once per scan tick and threaded down — never per row.
    /// A path maps to collection ids in `collections` order; absent paths
    /// have no entry.
    public static func membership(
        of paths: [String],
        collections: [ProjectCollection],
        knownPaths: [String]
    ) -> [String: [String]] {
        let byID = Dictionary(collections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let wanted = Set(paths)
        var index: [String: [String]] = [:]
        for collection in collections {
            let members = resolve(collection.id, collections: byID, knownPaths: knownPaths)
            for path in members where wanted.contains(path) {
                index[path, default: []].append(collection.id)
            }
        }
        return index
    }
}

/// Interprets a collection rule string. A rule is either a **directory
/// prefix** (a plain folder path — the common case, set via a folder
/// picker) or a **glob pattern** when it contains `*`/`?`. Stored as a
/// plain string so the kind is inferred, not a schema concern.
public enum CollectionRuleMatcher {

    /// True when `path` satisfies `rule`. Folder rules match the directory
    /// itself or anything beneath it (boundary-aware, so `/a/foo` does NOT
    /// match `/a/foobar`). Glob rules (`*`, `**`, `?`) match by pattern.
    /// Both tilde-expanded.
    public static func matches(path: String, rule: String) -> Bool {
        let p = normalize(path)
        let r = normalize(rule)
        guard !r.isEmpty else { return false }
        if isGlob(r) {
            return globMatches(path: p, pattern: r)
        }
        if p == r { return true }
        return p.hasPrefix(r + "/")
    }

    /// A rule is a glob (not a plain folder prefix) when it carries a glob
    /// metacharacter.
    public static func isGlob(_ rule: String) -> Bool {
        rule.contains("*") || rule.contains("?")
    }

    static func normalize(_ value: String) -> String {
        var t = (value as NSString).expandingTildeInPath
        while t.count > 1, t.hasSuffix("/") { t.removeLast() }
        return t
    }

    private static func globMatches(path: String, pattern: String) -> Bool {
        let regex = "^" + globToRegex(pattern) + "$"
        guard let re = try? NSRegularExpression(pattern: regex) else { return false }
        return re.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }

    /// Translate a shell-style glob into an anchored regex body.
    /// `**/` → any depth of directories (incl. none); `**` → anything;
    /// `*` → anything except `/`; `?` → one char except `/`. All other
    /// regex metacharacters are escaped to literals.
    static func globToRegex(_ glob: String) -> String {
        var out = ""
        let chars = Array(glob)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "*" {
                let isDouble = (i + 1 < chars.count && chars[i + 1] == "*")
                if isDouble {
                    if i + 2 < chars.count && chars[i + 2] == "/" {
                        out += "(?:.*/)?"   // **/ — zero or more directories
                        i += 3
                        continue
                    }
                    out += ".*"             // ** — across separators
                    i += 2
                    continue
                }
                out += "[^/]*"              // * — within one segment
            } else if c == "?" {
                out += "[^/]"
            } else if ".()+|^$={}[]\\".contains(c) {
                out += "\\" + String(c)
            } else {
                out += String(c)
            }
            i += 1
        }
        return out
    }
}
