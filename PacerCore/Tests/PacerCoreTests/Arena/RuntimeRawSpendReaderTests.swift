import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// The arena's history reads turns with raw SQLite (`RawSpendReader`), through
/// Core Data's mangled column names. So the test is parity: the same rows go
/// into a file store (read raw) and an in-memory one (read through SwiftData),
/// and the two histories must be identical, spend and meters, to the bit.
@Suite("Arena runtime: raw history reads match SwiftData exactly")
struct RuntimeRawSpendReaderTests {

    static let now = RuntimeHistoryBuilderTests.now
    static let account = RuntimeHistoryBuilderTests.account
    static func at(_ hoursAgo: Double) -> Date { now.addingTimeInterval(-hoursAgo * 3600) }

    private func fileStore() throws -> (ModelContainer, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arena-raw-\(UUID().uuidString).sqlite")
        return (try PacerStore.makeModelContainer(at: url), url)
    }

    private func remove(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }

    /// The awkward cases, inserted identically into `context`:
    /// - turns across many days and buckets, several models and families;
    /// - a stored cost (`sourceCostUSD`) beside computed ones, a fast-mode and
    ///   a US-residency turn (premium price variants), an unpriced model;
    /// - `<synthetic>` turns, another account's turns, unattributed turns;
    /// - turns exactly at the depth's start (excluded) and at `now` (included);
    /// - several turns in one bucket whose costs sum differently by order;
    /// - rate-limit, scoped and archived readings, so the whole store compares.
    private func seed(_ context: ModelContext) throws {
        func turn(_ at: Date, _ model: String, input: Int64, output: Int64, cacheRead: Int64 = 0,
                  c5m: Int64 = 0, c1h: Int64 = 0, account: String? = Self.account, stored: Double? = nil,
                  speed: String? = nil, geo: String? = nil) {
            let s = TokenSample(sampledAt: at, date: TokenSample.formatDate(at), model: model,
                                inputTokens: input, outputTokens: output, cacheReadTokens: cacheRead,
                                cacheCreation5mTokens: c5m, cacheCreation1hTokens: c1h, sourceCostUSD: stored)
            s.accountId = account
            s.speed = speed
            s.inferenceGeo = geo
            context.insert(s)
        }
        let models = ["claude-opus-5-5", "claude-sonnet-5", "claude-haiku-5", "mystery-model-x"]
        for i in 0..<900 {
            // Uneven spacing over ~100 days, with clusters inside buckets.
            let hoursAgo = Double(i) * 2.7 + (i.isMultiple(of: 7) ? 0.01 : 0.37)
            turn(Self.at(hoursAgo), models[i % models.count], input: Int64(100 + i * 13), output: Int64(7 + i % 50),
                 cacheRead: Int64(i * 31), c5m: Int64(i % 3 == 0 ? 200 : 0), c1h: Int64(i % 5 == 0 ? 90 : 0),
                 stored: i.isMultiple(of: 11) ? Double(i) * 1e-4 : nil,
                 speed: i.isMultiple(of: 13) ? "fast" : nil, geo: i.isMultiple(of: 17) ? "us" : nil)
        }
        // Three turns in one bucket, costs of very different sizes.
        let bucket = Date(timeIntervalSince1970: (Self.at(30).timeIntervalSince1970 / 300).rounded(.down) * 300)
        turn(bucket.addingTimeInterval(10), "claude-opus-5-5", input: 9_000_000, output: 1)
        turn(bucket.addingTimeInterval(20), "claude-opus-5-5", input: 1, output: 1)
        turn(bucket.addingTimeInterval(20), "claude-opus-5-5", input: 3, output: 3, cacheRead: 77)
        turn(Self.at(3), "<synthetic>", input: 5, output: 5)
        turn(Self.at(4), "claude-opus-5-5", input: 5, output: 5, account: "someone-else")
        turn(Self.at(5), "claude-opus-5-5", input: 5, output: 5, account: nil)
        // The boundaries: `(now - 120 d, now]`.
        turn(Self.now.addingTimeInterval(-120 * 86400), "claude-opus-5-5", input: 1, output: 1)
        turn(Self.now, "claude-sonnet-5", input: 2, output: 2)
        turn(Self.now.addingTimeInterval(1), "claude-sonnet-5", input: 2, output: 2)

        let reset = Self.at(-2)
        for i in 0..<40 {
            context.insert(RateLimitSample(sampledAt: Self.at(Double(40 - i) / 4), window: "five_hour",
                                           usedPercentage: Double(i / 3), resetsAt: reset, source: "oauth",
                                           accountId: Self.account))
            context.insert(RateLimitSample(sampledAt: Self.at(Double(40 - i) / 4), window: "seven_day",
                                           usedPercentage: Double(i / 9), resetsAt: Self.at(-90), source: "oauth",
                                           accountId: Self.account))
            context.insert(UsageLimitSample(sampledAt: Self.at(Double(40 - i) / 4), identity: "weekly_scoped|claude-fable|",
                                            kind: "weekly_scoped", group: "weekly", label: "Fable",
                                            percent: Double(i / 5), resetsAt: Self.at(-60), severity: "ok",
                                            isActive: false, modelId: "claude-fable", modelDisplayName: "Fable",
                                            source: "oauth", accountId: Self.account))
        }
        context.insert(AccountUsageArchive(accountId: Self.account, kind: AccountUsageArchive.kindRateLimit,
                                           sampledAt: Self.at(24 * 50), window: "five_hour", usedPercentage: 7,
                                           resetsAt: Self.at(24 * 50 - 2), source: "oauth"))
        try context.save()
    }

