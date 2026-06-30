import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// Behaviour tests for the project-collections spine: the cycle-safe
/// resolver, the rollup fold, rule matching, and the overlap/exclude
/// semantics. Most operate on pure functions over un-persisted model
/// instances — no container needed.

private func agg(_ path: String, date: String = "2026-06-01", cost: Double, tokens: Int64 = 0, sessions: Int = 0) -> ProjectDailyAggregate {
    ProjectDailyAggregate(
        projectPath: path,
        date: date,
        inputTokens: tokens,
        totalCostUSD: cost,
        sessionCount: sessions,
        lastActive: Date(timeIntervalSince1970: 1_750_000_000)
    )
}

// MARK: Rule matcher

@Test func ruleMatchesDirectoryAndDescendants() {
    #expect(CollectionRuleMatcher.matches(path: "/a/Acme", rule: "/a/Acme"))
    #expect(CollectionRuleMatcher.matches(path: "/a/Acme/api", rule: "/a/Acme"))
    #expect(CollectionRuleMatcher.matches(path: "/a/Acme/api/sub", rule: "/a/Acme/"))
}

@Test func ruleIsBoundaryAware() {
    // /a/foo must NOT match a sibling whose name merely shares the prefix.
    #expect(!CollectionRuleMatcher.matches(path: "/a/foobar", rule: "/a/foo"))
    #expect(!CollectionRuleMatcher.matches(path: "/other", rule: "/a/foo"))
    #expect(!CollectionRuleMatcher.matches(path: "/a/foo", rule: ""))
}

@Test func ruleExpandsTilde() {
    let home = NSHomeDirectory()
    #expect(CollectionRuleMatcher.matches(path: "\(home)/Code/x", rule: "~/Code"))
}

// MARK: Manual membership + overlap

@Test func manualCollectionSumsItsMembers() {
    let c = ProjectCollection(name: "Side", includePaths: ["/p/a", "/p/b"])
    let members = CollectionResolver.resolve(c.id, collections: [c.id: c], knownPaths: ["/p/a", "/p/b", "/p/c"])
    #expect(members == ["/p/a", "/p/b"])

    let perPath = CollectionUsageRollup.perPathTotals(from: [agg("/p/a", cost: 10), agg("/p/b", cost: 5), agg("/p/c", cost: 99)])
    let totals = CollectionUsageRollup.totals(for: members, perPath: perPath)
    #expect(totals.cost == 15)
}

@Test func projectCanBelongToMultipleCollectionsAndCountsInEach() {
    // Overlap is intentional: a shared project counts in both collections.
    let shared = "/p/shared"
    let a = ProjectCollection(name: "A", includePaths: [shared, "/p/a"])
    let b = ProjectCollection(name: "B", includePaths: [shared, "/p/b"])
    let perPath = CollectionUsageRollup.perPathTotals(from: [agg(shared, cost: 100), agg("/p/a", cost: 1), agg("/p/b", cost: 2)])
    let map = [a.id: a, b.id: b]
    let ta = CollectionUsageRollup.totals(for: CollectionResolver.resolve(a.id, collections: map, knownPaths: []), perPath: perPath)
    let tb = CollectionUsageRollup.totals(for: CollectionResolver.resolve(b.id, collections: map, knownPaths: []), perPath: perPath)
    #expect(ta.cost == 101)
    #expect(tb.cost == 102)
    // The shared $100 is in BOTH — sum exceeds the real total ($103).
    #expect(ta.cost + tb.cost > 103)
}

// MARK: Rules

@Test func ruleCapturesKnownProjectsUnderPrefix() {
    let c = ProjectCollection(name: "Acme", rules: ["/Code/work/Acme"])
    let known = ["/Code/work/Acme/api", "/Code/work/Acme/web", "/Code/personal/blog"]
    let members = CollectionResolver.resolve(c.id, collections: [c.id: c], knownPaths: known)
    #expect(members == ["/Code/work/Acme/api", "/Code/work/Acme/web"])
}

@Test func includePathsCountEvenWhenNotInKnownPaths() {
    // A hand-added project with no recent usage is still a member.
    let c = ProjectCollection(name: "X", includePaths: ["/p/dormant"])
    let members = CollectionResolver.resolve(c.id, collections: [c.id: c], knownPaths: [])
    #expect(members == ["/p/dormant"])
}

// MARK: Nesting

@Test func nestedCollectionFlattensToChildLeaves() {
    let child = ProjectCollection(name: "Side", includePaths: ["/p/wh1", "/p/wh2"])
    let parent = ProjectCollection(name: "Acme", includePaths: ["/p/rf1"], childCollectionIDs: [child.id])
    let map = [child.id: child, parent.id: parent]
    let members = CollectionResolver.resolve(parent.id, collections: map, knownPaths: [])
    #expect(members == ["/p/rf1", "/p/wh1", "/p/wh2"])
}

