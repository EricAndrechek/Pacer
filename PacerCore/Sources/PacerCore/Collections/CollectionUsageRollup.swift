import Foundation

/// A usage rollup over some set of project paths. The shared currency
/// between a single project (a one-path set) and a collection (a many-path
/// set), so the leaderboard, the detail view, and a merge-preview all
/// speak the same totals type instead of each re-summing inline.
public struct ProjectUsageTotals: Sendable, Equatable {
    public var cost: Double = 0
    public var inputTokens: Int64 = 0
    public var outputTokens: Int64 = 0
    public var cacheReadTokens: Int64 = 0
    public var sessionCount: Int = 0
    public var lastActive: Date = .distantPast

    public var totalTokens: Int64 { inputTokens + outputTokens + cacheReadTokens }

    public static let zero = ProjectUsageTotals()
    public init() {}
}

/// Folds `ProjectDailyAggregate` rows into per-path and per-collection
/// totals. A collection total is just a second fold over the per-path map
/// — the per-project work the Projects tab already does, reused. No new
/// stored aggregate; nesting flattens to a leaf-path set and sums those.
///
/// **Overlap is intentional and unhidden.** Because a project can belong
/// to several collections, summing collection totals double-counts shared
/// projects — Σ(collection totals) ≠ the user's real total. Callers must
/// never present collection totals as a partition of the whole (no
/// 100%-stacked "collections" chart, no grand total row). Each collection
/// total is an independent lens.
public enum CollectionUsageRollup {

    /// Per-leaf-path totals, computed once. O(aggregates).
    public static func perPathTotals(
        from aggregates: [ProjectDailyAggregate]
    ) -> [String: ProjectUsageTotals] {
        var map: [String: ProjectUsageTotals] = [:]
        map.reserveCapacity(aggregates.count)
        for r in aggregates {
            var t = map[r.projectPath] ?? .zero
            t.cost += r.totalCostUSD
            t.inputTokens += r.inputTokens
            t.outputTokens += r.outputTokens
            t.cacheReadTokens += r.cacheReadTokens
            t.sessionCount += r.sessionCount
            if r.lastActive > t.lastActive { t.lastActive = r.lastActive }
            map[r.projectPath] = t
        }
        return map
    }

    /// Sum the per-path totals for a resolved member set. O(members).
    public static func totals(
        for paths: Set<String>,
        perPath: [String: ProjectUsageTotals]
    ) -> ProjectUsageTotals {
        var t = ProjectUsageTotals.zero
        for path in paths {
            guard let pt = perPath[path] else { continue }
            t.cost += pt.cost
            t.inputTokens += pt.inputTokens
            t.outputTokens += pt.outputTokens
            t.cacheReadTokens += pt.cacheReadTokens
            t.sessionCount += pt.sessionCount
            if pt.lastActive > t.lastActive { t.lastActive = pt.lastActive }
        }
        return t
    }

    /// Resolve + roll up every collection in one pass — the API the
    /// Collections lane calls. Builds the per-path map and the id→model
    /// map once, then resolves and sums each collection. Member paths are
    /// the de-duped leaves (nesting already flattened), so `memberCount`
    /// and `totals` agree.
    public static func resolveAll(
        collections: [ProjectCollection],
        aggregates: [ProjectDailyAggregate]
    ) -> [CollectionRollupResult] {
        let perPath = perPathTotals(from: aggregates)
        let knownPaths = Array(perPath.keys)
        let byID = Dictionary(collections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        return collections.map { collection in
            let members = CollectionResolver.resolve(
                collection.id, collections: byID, knownPaths: knownPaths
            )
            return CollectionRollupResult(
                id: collection.id,
                name: collection.name,
                colorSeed: collection.colorSeed,
                colorHex: collection.colorHex,
                memberPaths: members,
                totals: totals(for: members, perPath: perPath),
                childCollectionIDs: collection.childCollectionIDs,
                directProjectCount: collection.includePaths.count,
                hasRule: !collection.rules.isEmpty
            )
        }
    }
}

/// Value-type result of resolving + rolling up one collection. Plain
/// `Sendable` data (no `@Model`), so it can be cached in view `@State`
/// and passed across the render without touching SwiftData.
public struct CollectionRollupResult: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let colorSeed: String
    public let colorHex: String?
    /// De-duped leaf project paths (nesting flattened).
    public let memberPaths: Set<String>
    public let totals: ProjectUsageTotals
    public let childCollectionIDs: [String]
    /// Count of hand-added projects (`includePaths`) — the "added by you"
    /// provenance, distinct from rule/child-derived members.
    public let directProjectCount: Int
    public let hasRule: Bool

    public var memberCount: Int { memberPaths.count }
    public var isNested: Bool { !childCollectionIDs.isEmpty }

    public init(
        id: String,
        name: String,
        colorSeed: String,
        colorHex: String? = nil,
        memberPaths: Set<String>,
        totals: ProjectUsageTotals,
        childCollectionIDs: [String],
        directProjectCount: Int,
        hasRule: Bool
    ) {
        self.id = id
        self.name = name
        self.colorSeed = colorSeed
        self.colorHex = colorHex
        self.memberPaths = memberPaths
        self.totals = totals
        self.childCollectionIDs = childCollectionIDs
        self.directProjectCount = directProjectCount
        self.hasRule = hasRule
    }
}
