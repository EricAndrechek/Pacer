import Foundation
import SwiftData

/// A user-defined, **non-destructive** collection of projects — the
/// opposite of a `ProjectPathAlias` merge. Where a merge collapses many
/// project identities into one canonical path (rewriting samples), a
/// collection is an overlay *lens*: members keep their own identity, a
/// project may belong to many collections at once, and removing a
/// collection never touches usage data.
///
/// ## Membership is stored as REFERENCES, never flattened leaves
///
/// A collection's members are a heterogeneous set of:
///   - **directly-added projects** (`includePaths` — canonical leaf paths), and/or
///   - **sub-collections** (`childCollectionIDs` — ids of other collections), and/or
///   - **rule matches** (`rules` — directory prefixes that auto-capture
///     every current/future project underneath; optional, so a purely
///     hand-picked "scattered" collection needs no rule at all), minus
///   - **exclusions** (`excludePaths`), applied last at this level so a
///     parent can drop a project even when a child brings it in.
///
/// We deliberately store the *graph* (these reference lists) and resolve
/// it to a de-duped set of leaf paths at read time via
/// `CollectionResolver` — exactly like `ProjectPathAlias` stores edges
/// and lets `ProjectPathCanonicalizer` resolve them. Storing the
/// flattened leaves instead would freeze membership: removing a project
/// from a sub-collection would silently leave it in every ancestor, and
/// a child's live rule would stop propagating upward. References keep one
/// source of truth and nothing to invalidate.
///
/// Sub-collection references are **ids**, so they're immune to the
/// path-churn that an alias merge inflicts on the canonical paths stored
/// in `includePaths`/`excludePaths` (an id never rots). Dangling ids
/// (referencing a deleted collection) resolve to nothing — the resolver
/// skips unknown ids the same way the alias resolver returns last-good on
/// a missing key — so a delete is always safe.
///
/// ## No new aggregate table
///
/// A collection's usage is the sum of its resolved members'
/// `ProjectDailyAggregate` rows (see `CollectionUsageRollup`). Nesting
/// adds *resolution* complexity but zero *aggregation* complexity: the
/// graph flattens to a `Set<leafPath>` and the existing per-project fold
/// runs unchanged.
///
/// ## Schema
///
/// Brand-new `@Model`, so SwiftData's lightweight migration adds it
/// additively — no store reset, no migration plan, no version bump.
/// Reference lists are JSON-encoded `Data` columns (matching
/// `ProjectDailyAggregate.modelTokensJSON` et al.) for forward-compat:
/// adding a richer rule grammar later is a decode change, not a schema
/// change.
@Model
public final class ProjectCollection {
    @Attribute(.unique) public var id: String

    /// Display name ("Acme Corp", "Side Projects"). Free-form; not a key.
    public var name: String

    /// Seed for the stable identity hue. Defaults to the name at
    /// creation; kept separate so a rename doesn't recolor the
    /// collection. The UI hashes this with the same sum-of-scalars
    /// recipe used for per-model swatches (`Hasher` is per-process
    /// randomized, so we can't use it for a stable color).
    public var colorSeed: String

    public var createdAt: Date

    /// Stable display ordering in the manager/lane. Newest-first by
    /// default; user-reorderable later.
    public var sortOrder: Int

    /// JSON `[String]` — canonical project paths added by hand. The
    /// "pick these scattered projects" case. Carries the alias-merge
    /// path-churn caveat (a merge can rewrite a canonical path); the
    /// child/rule reference kinds do not.
    public var includePathsJSON: Data

    /// JSON `[String]` — ids of sub-collections. The nesting edge.
    public var childCollectionIDsJSON: Data

    /// JSON `[String]` — optional directory-prefix rules
    /// (`~/Code/work/acme`). Empty for a purely manual collection —
    /// having no rule is a normal, complete state, not a half-configured
    /// one. A rule auto-captures matching projects, including ones
    /// created after the rule.
    public var rulesJSON: Data

    /// JSON `[String]` — canonical project paths to remove. Applied last
    /// at this level (after includes ∪ rules ∪ children), so an exclude
    /// always wins over anything a child or rule contributes.
    public var excludePathsJSON: Data

    public init(
        id: String = UUID().uuidString,
        name: String,
        colorSeed: String? = nil,
        createdAt: Date = Date(),
        sortOrder: Int = 0,
        includePaths: [String] = [],
        childCollectionIDs: [String] = [],
        rules: [String] = [],
        excludePaths: [String] = []
    ) {
        self.id = id
        self.name = name
        self.colorSeed = colorSeed ?? name
        self.createdAt = createdAt
        self.sortOrder = sortOrder
        self.includePathsJSON = Self.encodeStrings(includePaths)
        self.childCollectionIDsJSON = Self.encodeStrings(childCollectionIDs)
        self.rulesJSON = Self.encodeStrings(rules)
        self.excludePathsJSON = Self.encodeStrings(excludePaths)
    }

    // MARK: Typed reference accessors (computed — not persisted twice)

    public var includePaths: [String] {
        get { Self.decodeStrings(includePathsJSON) }
        set { includePathsJSON = Self.encodeStrings(newValue) }
    }

    public var childCollectionIDs: [String] {
        get { Self.decodeStrings(childCollectionIDsJSON) }
        set { childCollectionIDsJSON = Self.encodeStrings(newValue) }
    }

    public var rules: [String] {
        get { Self.decodeStrings(rulesJSON) }
        set { rulesJSON = Self.encodeStrings(newValue) }
    }

    public var excludePaths: [String] {
        get { Self.decodeStrings(excludePathsJSON) }
        set { excludePathsJSON = Self.encodeStrings(newValue) }
    }

    /// A collection with no rule and no sub-collections — pure hand-picked
    /// membership. The "scattered, related in name only" case.
    public var isPureManual: Bool {
        rules.isEmpty && childCollectionIDs.isEmpty
    }

    // MARK: JSON codec (empty Data ⇒ empty array, never throws)

    static func decodeStrings(_ data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    static func encodeStrings(_ values: [String]) -> Data {
        (try? JSONEncoder().encode(values)) ?? Data()
    }
}
