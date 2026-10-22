import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// #217: a price change rebuilds exactly the buckets it affects — the ones
/// priced by the changed key over the changed window — and nothing else.
@Suite("Reprice rebuild")
struct RepriceRebuildTests {

    static let day: TimeInterval = 86_400
    /// Midday UTC, so a date string is the same day in any test timezone.
    static let d0 = Date(timeIntervalSince1970: 1_790_078_400)   // 2026-09-22 12:00Z

    static func ledger(_ records: [PriceRecordValue]) -> PricingTable.Snapshot {
        PricingTable.Snapshot(pricingByModel: [:], ledger: PriceLedger(records: records))
    }

    static func rec(_ model: String, read: Double, from: Date, to: Date? = nil,
                    source: PriceSource = .litellm) -> PriceRecordValue {
        PriceRecordValue(
            key: CanonicalModelID(model: model),
            rates: PriceRates(input: 2e-6, output: 10e-6, cacheRead: read * 1e-6,
                              cacheWrite5m: 2.5e-6, cacheWrite1h: 4e-6),
            effectiveFrom: from, effectiveTo: to, source: source, reviewedAt: source == .curated ? from : nil)
    }

    // MARK: Diff

    @Test func anIdenticalLedgerHasNoChanges() {
        let a = PriceLedger(records: [Self.rec("claude-x", read: 0.2, from: Self.d0)])
        #expect(a.changes(since: a).isEmpty)
    }

    @Test func aRefreshClosingTheOpenRecordChangesOnlyFromThen() {
        let change = Self.d0.addingTimeInterval(5 * Self.day)
        let old = PriceLedger(records: [Self.rec("claude-x", read: 0.2, from: Self.d0)])
        let new = PriceLedger(records: [
            Self.rec("claude-x", read: 0.2, from: Self.d0, to: change),
            Self.rec("claude-x", read: 0.1, from: change),
        ])
        let changes = new.changes(since: old)
        #expect(changes.count == 1)
        #expect(changes.first?.from == change && changes.first?.to == nil)
        #expect(changes.first?.old?.cacheRead == 0.2e-6 && changes.first?.new?.cacheRead == 0.1e-6)
    }

    @Test func aCuratedRecordAtTheSameNumbersChangesNothing() {
        let old = PriceLedger(records: [Self.rec("claude-x", read: 0.2, from: Self.d0)])
        let new = PriceLedger(records: old.records + [Self.rec("claude-x", read: 0.2, from: Self.d0, source: .curated)])
        #expect(new.changes(since: old).isEmpty)
    }

    @Test func aModelGainingItsFirstPriceChangesForAllTime() {
        let new = PriceLedger(records: [Self.rec("claude-x", read: 0.2, from: Self.d0)])
        let changes = new.changes(since: .empty)
        #expect(changes.count == 1)
        #expect(changes.first?.from == .distantPast && changes.first?.to == nil && changes.first?.old == nil)
    }

    @Test func tokensNameTheirKey() {
        let r = Self.rec("claude-x", read: 0.2, from: Self.d0)
        #expect(PriceLedger.key(ofToken: r.id) == r.key)
        #expect(PriceLedger.key(ofToken: "~" + r.id) == r.key)
        let us = CanonicalModelID(model: "claude-x", provider: .bedrock, region: .us)
        #expect(PriceLedger.key(ofToken: PriceLedger.noneToken(us)) == us)
        #expect(PriceLedger.noneToken(us).contains(PriceLedger.needle(us)))
        #expect(r.id.contains(PriceLedger.needle(r.key)))
    }

    // MARK: End to end

