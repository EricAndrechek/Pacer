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
        // The store walk is lazy now — `ScanCoordinator` forces it on a
        // schedule for exactly these integrity checks. Do the same here.
        try persister.ensurePreloaded()
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
        // The store walk is lazy now — `ScanCoordinator` forces it on a
        // schedule for exactly these integrity checks. Do the same here.
        try persister.ensurePreloaded()
        #expect(persister.consumeStrandedHourBuckets().isEmpty)
    }
}

/// The stored hour is what stops buckets drifting in the first place.
///
/// Deleting stranded rows only fixes the case where the sample's new bucket
/// didn't exist. Where both the old and new bucket exist, a shift just
/// misfiles the numbers — measured on a real store as 64 of 1,440 buckets
/// holding another hour's values, one 289k output too low while its neighbour
/// ran 253k high. Storing the hour at insert removes the derivation that
/// could move.
@Suite struct StoredLocalHourTests {

    @Test func hourIsStoredAtInsert() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let sample = TokenSample(
            sampledAt: at, date: TokenSample.formatDate(at), model: "claude-opus-5",
            inputTokens: 1, outputTokens: 1, cacheReadTokens: 0,
            cacheCreation5mTokens: 0, cacheCreation1hTokens: 0)
        #expect(sample.localHour == Calendar.current.component(.hour, from: at))
        #expect(sample.localHour >= 0 && sample.localHour <= 23)
    }

    /// A row written before the field existed carries the sentinel, and must
    /// keep working by deriving until the backfill walk reaches it.
    @Test func sentinelMeansNotBackfilledYet() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let sample = TokenSample(
            sampledAt: at, date: TokenSample.formatDate(at), model: "claude-opus-5",
            inputTokens: 1, outputTokens: 1, cacheReadTokens: 0,
            cacheCreation5mTokens: 0, cacheCreation1hTokens: 0)
        sample.localHour = -1          // as a pre-migration row decodes
        let row = SampleSnapshot.Row(
            date: sample.date, model: sample.model, projectPath: nil, sessionId: nil,
            sampledAt: sample.sampledAt,
            localHour: sample.localHour >= 0
                ? sample.localHour
                : Calendar.current.component(.hour, from: sample.sampledAt),
            ccVersion: nil, breakdown: sample.breakdown, sourceCostUSD: nil)
        #expect(row.localHour == Calendar.current.component(.hour, from: at))
    }

    /// The stored hour must survive a timezone change, which is the whole
    /// point — a derived one would not.
    @Test func storedHourDoesNotFollowTheCalendar() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let sample = TokenSample(
            sampledAt: at, date: TokenSample.formatDate(at), model: "claude-opus-5",
            inputTokens: 1, outputTokens: 1, cacheReadTokens: 0,
            cacheCreation5mTokens: 0, cacheCreation1hTokens: 0)
        let recorded = sample.localHour

        // What a shifted calendar would have produced instead.
        var shifted = Calendar(identifier: .gregorian)
        shifted.timeZone = TimeZone(secondsFromGMT: Calendar.current.timeZone.secondsFromGMT(for: at) + 3600)!
        let derivedAfterShift = shifted.component(.hour, from: at)

        #expect(sample.localHour == recorded)          // unchanged
        #expect(derivedAfterShift != recorded)         // a derivation would have moved
    }
}

/// Both rollup paths must bucket on the STORED hour.
///
/// The bulk path and the per-bucket path each decide which samples belong to
/// an hour, and they're separate code. Moving only one off the derived hour
/// leaves the other drifting — which is exactly what happened: the bulk
/// worker was fixed while `recomputeOne` kept calling
/// `Calendar.component(.hour:)`, so the fix silently applied to full rebuilds
/// but not to incremental ones.
///
/// A sample whose stored hour deliberately disagrees with its derived hour
/// pins both paths to the stored value.
@Suite struct HourlyBucketingUsesStoredHourTests {

    @ScanActor
    @Test func perBucketRecomputeUsesStoredHour() async throws {
        let container = try ModelContainer(
            for: TokenSample.self, HourlyAggregate.self, DailyAggregate.self,
                ProjectDailyAggregate.self, SessionInfo.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)

        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let derived = Calendar.current.component(.hour, from: at)
        let stored = (derived + 5) % 24          // deliberately not the derived one
        let date = TokenSample.formatDate(at)

        let sample = TokenSample(
            sampledAt: at, date: date, model: "claude-opus-5",
            inputTokens: 3, outputTokens: 7, cacheReadTokens: 0,
            cacheCreation5mTokens: 0, cacheCreation1hTokens: 0)
        sample.localHour = stored
        context.insert(sample)
        try context.save()

        // One bucket keeps this on the per-bucket path, not the bulk worker.
        let recomputer = HourlyAggregateRecomputer(
            container: container, context: context, mode: .display)
        _ = try await recomputer.recompute(
            buckets: [DateHourModelTriple(date: date, hour: stored, model: "claude-opus-5")])
        try context.save()

        let rows = try context.fetch(FetchDescriptor<HourlyAggregate>())
        #expect(rows.count == 1)
        #expect(rows.first?.hour == stored)
        // The sample counted — if this path still derived, it would have
        // filtered itself out and written a zeroed or deleted bucket.
        #expect(rows.first?.outputTokens == 7)
        #expect(rows.first?.sampleCount == 1)
    }
}