@Test func nestedOverlapIsDedupedInParentTotal() {
    // A project reachable via the parent directly AND via a child is
    // counted once (Set semantics).
    let child = ProjectCollection(name: "child", includePaths: ["/p/dup", "/p/c"])
    let parent = ProjectCollection(name: "parent", includePaths: ["/p/dup"], childCollectionIDs: [child.id])
    let map = [child.id: child, parent.id: parent]
    let members = CollectionResolver.resolve(parent.id, collections: map, knownPaths: [])
    #expect(members == ["/p/dup", "/p/c"])
    let perPath = CollectionUsageRollup.perPathTotals(from: [agg("/p/dup", cost: 50), agg("/p/c", cost: 5)])
    #expect(CollectionUsageRollup.totals(for: members, perPath: perPath).cost == 55)
}

@Test func childRemovalPropagatesToParent() {
    // The whole reason we store references not leaves: edit the child,
    // the parent reflects it on next resolve.
    let child = ProjectCollection(name: "child", includePaths: ["/p/x", "/p/y"])
    let parent = ProjectCollection(name: "parent", childCollectionIDs: [child.id])
    var map = [child.id: child, parent.id: parent]
    #expect(CollectionResolver.resolve(parent.id, collections: map, knownPaths: []) == ["/p/x", "/p/y"])

    child.includePaths = ["/p/x"] // remove /p/y from the child
    map[child.id] = child
    #expect(CollectionResolver.resolve(parent.id, collections: map, knownPaths: []) == ["/p/x"])
}

// MARK: Exclude precedence

@Test func parentExcludeWinsOverChildInclude() {
    let child = ProjectCollection(name: "child", includePaths: ["/p/a", "/p/b"])
    let parent = ProjectCollection(name: "parent", childCollectionIDs: [child.id], excludePaths: ["/p/b"])
    let map = [child.id: child, parent.id: parent]
    #expect(CollectionResolver.resolve(parent.id, collections: map, knownPaths: []) == ["/p/a"])
}

// MARK: Robustness — cycles & dangling refs (never crash / hang)

@Test func cycleResolvesWithoutHanging() {
    let a = ProjectCollection(name: "A", includePaths: ["/p/a"])
    let b = ProjectCollection(name: "B", includePaths: ["/p/b"])
    a.childCollectionIDs = [b.id]
    b.childCollectionIDs = [a.id] // A ⊃ B ⊃ A
    let map = [a.id: a, b.id: b]
    let members = CollectionResolver.resolve(a.id, collections: map, knownPaths: [])
    #expect(members == ["/p/a", "/p/b"]) // union, no infinite loop
}

@Test func danglingChildReferenceIsSkipped() {
    let parent = ProjectCollection(name: "parent", includePaths: ["/p/a"], childCollectionIDs: ["does-not-exist"])
    let members = CollectionResolver.resolve(parent.id, collections: [parent.id: parent], knownPaths: [])
    #expect(members == ["/p/a"])
}

// MARK: resolveAll end-to-end

@Test func resolveAllProducesRollupResults() {
    let child = ProjectCollection(name: "Side", includePaths: ["/p/wh"])
    let parent = ProjectCollection(name: "Acme", childCollectionIDs: [child.id], rules: ["/work/rf"])
    let aggregates = [agg("/p/wh", cost: 3, sessions: 1), agg("/work/rf/api", cost: 7, sessions: 2)]
    let results = CollectionUsageRollup.resolveAll(collections: [parent, child], aggregates: aggregates)

    let parentResult = results.first { $0.id == parent.id }!
    #expect(parentResult.memberPaths == ["/p/wh", "/work/rf/api"])
    #expect(parentResult.totals.cost == 10)
    #expect(parentResult.hasRule)
    #expect(parentResult.isNested)

    let childResult = results.first { $0.id == child.id }!
    #expect(childResult.totals.cost == 3)
    #expect(childResult.isPureManualEquivalent)
}

private extension CollectionRollupResult {
    /// Mirror of `ProjectCollection.isPureManual` for the value-type result.
    var isPureManualEquivalent: Bool { !hasRule && childCollectionIDs.isEmpty }
}

// MARK: Schema round-trip

@MainActor
@Test func projectCollectionRoundTrips() throws {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: ProjectCollection.self, configurations: config)
    let context = ModelContext(container)
    let c = ProjectCollection(name: "Acme", includePaths: ["/p/a"], childCollectionIDs: ["child-id"], rules: ["/work/rf"], excludePaths: ["/p/x"])
    context.insert(c)
    try context.save()

    let fetched = try context.fetch(FetchDescriptor<ProjectCollection>())
    #expect(fetched.count == 1)
    #expect(fetched[0].name == "Acme")
    #expect(fetched[0].includePaths == ["/p/a"])
    #expect(fetched[0].childCollectionIDs == ["child-id"])
    #expect(fetched[0].rules == ["/work/rf"])
    #expect(fetched[0].excludePaths == ["/p/x"])
}
