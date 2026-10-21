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
