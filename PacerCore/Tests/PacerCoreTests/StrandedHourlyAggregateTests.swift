import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// `HourlyAggregate` rows whose bucket no longer matches any sample.
///
/// `TokenSample.date` is stored at insert; the hour is **derived** from
/// `sampledAt` through the current calendar. Anything that shifts that
/// derivation — a DST boundary, a timezone change, an older build computing
/// it differently — re-buckets the sample and strands the row it used to
/// live in. Nothing cleaned those up: the recomputer only deletes a bucket
/// that's in its dirty set, and a bucket with no samples is never dirtied by
/// an insert.
///
/// Found on a real store as 34 stranded rows holding 1,915,526 output tokens
/// — the hourly rollup reading ~1% high while the daily rollup, which buckets
/// on the stored `date`, matched its samples exactly. Each stranded row
/// carried the sample count belonging to the hour after it, which is the
/// one-hour-shift signature:
///
///     agg hour:   7    8    9   10
///     agg count: 18   18   44   44
///     actual:     0   18    0   44
@Suite struct StrandedHourlyAggregateTests {

    @ScanActor
    @Test func strandedHourlyRowsAreDetectedAndDeleted() throws {
        let container = try ModelContainer(
            for: TokenSample.self, HourlyAggregate.self, DailyAggregate.self,
                ProjectDailyAggregate.self, SessionInfo.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)

        // One sample, and the hourly row it legitimately belongs to.
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let hour = Calendar.current.component(.hour, from: at)
        let date = TokenSample.formatDate(at)
        context.insert(TokenSample(
            sampledAt: at, date: date, model: "claude-opus-5",
            inputTokens: 10, outputTokens: 20, cacheReadTokens: 0,
            cacheCreation5mTokens: 0, cacheCreation1hTokens: 0))
        context.insert(HourlyAggregate(
            date: date, hour: hour, model: "claude-opus-5",
            inputTokens: 10, outputTokens: 20, cacheReadTokens: 0,
            cacheCreation5mTokens: 0, cacheCreation1hTokens: 0,
            totalCostUSD: 0, sampleCount: 1))
        // …and the stranded twin an hour earlier, as a shift leaves behind.
        context.insert(HourlyAggregate(
            date: date, hour: (hour + 23) % 24, model: "claude-opus-5",
            inputTokens: 10, outputTokens: 20, cacheReadTokens: 0,
            cacheCreation5mTokens: 0, cacheCreation1hTokens: 0,
            totalCostUSD: 0, sampleCount: 1))
        try context.save()

        // The persister spots it during its preload walk.
        let persister = try SamplePersister(context: context)
        let stranded = persister.consumeStrandedHourBuckets()
        #expect(stranded.count == 1)
        #expect(stranded.first?.hour == (hour + 23) % 24)

        #expect(try persister.deleteHourAggregates(stranded) == 1)
        try context.save()

        // The legitimate row survives; totals now match the samples again.
        let rows = try context.fetch(FetchDescriptor<HourlyAggregate>())
        #expect(rows.count == 1)
        #expect(rows.first?.hour == hour)
        #expect(rows.reduce(0) { $0 + $1.outputTokens } == 20)

        // Draining is one-shot.
        #expect(persister.consumeStrandedHourBuckets().isEmpty)
    }

    /// A store with no drift must lose nothing.
    @ScanActor
    @Test func healthyStoreHasNoStrandedBuckets() throws {
        let container = try ModelContainer(
            for: TokenSample.self, HourlyAggregate.self, DailyAggregate.self,
                ProjectDailyAggregate.self, SessionInfo.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let hour = Calendar.current.component(.hour, from: at)
        let date = TokenSample.formatDate(at)
        context.insert(TokenSample(
            sampledAt: at, date: date, model: "claude-opus-5",
            inputTokens: 10, outputTokens: 20, cacheReadTokens: 0,
            cacheCreation5mTokens: 0, cacheCreation1hTokens: 0))
        context.insert(HourlyAggregate(
            date: date, hour: hour, model: "claude-opus-5",
            inputTokens: 10, outputTokens: 20, cacheReadTokens: 0,
            cacheCreation5mTokens: 0, cacheCreation1hTokens: 0,
            totalCostUSD: 0, sampleCount: 1))
        try context.save()

        let persister = try SamplePersister(context: context)
        #expect(persister.consumeStrandedHourBuckets().isEmpty)
    }
}
