import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// The raw reader replaces a SwiftData fetch the forecast depends on, and its
/// column names are Core Data's mangled ones — an implementation detail of a
/// framework nobody here controls. So the test is parity, not plausibility:
/// rows go in through SwiftData and both readers must return the same sequence.
/// If Core Data ever renames a column the reader returns nil and the engine
/// falls back, but the mapping drifting *silently* is the failure worth
/// catching, and only this catches it.
@Suite("Raw SQLite limit reads match SwiftData exactly")
struct RawLimitReaderParityTests {

    private func makeStore() throws -> (ModelContainer, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).sqlite")
        let container = try ModelContainer(
            for: RateLimitSample.self, UsageLimitSample.self, Account.self,
            ExtraUsageSample.self, AccountUsageArchive.self, ClaudeCodeMeta.self,
            configurations: ModelConfiguration(url: url))
        return (container, url)
    }

    /// Values chosen to exercise the awkward parts: a nil `resetsAt`, a nil
    /// account, two accounts, and rows either side of the cutoff.
    private func seed(_ context: ModelContext, base: Date) throws {
        for i in 0..<40 {
            let at = base.addingTimeInterval(Double(i) * 60)
            context.insert(RateLimitSample(
                sampledAt: at,
                window: i.isMultiple(of: 2) ? "five_hour" : "seven_day",
                usedPercentage: Double(i) * 1.5,
                resetsAt: i.isMultiple(of: 5) ? nil : at.addingTimeInterval(3600),
                source: "oauth",
                accountId: i < 20 ? "orgA" : "orgB"))
            context.insert(UsageLimitSample(
                sampledAt: at,
                identity: "weekly_scoped|Fable|",
                kind: "weekly_scoped", group: "weekly", label: "Fable",
                percent: Double(i), resetsAt: i.isMultiple(of: 7) ? nil : at,
                severity: "normal", isActive: i.isMultiple(of: 3),
                modelId: i.isMultiple(of: 4) ? nil : "claude-fable-5",
                modelDisplayName: "Fable", surface: nil, source: "oauth",
                accountId: i < 20 ? "orgA" : "orgB"))
        }
        try context.save()
    }

    @Test("rate rows match, scoped to one account")
    func rateParityScoped() throws {
        let (container, url) = try makeStore()
        let context = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        try seed(context, base: base)
        let since = base.addingTimeInterval(300)

        var d = FetchDescriptor<RateLimitSample>(
            predicate: LimitScope.rateLimitPredicate(account: "orgA", since: since))
        d.sortBy = [SortDescriptor(\.sampledAt, order: .forward)]
        let expected = (try context.fetch(d)).map {
            EngineFeatures.RateRow(window: $0.window, at: $0.sampledAt,
                                   usedPercentage: $0.usedPercentage, resetsAt: $0.resetsAt)
        }
        let actual = RawLimitReader.rateRows(storeURL: url, account: "orgA", since: since)

        #expect(actual != nil)
        #expect(actual?.count == expected.count)
        #expect(expected.isEmpty == false)      // the comparison must be of something
        for (a, e) in zip(actual ?? [], expected) {
            #expect(a.window == e.window)
            #expect(abs(a.at.timeIntervalSince(e.at)) < 0.001)
            #expect(a.usedPercentage == e.usedPercentage)
            #expect(sameInstant(a.resetsAt, e.resetsAt))
        }
    }

    /// `nil` account means every account for `LimitScope`, and the raw reader
    /// has to agree — it drops the WHERE clause rather than binding a NULL,
    /// which would match nothing.
    @Test("rate rows match with no account filter")
    func rateParityUnscoped() throws {
        let (container, url) = try makeStore()
        let context = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        try seed(context, base: base)

        var d = FetchDescriptor<RateLimitSample>(
            predicate: LimitScope.rateLimitPredicate(account: nil, since: base))
        d.sortBy = [SortDescriptor(\.sampledAt, order: .forward)]
        let expected = try context.fetch(d)
        let actual = RawLimitReader.rateRows(storeURL: url, account: nil, since: base)
        #expect(actual?.count == expected.count)
        #expect(expected.count == 40)
    }

    @Test("scoped rows match, including the nullable columns")
    func scopedParity() throws {
        let (container, url) = try makeStore()
        let context = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        try seed(context, base: base)
        let since = base.addingTimeInterval(120)

        var d = FetchDescriptor<UsageLimitSample>(
            predicate: LimitScope.usageLimitPredicate(account: "orgB", since: since))
        d.sortBy = [SortDescriptor(\.sampledAt, order: .forward)]
        let expected = try context.fetch(d)
        let actual = RawLimitReader.scopedRows(storeURL: url, account: "orgB", since: since)

        #expect(actual != nil)
        #expect(actual?.count == expected.count)
        #expect(expected.isEmpty == false)
        for (a, e) in zip(actual ?? [], expected) {
            #expect(a.identity == e.identity)
            #expect(a.group == e.group)
            #expect(a.label == e.label)
            #expect(a.modelId == e.modelId)
            #expect(a.modelDisplayName == e.modelDisplayName)
            #expect(a.surface == e.surface)
            #expect(abs(a.at.timeIntervalSince(e.sampledAt)) < 0.001)
            #expect(a.usedPercentage == e.percent)
            #expect(sameInstant(a.resetsAt, e.resetsAt))
            #expect(a.isActive == e.isActive)
        }
    }

    /// A path with no database is the ordinary in-memory case, and must degrade
    /// to "the caller falls back", not to a crash or an empty answer that looks
    /// like real data.
    @Test("a missing store returns nil rather than empty")
    func missingStoreIsNil() {
        let url = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).sqlite")
        #expect(RawLimitReader.rateRows(storeURL: url, account: nil, since: .distantPast) == nil)
        #expect(RawLimitReader.scopedRows(storeURL: url, account: nil, since: .distantPast) == nil)
    }

    private func sameInstant(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return abs(x.timeIntervalSince(y)) < 0.001
        default: return false
        }
    }
}
