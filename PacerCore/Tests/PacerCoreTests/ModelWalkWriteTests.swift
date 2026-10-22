import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// The walks that WRITE stopped using `enumerate` too (#338). These pin that
/// each one still writes, deletes and marks exactly what it did, on a store
/// several pages long — including a mutation that takes rows out of the
/// walk's own predicate, deletes, and rows the persister's context holds
/// while other contexts write underneath it.
@Suite struct ModelWalkWriteTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema(PacerStore.allModelTypes),
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func entry(_ i: Int, output: Int64 = 1, complete: Bool = false,
                       projectPath: String? = nil, originalProjectPath: String? = nil) -> ParsedUsageEntry {
        ParsedUsageEntry(
            timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(i) * 1_337),
            model: ["claude-opus-5", "claude-sonnet-5-5", "claude-haiku-5-5"][i % 3],
            breakdown: TokenBreakdown(inputTokens: Int64(i), outputTokens: output,
                                      cacheReadTokens: Int64(i * 3),
                                      cacheCreation5mTokens: Int64(i % 5),
                                      cacheCreation1hTokens: Int64(i % 7)),
            storedCostUSD: i.isMultiple(of: 4) ? Double(i) / 1000 : nil,
            dedupKey: "m\(i):r\(i)",
            sessionId: i.isMultiple(of: 11) ? nil : "s\(i % 23)",
            projectPath: projectPath ?? "/Users/dev/code/p\(i % 3)",
            originalProjectPath: originalProjectPath,
            isComplete: complete)
    }

    private func key(_ i: Int) -> String { "m\(i):r\(i)" }

    /// Every stored column, so a walk can be shown to change only the ones
    /// it means to.
    private func describe(_ s: TokenSample) -> String {
        let cost: String = s.sourceCostUSD.map { "\($0)" } ?? "-"
        var parts: [String] = [s.dedupKey ?? "-", String(s.sampledAt.timeIntervalSince1970), s.date, s.model]
        parts += [String(s.localHour), String(s.inputTokens), String(s.outputTokens), String(s.cacheReadTokens)]
        parts += [String(s.cacheCreation5mTokens), String(s.cacheCreation1hTokens), cost]
        parts += [s.sessionId ?? "-", s.projectPath ?? "-", s.originalProjectPath ?? "-"]
        parts += [s.ccVersion ?? "-", s.accountId ?? "-", s.speed ?? "-", s.inferenceGeo ?? "-"]
        return parts.joined(separator: "|")
    }

    private func rows(_ c: ModelContainer) throws -> [TokenSample] {
        try ModelContext(c).fetch(FetchDescriptor<TokenSample>())
    }

    private func hour(_ d: Date) -> Int { Calendar.current.component(.hour, from: d) }

    // MARK: - ModelWalk.update

    @ScanActor
    @Test func offsetPagingWritesEveryRowOnce() throws {
        for pageSize in [7, 5, 1, 23, 40] {
            let c = try container()
            let owner = ModelContext(c)
            for i in 0..<23 { owner.insert(TokenSample(from: entry(i))) }
            try owner.save()
            var handed: [String] = []
            let visited = try ModelWalk.update(FetchDescriptor<TokenSample>(), in: c, owner: owner,
                                               paging: .offset, pageSize: pageSize) { s in
                handed.append(s.dedupKey ?? "-")
                s.outputTokens += 1_000
            }
            #expect(visited == 23)
            #expect(handed.count == 23 && Set(handed).count == 23)
            #expect(try rows(c).allSatisfy { $0.outputTokens == 1_001 }, "page size \(pageSize)")
            #expect(!owner.hasChanges)
        }
    }

    /// Stamping the rows a predicate picks as unstamped takes each out of the
    /// predicate, so offset paging skips a page's worth after every page.
    /// Draining stamps them all.
    @ScanActor
    @Test func drainPagingReachesEveryRowItsBodyTakesOutOfThePredicate() throws {
        func unstampedStore() throws -> (ModelContainer, ModelContext) {
            let c = try container()
            let owner = ModelContext(c)
            for i in 0..<40 {
                let s = TokenSample(from: entry(i))
                s.localHour = -1
                owner.insert(s)
            }
            try owner.save()
            return (c, owner)
        }
        let unstamped = FetchDescriptor<TokenSample>(predicate: #Predicate { $0.localHour < 0 })

        let (offsetStore, offsetOwner) = try unstampedStore()
        try ModelWalk.update(unstamped, in: offsetStore, owner: offsetOwner,
                             paging: .offset, pageSize: 7) { $0.localHour = 0 }
        #expect(try rows(offsetStore).contains { $0.localHour < 0 }, "offset paging skipped none")

        for pageSize in [7, 1, 40, 41] {
            let (c, owner) = try unstampedStore()
            let visited = try ModelWalk.update(unstamped, in: c, owner: owner,
                                               paging: .drain, pageSize: pageSize) { s in
                s.localHour = Calendar.current.component(.hour, from: s.sampledAt)
            }
            #expect(visited == 40, "page size \(pageSize)")
            #expect(try rows(c).allSatisfy { $0.localHour == hour($0.sampledAt) })
        }
    }

    @ScanActor
    @Test func drainThrowsRatherThanLoopWhenTheBodyLeavesARowIn() throws {
        let c = try container()
        let owner = ModelContext(c)
        for i in 0..<10 {
            let s = TokenSample(from: entry(i))
            s.localHour = -1
            owner.insert(s)
        }
        try owner.save()
        let unstamped = FetchDescriptor<TokenSample>(predicate: #Predicate { $0.localHour < 0 })
        // Leaves the first row it is handed in; that row tops the next page.
        var leftIn: PersistentIdentifier?
        #expect(throws: ModelWalk.WalkError.drainMadeNoProgress) {
            try ModelWalk.update(unstamped, in: c, owner: owner, paging: .drain, pageSize: 4) { s in
                if leftIn == nil { leftIn = s.persistentModelID }
                if s.persistentModelID != leftIn { s.localHour = 1 }
            }
        }
    }

    @ScanActor
    @Test func refusesAnOwnerWithUnsavedChanges() throws {
        let c = try container()
        let owner = ModelContext(c)
        owner.insert(TokenSample(from: entry(1)))
        #expect(throws: ModelWalk.WalkError.ownerHasPendingChanges) {
            try ModelWalk.update(FetchDescriptor<TokenSample>(), in: c, owner: owner,
                                 paging: .offset) { _ in }
        }
    }

    /// A row the owner holds is written through the owner's instance. Saved
    /// through the page's context instead, the owner's instance would keep the
    /// old values, and the owner's next save of any change to it would write
    /// them back over the walk's.
    @ScanActor
    @Test func aRowTheOwnerHoldsIsWrittenThroughTheOwner() throws {
        let c = try container()
        let owner = ModelContext(c)
        for i in 0..<20 { owner.insert(TokenSample(from: entry(i))) }
        try owner.save()
        let target = key(9)
        let held = try #require(try owner.fetch(FetchDescriptor<TokenSample>(
            predicate: #Predicate { $0.dedupKey == target })).first)
        try ModelWalk.update(FetchDescriptor<TokenSample>(), in: c, owner: owner,
                             paging: .offset, pageSize: 6) { $0.projectPath = "/moved" }
        #expect(held.projectPath == "/moved")
        #expect(!owner.hasChanges, "the walk saves what it wrote through the owner")

        held.outputTokens = 4_242
        try owner.save()
        let stored = try rows(c).first { $0.dedupKey == target }
        #expect(stored?.projectPath == "/moved")
        #expect(stored?.outputTokens == 4_242)
        #expect(try rows(c).allSatisfy { $0.projectPath == "/moved" })
    }

    // MARK: - The persister's walks, across pages

    /// Above the bulk threshold the upgrades are found by a paged walk and
    /// written through the persister's own context. A row inserted this pass
    /// and already saved is upgraded on the very instance the rollups' pending
    /// lists hold, so it takes no session delta (it would count twice); a
    /// stored row takes one, on a live instance; and only the first stored
    /// row under a key is upgraded, as `enumerate` did.
    @ScanActor
    @Test(arguments: [1, 7, ModelWalk.pageSize])
    func bulkUpgradesAcrossPages(pageSize: Int) throws {
        let c = try container()
        let context = ModelContext(c)
        let first = try SamplePersister(context: context)
        for i in 0..<60 { try first.insert(entry(i)) }
        try first.flush()
        // A second stored row under one key: residue the duplicate repair
        // exists for. Marked by a column an upgrade doesn't write.
        let twin = TokenSample(from: entry(3))
        twin.accountId = "twin"
        context.insert(twin)
        try context.save()
        let firstUnderKey3 = try #require(try rows(c).first { $0.dedupKey == key(3) }).accountId

        // As after a relaunch: 23 new partial rows (saved every five, so 20
        // are on disk and three are not), then the finished copy of all 83.
        let reread = try SamplePersister(context: context, saveBatchSize: 5)
        reread.walkPageSize = pageSize
        for i in 60..<83 { try reread.insert(entry(i)) }
        #expect(context.insertedModelsArray.count == 3)
        for i in 0..<83 { try reread.insert(entry(i, output: 500 + Int64(i), complete: true)) }
        #expect(reread.stats.upgradedFromPartial == 83)
        try reread.flush()

        // Inserted this pass: the pending lists' instances carry the finished
        // counts, and no session delta was queued for them.
        let pending = reread.pendingSessionSamples.values.flatMap { $0 }
        for i in 60..<83 where !i.isMultiple(of: 11) {
            let s = try #require(pending.first { $0.dedupKey == key(i) })
            #expect(s.outputTokens == 500 + Int64(i))
        }
        let upgrades = reread.pendingSessionUpgrades.values.flatMap { $0 }
        let upgradedKeys = upgrades.compactMap(\.new.dedupKey)
        // Stored rows: exactly one delta each, partial → finished.
        let storedWithSession = (0..<60).filter { !$0.isMultiple(of: 11) }.map(key)
        #expect(upgradedKeys.sorted() == storedWithSession.sorted())
        for u in upgrades {
            let i = Int(u.new.dedupKey!.dropFirst().prefix { $0 != ":" })!
            #expect(u.old.breakdown.outputTokens == 1)
            #expect(u.new.outputTokens == 500 + Int64(i))
        }
        try context.save()

        let stored = try rows(c)
        #expect(stored.count == 84)
        for s in stored {
            let i = Int(s.dedupKey!.dropFirst().prefix { $0 != ":" })!
            if i == 3, s.accountId != firstUnderKey3 {
                #expect(s.outputTokens == 1, "only the first row under a key is upgraded")
            } else {
                #expect(s.outputTokens == 500 + Int64(i), "row \(i) kept its partial output")
            }
        }
        let days = Set(stored.map { DateModelPair(date: $0.date, model: $0.model) })
        #expect(days.isSubset(of: reread.pollutedDailyPairs))
        #expect(days.isSubset(of: reread.dirtyPairs))
    }

    /// The repair's second pass finds the offending rows a page at a time and
    /// deletes them through the persister's context, pending until the
    /// cycle's save. The keeper is chosen exactly as before: most output, then
    /// the earliest, then table order.
    @ScanActor
    @Test(arguments: [1, 7, ModelWalk.pageSize])
    func duplicateRepairAcrossPages(pageSize: Int) throws {
        let c = try container()
        let context = ModelContext(c)
        var marker: Int64 = 0
        func add(_ i: Int, output: Int64, offset: TimeInterval = 0) {
            let s = TokenSample(from: entry(i, output: output))
            s.sampledAt = s.sampledAt.addingTimeInterval(offset)
            marker += 1
            s.cacheReadTokens = marker   // which physical row survived
            context.insert(s)
        }
        for i in 0..<40 {
            add(i, output: 5)
            switch i {
            case 4: add(i, output: 5)                       // identical twin
            case 9: add(i, output: 900)                     // finished copy after the partial
            case 15: add(i, output: 1)                      // partial copy after the finished
            case 22: add(i, output: 5, offset: -60)         // same output, earlier
            case 30: add(i, output: 900); add(i, output: 300)
            default: break
            }
        }
        try context.save()

        // What should survive, worked out from the store's own order.
        let before = try rows(c)
        var groups: [String: [TokenSample]] = [:]
        for s in before { groups[s.dedupKey!, default: []].append(s) }
        var expectedKept: Set<Int64> = []
        var expectedRemoved = 0
        for (_, g) in groups {
            var best = g[0]
            for s in g.dropFirst() {
                if s.outputTokens != best.outputTokens {
                    if s.outputTokens > best.outputTokens { best = s }
                } else if s.sampledAt < best.sampledAt {
                    best = s
                }
            }
            expectedKept.insert(best.cacheReadTokens)
            expectedRemoved += g.count - 1
        }
        #expect(expectedRemoved == 6)

        let persister = try SamplePersister(context: context)
        persister.walkPageSize = pageSize
        #expect(try persister.repairDuplicateSamples() == expectedRemoved)
        #expect(context.deletedModelsArray.count == expectedRemoved, "deletes wait for the cycle's save")
        #expect(persister.stats.sessionPollution["repair"] == 4)   // group 22 has no session
        try context.save()

        let after = try rows(c)
        #expect(Set(after.map(\.cacheReadTokens)) == expectedKept)
        #expect(after.count == 40)
        #expect(try persister.repairDuplicateSamples() == 0)
    }

    /// The stored-hour backfill drains its own predicate a page at a time.
    /// Rows the persister's context holds are stamped through it, and a later
    /// save of theirs can't put the -1 back.
    @ScanActor
    @Test(arguments: [1, 7, ModelWalk.pageSize])
    func localHourBackfillAcrossPages(pageSize: Int) throws {
        let c = try container()
        // Written through a context of its own, as an older build's store
        // would be: nothing in the persister's context is older than the store.
        let scratch = ModelContext(c)
        for i in 0..<45 {
            let s = TokenSample(from: entry(i))
            if i >= 5 { s.localHour = -1 }
            scratch.insert(s)
        }
        try scratch.save()
        let context = ModelContext(c)
        let expected = try rows(c).map { s -> String in
            let copy = describe(s)
            return s.localHour < 0 ? copy.replacingOccurrences(
                of: "|-1|\(s.inputTokens)|", with: "|\(hour(s.sampledAt))|\(s.inputTokens)|") : copy
        }.sorted()

        let target = key(17)
        let held = try #require(try context.fetch(FetchDescriptor<TokenSample>(
            predicate: #Predicate { $0.dedupKey == target })).first)
        #expect(held.localHour == -1)
        // Unsaved work in the persister's context is saved first, not lost.
        let other = key(2)
        try #require(try context.fetch(FetchDescriptor<TokenSample>(
            predicate: #Predicate { $0.dedupKey == other })).first).accountId = "acct-a"

        let persister = try SamplePersister(context: context)
        persister.walkPageSize = pageSize
        try persister.markEverySampleDirty()
        #expect(held.localHour == hour(held.sampledAt))
        let stored = try rows(c)
        #expect(stored.map(describe).map {
            $0.replacingOccurrences(of: "|acct-a|", with: "|-|")
        }.sorted() == expected)
        #expect(stored.first { $0.dedupKey == other }?.accountId == "acct-a")
        let days = Set(stored.map { DateModelPair(date: $0.date, model: $0.model) })
        #expect(persister.dirtyPairs == days)
        #expect(persister.pollutedDailyPairs == days)

        held.outputTokens = 777
        try context.save()
        #expect(try rows(c).first { $0.dedupKey == target }?.localHour == hour(held.sampledAt))
    }

    /// The path re-canonicalisation writes every row a page at a time and
    /// marks both ends of every move, exactly as the whole-table walk did.
    @ScanActor
    @Test(arguments: [1, 7, ModelWalk.pageSize])
    func canonicalizationAcrossPages(pageSize: Int) throws {
        let c = try container()
        let scratch = ModelContext(c)
        for i in 0..<50 {
            let path: String
            switch i % 5 {
            case 0: path = "/Users/dev/code/p\(i % 3)/.claude/worktrees/agent-\(i)"
            case 1: path = "/Users/dev/code/old\(i % 2)"
            case 2: path = "/Users/dev/code/p\(i % 3)/.worktrees/feature-\(i)/sub"
            default: path = "/Users/dev/code/p\(i % 3)"
            }
            let s = TokenSample(from: entry(i, projectPath: path,
                                            originalProjectPath: i.isMultiple(of: 7) ? "/orig/\(i)" : nil))
            if i == 13 { s.projectPath = nil }   // no path at all: left alone
            scratch.insert(s)
        }
        try scratch.save()
        let context = ModelContext(c)
        let aliases = ["/Users/dev/code/old0": "/Users/dev/code/new0"]

        // Expected, from each row as stored.
        var expectedRows: [String] = []
        var expectedPairs: Set<ProjectDatePair> = []
        var expectedSessions: Set<String> = []
        var expectedChanged = 0
        for s in try rows(c) {
            guard let pre = s.projectPath else { expectedRows.append(describe(s)); continue }
            let canonical = ProjectPathCanonicalizer.canonicalize(pre, aliases: aliases)
            let original = s.originalProjectPath ?? pre
            if canonical != pre {
                expectedChanged += 1
                expectedPairs.insert(ProjectDatePair(projectPath: pre, date: s.date))
                expectedPairs.insert(ProjectDatePair(projectPath: canonical, date: s.date))
                if let sid = s.sessionId, !sid.isEmpty { expectedSessions.insert(sid) }
            }
            let line = describe(s).replacingOccurrences(
                of: "|\(pre)|\(s.originalProjectPath ?? "-")|", with: "|\(canonical)|\(original)|")
            expectedRows.append(line)
        }
        #expect(expectedChanged == 25)

        let target = key(20)   // a worktree path, so it moves
        let held = try #require(try context.fetch(FetchDescriptor<TokenSample>(
            predicate: #Predicate { $0.dedupKey == target })).first)
        let other = key(3)
        try #require(try context.fetch(FetchDescriptor<TokenSample>(
            predicate: #Predicate { $0.dedupKey == other })).first).accountId = "acct-b"

        let persister = try SamplePersister(context: context)
        persister.walkPageSize = pageSize
        #expect(try persister.canonicalizeProjectPaths(aliases: aliases) == expectedChanged)
        #expect(persister.dirtyProjectDates == expectedPairs)
        #expect(persister.pollutedProjectPairs == expectedPairs)
        #expect(persister.dirtySessionIds == expectedSessions)
        #expect(persister.pollutedSessionIds == expectedSessions)
        #expect(persister.dirtyPairs.isEmpty && persister.dirtyHourBuckets.isEmpty)
        #expect(held.projectPath == "/Users/dev/code/p2")
        let stored = try rows(c)
        #expect(stored.map(describe).map {
            $0.replacingOccurrences(of: "|acct-b|", with: "|-|")
        }.sorted() == expectedRows.sorted())

        held.outputTokens = 31_337
        try context.save()
        let reread = try rows(c).first { $0.dedupKey == target }
        #expect(reread?.projectPath == "/Users/dev/code/p2")
        #expect(reread?.originalProjectPath == "/Users/dev/code/p2/.claude/worktrees/agent-20")
    }
}
