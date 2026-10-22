import Foundation
import SwiftData

/// Keeps the `PriceRecord` table in step with the catalogs and the curated
/// file (#296).
///
/// - **Curated rows** mirror the curated file exactly: added, updated and
///   removed with it. A catalog refresh never touches them.
/// - **Catalog rows** record changes. For every rate vector the merged
///   catalog states, compare it with that vector's open record: different →
///   close the open record at `now` and open a new one; the same → write
///   nothing. A vector's first record starts at its curated start date when
///   the curated file has one, otherwise at first sighting (`now`).
///
/// A catalog that stops listing a model writes nothing either: dropping an
/// entry is not a price change, and the last known price stays in effect.
public enum PriceLedgerStore {

    public struct SyncResult: Sendable {
        /// The ledger before and after the sync.
        public let previous: PriceLedger
        public let ledger: PriceLedger
        public let opened: [PriceRecordValue]
        public let closed: [PriceRecordValue]
        public let curatedChanged: Int
        public var changed: Bool { !opened.isEmpty || !closed.isEmpty || curatedChanged > 0 }
    }

    /// Read the ledger as stored.
    public static func load(context: ModelContext) throws -> PriceLedger {
        PriceLedger(records: try context.fetch(FetchDescriptor<PriceRecord>()).map(\.value))
    }

    /// One slot = one rate vector's timeline.
    private struct Slot: Hashable {
        let key: CanonicalModelID
        let speed: PriceSpeed
        let tier: Int64
        init(_ r: PriceRecordValue) {
            key = r.key; speed = r.speed; tier = r.tierAbovePromptTokens
        }
    }

    /// Bring the table up to date and return the resulting ledger. Saves
    /// only if something changed.
    ///
    /// `usedModels` are raw model strings the store has usage for: their
    /// identities are tracked even when they aren't `claude-*` (Claude Code
    /// pointed at another backend), so they can still be priced.
    public static func sync(
        context: ModelContext,
        catalog: [String: LiteLLMModelPricing],
        curated: CuratedPriceHistory,
        usedModels: Set<String> = [],
        now: Date = Date()
    ) throws -> SyncResult {
        let rows = try context.fetch(FetchDescriptor<PriceRecord>())
        let previous = PriceLedger(records: rows.map(\.value))
        var byId: [String: PriceRecord] = [:]
        for row in rows { byId[row.recordId] = row }

        // Curated: the file is the truth for curated rows.
        var curatedChanged = 0
        let wanted = Dictionary(uniqueKeysWithValues: curated.records.map { ($0.id, $0) })
        for (id, value) in wanted {
            if let row = byId[id] {
                if row.value != value { row.update(from: value); curatedChanged += 1 }
            } else {
                let row = PriceRecord(value, recordedAt: now)
                context.insert(row)
                byId[id] = row
                curatedChanged += 1
            }
        }
        for row in rows where row.curated && wanted[row.recordId] == nil {
            context.delete(row)
            byId[row.recordId] = nil
            curatedChanged += 1
        }
        var curatedStart: [Slot: Date] = [:]
        for r in curated.records {
            let slot = Slot(r)
            curatedStart[slot] = min(curatedStart[slot] ?? r.effectiveFrom, r.effectiveFrom)
        }

        // Catalog: record changes, one slot at a time.
        var catalogBySlot: [Slot: [PriceRecord]] = [:]
        for row in byId.values where !row.curated {
            catalogBySlot[Slot(row.value), default: []].append(row)
        }
        let used = Set(usedModels.map(CanonicalModelID.parse))
        var opened: [PriceRecordValue] = []
        var closed: [PriceRecordValue] = []
        for template in PriceLedger.catalogTemplates(catalog, alsoInclude: used) {
            let slot = Slot(template)
            let history = catalogBySlot[slot] ?? []
            let open = history.filter { $0.effectiveTo == nil }
                .max { $0.effectiveFrom < $1.effectiveFrom }
            if let open {
                if open.value.samePrice(as: template) { continue }
                if open.effectiveFrom >= now {
                    // Opened this very instant: correct it rather than leave
                    // a zero-length window behind.
                    var v = template
                    v.id = open.recordId
                    v.effectiveFrom = open.effectiveFrom
                    open.update(from: v)
                    opened.append(v)
                    continue
                }
                closed.append(open.value)
                open.effectiveTo = now
            }
            // First sighting starts at the curated start when there is one —
            // but only for a slot with no catalog history at all. A model
            // that comes back after a change starts now.
            let start = history.isEmpty ? (curatedStart[slot].map { min($0, now) } ?? now) : now
            var value = template
            value.effectiveFrom = start
            value.effectiveTo = nil
            value.id = PriceRecordValue.makeId(
                curated: false, key: value.key, speed: value.speed,
                tier: value.tierAbovePromptTokens, from: start)
            if let clash = byId[value.id] {
                clash.update(from: value)
            } else {
                let row = PriceRecord(value, recordedAt: now)
                context.insert(row)
                byId[value.id] = row
            }
            opened.append(value)
        }

        let result = SyncResult(
            previous: previous,
            ledger: PriceLedger(records: byId.values.map(\.value)),
            opened: opened, closed: closed, curatedChanged: curatedChanged)
        if result.changed { try context.save() }
        return result
    }
}