    /// Two models over six days, rolled up at one price; then model X's
    /// cache-read rate changes from day 3. Rebuilding the scope the change
    /// names must reprice X from day 3 on, leave X's earlier days and every
    /// Y bucket alone, and agree with a fresh rebuild of everything.
    @ScanActor
    @Test func aPriceChangeRebuildsExactlyTheBucketsItAffects() async throws {
        let container = try ModelContainer(
            for: Schema(PacerStore.allModelTypes),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        for dayIndex in 0..<6 {
            for model in ["claude-x", "claude-y"] {
                let at = Self.d0.addingTimeInterval(Double(dayIndex) * Self.day)
                let s = TokenSample(
                    sampledAt: at, date: TokenSample.formatDate(at), model: model,
                    inputTokens: 1_000, outputTokens: 100, cacheReadTokens: 1_000_000,
                    cacheCreation5mTokens: 0, cacheCreation1hTokens: 0,
                    sessionId: "s-\(model)", projectPath: "/p/\(model)")
                context.insert(s)
            }
        }
        try context.save()

        let before = Self.ledger([Self.rec("claude-x", read: 0.2, from: .distantPast),
                                  Self.rec("claude-y", read: 0.2, from: .distantPast)])
        let change = Self.d0.addingTimeInterval(3 * Self.day - 12 * 3600)   // start of day 3
        let after = Self.ledger([
            Self.rec("claude-x", read: 0.2, from: .distantPast, to: change),
            Self.rec("claude-x", read: 0.1, from: change),
            Self.rec("claude-y", read: 0.2, from: .distantPast),
        ])

        func rebuild(_ pricing: PricingTable.Snapshot, daily: Set<DateModelPair>, hourly: Set<DateHourModelTriple>,
                     project: Set<ProjectDatePair>, sessions: Set<String>) async throws {
            _ = try await AggregateRecomputer(container: container, context: context, mode: .calculate,
                                              pricing: pricing).recompute(pairs: daily, polluted: daily)
            _ = try await HourlyAggregateRecomputer(container: container, context: context, mode: .calculate,
                                                    pricing: pricing).recompute(buckets: hourly, polluted: hourly)
            _ = try await ProjectAggregateRecomputer(container: container, context: context, mode: .calculate,
                                                     pricing: pricing).recompute(pairs: project, polluted: project)
            _ = try await SessionInfoRecomputer(container: container, context: context, mode: .calculate,
                                                pricing: pricing).recompute(sessionIds: sessions, polluted: sessions)
            try context.save()
        }
        let samples = try context.fetch(FetchDescriptor<TokenSample>())
        let allDaily = Set(samples.map { DateModelPair(date: $0.date, model: $0.model) })
        let allHourly = Set(samples.map { DateHourModelTriple(date: $0.date, hour: $0.localHour, model: $0.model) })
        let allProject = Set(samples.map { ProjectDatePair(projectPath: $0.projectPath!, date: $0.date) })
        let allSessions = Set(samples.compactMap(\.sessionId))
        try await rebuild(before, daily: allDaily, hourly: allHourly, project: allProject, sessions: allSessions)

        let daily0 = try context.fetch(FetchDescriptor<DailyAggregate>())
        #expect(daily0.allSatisfy { $0.pricedByRecordIds.contains(PriceLedger.needle(CanonicalModelID(model: $0.model))) })

        let changes = after.ledger.changes(since: before.ledger)
        #expect(changes.count == 1 && changes.first?.key.model == "claude-x")
        let scope = try PriceLedgerStore.affectedBuckets(context: context, changes: changes)

        // Day 2 is inside the 14-hour pad of a day-3 change, so days 2…5 of
        // X — never any Y bucket, never X's days 0 and 1.
        #expect(Set(scope.daily.map(\.model)) == ["claude-x"])
        #expect(scope.daily.count == 4)
        #expect(scope.project.allSatisfy { $0.projectPath == "/p/claude-x" })
        #expect(scope.sessions == ["s-claude-x"])
        let costBefore = Dictionary(uniqueKeysWithValues: daily0.map { ($0.dateModelKey, $0.totalCostUSD) })

        try await rebuild(after, daily: scope.daily, hourly: scope.hourly, project: scope.project, sessions: scope.sessions)

        for row in try context.fetch(FetchDescriptor<DailyAggregate>()) {
            let old = costBefore[row.dateModelKey]!
            let isChangedDay = row.model == "claude-x" && Self.dayIndex(row.date) >= 3
            if isChangedDay {
                #expect(abs(old - row.totalCostUSD - 0.10) < 1e-9, "\(row.dateModelKey)")
            } else {
                #expect(row.totalCostUSD == old, "\(row.dateModelKey) moved")
            }
        }

        // A targeted rebuild must land exactly where a full rebuild does.
        let targeted = try Self.costs(context)
        try await rebuild(after, daily: allDaily, hourly: allHourly, project: allProject, sessions: allSessions)
        #expect(try Self.costs(context) == targeted)
    }

    static func dayIndex(_ date: String) -> Int {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        let first = TokenSample.formatDate(d0)
        return Int((f.date(from: date)!.timeIntervalSince(f.date(from: first)!) / day).rounded())
    }

    struct Costs: Equatable {
        var daily: [String: Double], hourly: Double, project: Double, session: Double
    }

    static func costs(_ context: ModelContext) throws -> Costs {
        func r(_ x: Double) -> Double { (x * 1e9).rounded() / 1e9 }
        return Costs(
            daily: Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<DailyAggregate>())
                .map { ($0.dateModelKey, r($0.totalCostUSD)) }),
            hourly: r(try context.fetch(FetchDescriptor<HourlyAggregate>()).reduce(0) { $0 + $1.totalCostUSD }),
            project: r(try context.fetch(FetchDescriptor<ProjectDailyAggregate>()).reduce(0) { $0 + $1.totalCostUSD }),
            session: r(try context.fetch(FetchDescriptor<SessionInfo>()).reduce(0) { $0 + $1.cumulativeCostUSD }))
    }

    @ScanActor
    @Test func aModelGainingAPriceRebuildsOnlyItsUnpricedBuckets() throws {
        let context = ModelContext(try ModelContainer(
            for: Schema(PacerStore.allModelTypes),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        let x = CanonicalModelID(model: "claude-new")
        let priced = DailyAggregate(date: "2026-09-22", model: "claude-y")
        priced.pricedByRecordIds = Self.rec("claude-y", read: 0.2, from: Self.d0).id
        let unpriced = DailyAggregate(date: "2026-09-22", model: "claude-new")
        unpriced.pricedByRecordIds = PriceLedger.noneToken(x)
        context.insert(priced)
        context.insert(unpriced)
        let y = Self.rec("claude-y", read: 0.2, from: Self.d0)
        let changes = PriceLedger(records: [y, Self.rec("claude-new", read: 0.2, from: Self.d0)])
            .changes(since: PriceLedger(records: [y]))
        let scope = try PriceLedgerStore.affectedBuckets(context: context, changes: changes)
        #expect(scope.daily == [DateModelPair(date: "2026-09-22", model: "claude-new")])
    }
}