    static let pricing = PricingTable.Snapshot(pricingByModel: RuntimeHistoryBuilderTests.catalog)

    @Test(arguments: [CostMode.auto, .calculate, .display])
    func theRawSpendReadIsTheSwiftDataRead(mode: CostMode) throws {
        let (file, url) = try fileStore()
        defer { remove(url) }
        try seed(ModelContext(file))
        let after = Self.now.addingTimeInterval(-120 * 86400)
        let raw = ArenaHistoryBuilder.readSpend(container: file, account: Self.account, after: after, through: Self.now,
                                                pricing: Self.pricing, mode: mode)
        let viaSwiftData = ArenaHistoryBuilder.readSpendThroughSwiftData(
            container: file, account: Self.account, after: after, through: Self.now, pricing: Self.pricing, mode: mode)
        #expect(!raw.isEmpty)
        #expect(raw == viaSwiftData)
        // The raw path really ran (the file store has a URL), and found every
        // priced and unpriced family.
        #expect(ArenaHistoryBuilder.storeURL(file) != nil)
        #expect(Set(raw.map(\.family)) == ["opus", "sonnet", "haiku", "other"])
        #expect(raw.contains { $0.costUSD == nil })
    }

    /// The whole history, as the scorer builds it: the file store (raw reads
    /// for everything) and an in-memory store (SwiftData for everything) with
    /// the same rows.
    @Test func theWholeHistoryIsTheSameEitherWay() throws {
        let (file, url) = try fileStore()
        defer { remove(url) }
        let memory = try PacerStore.makeInMemoryContainer()
        try seed(ModelContext(file))
        try seed(ModelContext(memory))
        #expect(ArenaHistoryBuilder.storeURL(memory) == nil)
        var paced = 0
        let a = ArenaHistoryBuilder.build(container: file, account: Self.account, now: Self.now, mode: .auto,
                                          pricing: Self.pricing, pace: { paced += 1 })
        let b = ArenaHistoryBuilder.build(container: memory, account: Self.account, now: Self.now, mode: .auto,
                                          pricing: Self.pricing)
        #expect(a.store.spend == b.store.spend)
        #expect(a.store.meters == b.store.meters)
        #expect(a.store.dataStart == b.store.dataStart)
        #expect(a.store.tzOffsetMin == b.store.tzOffsetMin)
        #expect(a.store.spend[Self.account]?.isEmpty == false)
        #expect(a.store.meters.count == 3)
        // A day a statement, the budget's checkpoint between them.
        #expect(paced == 120)

        // Moved on ten minutes, both ways.
        let later = Self.now.addingTimeInterval(600)
        for c in [file, memory] {
            let ctx = ModelContext(c)
            let s = TokenSample(sampledAt: Self.now.addingTimeInterval(300), date: "x", model: "claude-opus-5-5",
                                inputTokens: 10, outputTokens: 10, cacheReadTokens: 0,
                                cacheCreation5mTokens: 0, cacheCreation1hTokens: 0)
            s.accountId = Self.account
            ctx.insert(s)
            try ctx.save()
        }
        let a2 = ArenaHistoryBuilder.extend(a, container: file, account: Self.account, now: later, mode: .auto,
                                            pricing: Self.pricing)
        let b2 = ArenaHistoryBuilder.extend(b, container: memory, account: Self.account, now: later, mode: .auto,
                                            pricing: Self.pricing)
        #expect(a2.store.spend == b2.store.spend)
        #expect(a2.store.meters == b2.store.meters)
    }

    /// The order turns arrive in changes nothing: the bucket sums are made in
    /// one fixed order.
    @Test func spendRowsDoNotDependOnReadOrder() {
        var turns: [ArenaHistoryBuilder.Turn] = []
        for i in 0..<400 {
            turns.append(.init(at: Millis(i % 37) * 20_000, family: i.isMultiple(of: 3) ? "opus" : "sonnet",
                               costUSD: i.isMultiple(of: 9) ? nil : 1 / Double(i + 1) * pow(10, Double(i % 7)),
                               tokens: i))
        }
        var rng = SystemRandomNumberGenerator()
        let shuffled = turns.shuffled(using: &rng)
        #expect(ArenaHistoryBuilder.spendRows(turns) == ArenaHistoryBuilder.spendRows(shuffled))
        #expect(ArenaHistoryBuilder.spendRows(turns) == ArenaHistoryBuilder.spendRows(turns.reversed()))
    }
}