// MARK: - Rebuilding what a price change touched (#217)

/// The rollup buckets a set of price changes affects.
public struct RepriceScope: Sendable {
    public var daily: Set<DateModelPair> = []
    public var hourly: Set<DateHourModelTriple> = []
    public var project: Set<ProjectDatePair> = []
    public var sessions: Set<String> = []

    /// Per change, how many of each it touched and the daily cost it had —
    /// for the `model, window, old → new` log line.
    public struct Line: Sendable {
        public let change: PriceChange
        public var daily: Set<DateModelPair> = []
        public var hourly = 0, project = 0, sessions = 0
        public var costBefore: Double = 0
    }
    public var lines: [Line] = []

    public var isEmpty: Bool { daily.isEmpty && hourly.isEmpty && project.isEmpty && sessions.isEmpty }
}

extension PriceLedgerStore {

    /// Every bucket whose `pricedByRecordIds` names a key that changed price
    /// over that bucket's time.
    ///
    /// Matched by KEY (model, provider, region) and time, not by exact record
    /// id: a bucket remembers the records that priced it, and any change to
    /// that key's prices over the bucket's window — a record corrected,
    /// added, closed, or a curated one taking precedence — can change what
    /// it costs. A bucket the change doesn't reach is never touched.
    ///
    /// Bucket windows are padded by 14 hours either side: a day bucket's
    /// `date` is the local date at insert time, and a timezone change since
    /// would otherwise let a sample sit just outside the window computed now.
    /// Over-including a bucket costs one rebuild; missing one leaves it wrong.
    public static func affectedBuckets(context: ModelContext, changes: [PriceChange]) throws -> RepriceScope {
        var scope = RepriceScope()
        guard !changes.isEmpty else { return scope }
        scope.lines = changes.map { RepriceScope.Line(change: $0) }
        let needles = changes.map { PriceLedger.needle($0.key) }
        let pad: TimeInterval = 14 * 3600

        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = .current
        dayFormatter.dateFormat = "yyyy-MM-dd"
        var dayStart: [String: Date] = [:]
        func start(of date: String) -> Date? {
            if let d = dayStart[date] { return d }
            let d = dayFormatter.date(from: date)
            dayStart[date] = d
            return d
        }
        /// Indices of the changes `tokens` names whose window overlaps.
        func hits(_ tokens: String, _ from: Date, _ to: Date) -> [Int] {
            guard !tokens.isEmpty else { return [] }
            return needles.indices.filter {
                tokens.contains(needles[$0]) && changes[$0].overlaps(from - pad, to + pad)
            }
        }

        var daily = FetchDescriptor<DailyAggregate>()
        daily.propertiesToFetch = [\.date, \.model, \.pricedByRecordIds, \.totalCostUSD]
        for row in try context.fetch(daily) {
            guard let d = start(of: row.date) else { continue }
            for i in hits(row.pricedByRecordIds, d, d.addingTimeInterval(86_400)) {
                let pair = DateModelPair(date: row.date, model: row.model)
                scope.daily.insert(pair)
                if scope.lines[i].daily.insert(pair).inserted { scope.lines[i].costBefore += row.totalCostUSD }
            }
        }
        var hourly = FetchDescriptor<HourlyAggregate>()
        hourly.propertiesToFetch = [\.date, \.hour, \.model, \.pricedByRecordIds]
        for row in try context.fetch(hourly) {
            guard let d = start(of: row.date)?.addingTimeInterval(TimeInterval(row.hour) * 3600) else { continue }
            let found = hits(row.pricedByRecordIds, d, d.addingTimeInterval(3600))
            if !found.isEmpty {
                scope.hourly.insert(DateHourModelTriple(date: row.date, hour: row.hour, model: row.model))
                for i in found { scope.lines[i].hourly += 1 }
            }
        }
        var project = FetchDescriptor<ProjectDailyAggregate>()
        project.propertiesToFetch = [\.date, \.projectPath, \.pricedByRecordIds]
        for row in try context.fetch(project) {
            guard let d = start(of: row.date) else { continue }
            let found = hits(row.pricedByRecordIds, d, d.addingTimeInterval(86_400))
            if !found.isEmpty {
                scope.project.insert(ProjectDatePair(projectPath: row.projectPath, date: row.date))
                for i in found { scope.lines[i].project += 1 }
            }
        }
        var sessions = FetchDescriptor<SessionInfo>()
        sessions.propertiesToFetch = [\.sessionId, \.firstSeenAt, \.lastSeenAt, \.pricedByRecordIds]
        for row in try context.fetch(sessions) {
            let found = hits(row.pricedByRecordIds, row.firstSeenAt, row.lastSeenAt.addingTimeInterval(1))
            if !found.isEmpty {
                scope.sessions.insert(row.sessionId)
                for i in found { scope.lines[i].sessions += 1 }
            }
        }
        return scope
    }
}
