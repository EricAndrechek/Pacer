import Foundation
import SwiftData

/// The daily spend → meter fit (#317): reads 14 days of meter readings and
/// hourly spend, fits every account × window with `SpendMeterFitter`, and
/// stores one `SpendMeterFit` row each.
///
/// A `@ModelActor`, so it runs on its own context off the main actor.
/// Create it off the main actor too: a model actor built on the main thread
/// executes there. `AppBackgroundService` builds it inside a detached task
/// once per local day.
///
/// **Reads, all bounded by the span.** One fetch of `AccountHourlyAggregate`
/// for every account (by `date`, indexed), and per account one read of each
/// limit table from 14 days back. The limit tables are read through
/// `RawLimitReader` when the store is a file: on the store this was written
/// against that is ~130,000 readings across four accounts, about 8 s of
/// SwiftData materialisation at the ~65 µs a row `RawLimitReader` measured,
/// and a fraction of that through sqlite3. In-memory stores (tests) read
/// through SwiftData with the same bounds. Nothing is fetched per row, and
/// everything is written with one save.
@ModelActor
public actor SpendMeterFitWorker {

    public struct Entry: Sendable, Equatable {
        public let accountId: String
        public let window: String
        public let outcome: SpendMeterFitter.Outcome
    }

    public struct Report: Sendable {
        /// Local `yyyy-MM-dd` the fits were made for.
        public let fittedDay: String
        public let span: DateInterval
        public let entries: [Entry]
        /// Readings across both limit tables, and spend rows, read.
        public let readingRows: Int
        public let spendRows: Int
        public let elapsed: TimeInterval

        public var fitted: [SpendMeterFitResult] {
            entries.compactMap { if case .fitted(let r) = $0.outcome { return r } else { return nil } }
        }
    }

    /// Fit today unless today's fits already exist — a relaunch the same day
    /// keeps the morning's rows. Nil when there was nothing to do.
    public func runIfDue(now: Date = Date(), timeZone: TimeZone = .current) throws -> Report? {
        let day = TokenSample.formatDate(now, timeZone: timeZone)
        var probe = FetchDescriptor<SpendMeterFit>(predicate: #Predicate { $0.fittedDay == day })
        probe.fetchLimit = 1
        guard try modelContext.fetch(probe).isEmpty else { return nil }
        return try refit(now: now, timeZone: timeZone)
    }

    /// Fit every account and window for the local day containing `now`, and
    /// upsert the results.
    ///
    /// `span` overrides the trailing 14 whole days; `persist: false` fits
    /// without writing. Both are for the real-store probe, which compares a
    /// longer span with the research harness.
    public func refit(
        now: Date = Date(), timeZone: TimeZone = .current,
        span override: DateInterval? = nil, persist: Bool = true
    ) throws -> Report {
        let started = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = TokenSample.formatDate(now, timeZone: timeZone)
        let span = override ?? SpendMeterFitter.span(endingAtStartOf: now, calendar: calendar)
        // One pair-gap either side: a pair that crosses the span's edge
        // still credits the hour inside it.
        let since = span.start.addingTimeInterval(-SpendMeterFitter.maxPairGap)
        let until = span.end.addingTimeInterval(SpendMeterFitter.maxPairGap)

        let accounts = try modelContext.fetch(FetchDescriptor<Account>())
            .map(\.id)
            .filter { $0 != AccountDailyAggregate.unattributedKey }
            .sorted()

        // Spend: one bounded fetch for every account. The end day is
        // included and trimmed by the fitter, which only keeps observed
        // hours inside the span — so an override span need not fall on
        // midnight.
        let startKey = TokenSample.formatDate(span.start, timeZone: timeZone)
        let endKey = TokenSample.formatDate(span.end, timeZone: timeZone)
        let spendRows = try modelContext.fetch(FetchDescriptor<AccountHourlyAggregate>(
            predicate: #Predicate { $0.date >= startKey && $0.date <= endKey }))
        var spendByAccount: [String: [HourlySpend]] = [:]
        for row in spendRows {
            spendByAccount[row.accountId, default: []].append(
                HourlySpend(date: row.date, hour: row.hour, model: row.model, costUSD: row.totalCostUSD))
        }

        var entries: [Entry] = []
        var readingCount = 0
        for account in accounts {
            let spend = spendByAccount[account] ?? []
            let windows = readings(account: account, since: since, until: until)
            readingCount += windows.reduce(0) { $0 + $1.readings.count }
            for w in windows {
                let outcome = SpendMeterFitter.fit(
                    accountId: account, window: w.key, duration: w.duration,
                    readings: w.readings, spend: spend, span: span, timeZone: timeZone,
                    counts: SpendMeterFitter.capCounts(modelId: w.capModelId, displayName: w.capModelName))
                entries.append(Entry(accountId: account, window: w.key, outcome: outcome))
            }
        }

        if persist {
            let existing = try modelContext.fetch(FetchDescriptor<SpendMeterFit>(
                predicate: #Predicate { $0.fittedDay == day }))
            var byKey: [String: SpendMeterFit] = [:]
            for row in existing { byKey[row.fitKey] = row }
            for entry in entries {
                guard case .fitted(let result) = entry.outcome else { continue }
                let key = SpendMeterFit.makeKey(accountId: result.accountId, window: result.window, fittedDay: day)
                if let row = byKey[key] {
                    row.apply(result, fittedAt: now)
                } else {
                    let row = SpendMeterFit(result: result, fittedDay: day, fittedAt: now)
                    modelContext.insert(row)
                    byKey[key] = row
                }
            }
            if modelContext.hasChanges { try modelContext.save() }
        }

        let report = Report(fittedDay: day, span: span, entries: entries,
                            readingRows: readingCount, spendRows: spendRows.count,
                            elapsed: Date().timeIntervalSince(started))
        if persist { Self.log(report) }
        return report
    }

    // MARK: - Reads

    struct WindowReadings {
        let key: String
        let duration: TimeInterval
        /// The model a scoped cap names, if any: only its spend can move it.
        var capModelId: String? = nil
        var capModelName: String? = nil
        var readings: [MeterReading]
    }

    /// One account's readings for every window it reports: the two fixed
    /// blocks, then each model-scoped `limits[]` cap. The account-wide
    /// `session` / `weekly_all` scoped rows duplicate the fixed blocks and
    /// are left out, as every other reader of them does.
    func readings(account: String, since: Date, until: Date) -> [WindowReadings] {
        var fixed: [String: [MeterReading]] = [:]
        var scoped: [String: WindowReadings] = [:]

        if let url = rawStoreURL,
           let rows = RawLimitReader.rateRows(storeURL: url, account: account, since: since) {
            for r in rows where r.at < until {
                fixed[r.window, default: []].append(
                    MeterReading(at: r.at, percent: r.usedPercentage, resetsAt: r.resetsAt))
            }
        } else {
            let rows = (try? modelContext.fetch(FetchDescriptor<RateLimitSample>(
                predicate: #Predicate { $0.accountId == account && $0.sampledAt >= since && $0.sampledAt < until },
                sortBy: [SortDescriptor(\.sampledAt)]
            ))) ?? []
            for r in rows {
                fixed[r.window, default: []].append(
                    MeterReading(at: r.sampledAt, percent: r.usedPercentage, resetsAt: r.resetsAt))
            }
        }

        func addScoped(identity: String, group: String, modelId: String?, modelName: String?,
                       surface: String?, reading: MeterReading) {
            let isModelScoped = (modelId?.isEmpty == false) || (modelName?.isEmpty == false)
                || (surface?.isEmpty == false)
            guard isModelScoped else { return }
            if scoped[identity] == nil {
                scoped[identity] = WindowReadings(
                    key: identity, duration: WindowSpec.scopedDuration(group: group), readings: [])
            }
            // Rows arrive oldest first, so the newest naming wins.
            if modelId?.isEmpty == false { scoped[identity]!.capModelId = modelId }
            if modelName?.isEmpty == false { scoped[identity]!.capModelName = modelName }
            scoped[identity]!.readings.append(reading)
        }
        if let url = rawStoreURL,
           let rows = RawLimitReader.scopedRows(storeURL: url, account: account, since: since) {
            for r in rows where r.at < until {
                addScoped(identity: r.identity, group: r.group, modelId: r.modelId,
                          modelName: r.modelDisplayName, surface: r.surface,
                          reading: MeterReading(at: r.at, percent: r.usedPercentage, resetsAt: r.resetsAt))
            }
        } else {
            let rows = (try? modelContext.fetch(FetchDescriptor<UsageLimitSample>(
                predicate: #Predicate {
                    $0.accountId == account && $0.sampledAt >= since && $0.sampledAt < until
                        && ($0.modelId != nil || $0.modelDisplayName != nil || $0.surface != nil)
                },
                sortBy: [SortDescriptor(\.sampledAt)]
            ))) ?? []
            for r in rows {
                addScoped(identity: r.identity, group: r.group, modelId: r.modelId,
                          modelName: r.modelDisplayName, surface: r.surface,
                          reading: MeterReading(at: r.sampledAt, percent: r.percent, resetsAt: r.resetsAt))
            }
        }

        var out: [WindowReadings] = []
        for kind in RateLimitWindowKind.allCases {
            guard let rows = fixed[kind.rawValue], let duration = PaceMath.windowDuration(for: kind.rawValue)
            else { continue }
            out.append(WindowReadings(key: kind.rawValue, duration: duration, readings: rows))
        }
        out += scoped.values.sorted { $0.key < $1.key }
        return out
    }

    /// The file this worker's own container is backed by, or nil for an
    /// in-memory one. Never `PacerStore.storeURL()`: a test or the probe
    /// runs against a different store than the app's — see the engine's
    /// `rawStoreURL` for the time that went wrong.
    private var rawStoreURL: URL? {
        guard let config = modelContext.container.configurations.first,
              !config.isStoredInMemoryOnly
        else { return nil }
        return config.url
    }

    // MARK: - Log

    static func log(_ report: Report) {
        for entry in report.entries {
            let who = "\(entry.accountId.suffix(4)) \(entry.window)"
            switch entry.outcome {
            case .fitted(let r):
                Log.write("SpendMeterFit", String(
                    format: "%@: pooled %.3f pts/$ R² %.2f · per-model R² %.2f rmse %.2f models=%d hours=%d · intercept %.1f%% vs no-spend %.1f%% of %.0f pts",
                    who, r.pooledRate, r.pooledR2, r.r2, r.rmse, r.modelRates.count, r.hours,
                    100 * r.interceptShare, 100 * r.noSpendRiseShare, r.totalRise))
            case .skipped(let reason):
                Log.write("SpendMeterFit", "\(who): not fitted, \(reason)")
            }
        }
        Log.write("SpendMeterFit", String(
            format: "%@: %d fitted, %d skipped in %.0f ms (%d readings, %d spend rows)",
            report.fittedDay, report.fitted.count, report.entries.count - report.fitted.count,
            report.elapsed * 1000, report.readingRows, report.spendRows))
    }
}
