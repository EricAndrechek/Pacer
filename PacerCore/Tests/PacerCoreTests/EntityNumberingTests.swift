import Foundation
import SQLite3
import SwiftData
import Testing
@testable import PacerCore

/// A new `@Model` must never renumber the shipped ones (#387).
///
/// Core Data numbers a store's entities (`Z_ENT`, written into every row of
/// every table and into every persistent-history change) in entity-NAME
/// order, and SwiftData's entity name is the class name, with no way to set
/// another. So a model whose name sorts among the existing ones shifts the
/// number of every entity after it, and the first launch of that release
/// rewrites those tables and the history: on a real 1.4 GB store, 2.1 GB
/// written in `prepareStore`, against 0.7 MB for the same change with the new
/// model named to sort last (`PACER_INGEST_EXTRA_ENTITY` in `IngestHarness`). 0.8.0's `PriceRecord` (number 18 of 30) did this
/// to every upgrading Mac.
///
/// The rule this holds: a model added after a release is named
/// `Z<three-digit sequence><Name>` (`Z001LiveMeterOutcome`), the next number
/// after the highest one in use, so it sorts after every shipped entity and
/// after every earlier addition. When a release ships, add its new models to
/// `shipped` with the numbers a fresh store gives them.
@Suite("Entity numbering: a new model never renumbers the shipped ones")
struct EntityNumberingTests {

    /// Every entity a released store holds, with its `Z_ENT` (as of 0.9.3:
    /// read from a real store's `Z_PRIMARYKEY`; the `Z00n` models shipped in
    /// 0.9.0).
    static let shipped: [String: Int] = [
        "Account": 1, "AccountActivation": 2, "AccountDailyAggregate": 3,
        "AccountHourlyAggregate": 4, "AccountProjectDailyAggregate": 5, "AccountSessionInfo": 6,
        "AccountUsageArchive": 7, "AlertRule": 8, "ClaudeCodeMeta": 9, "DailyAggregate": 10,
        "EngineEvalOutcome": 11, "ExtraUsageSample": 12, "ForecastModelOutcome": 13,
        "Heartbeat": 14, "HourlyAggregate": 15, "JSONLFileCursor": 16, "PredictionSnapshot": 17,
        "PriceRecord": 18, "ProjectBudget": 19, "ProjectCollection": 20,
        "ProjectDailyAggregate": 21, "ProjectMeta": 22, "ProjectPathAlias": 23,
        "ProjectPathProbe": 24, "RateLimitSample": 25, "SessionInfo": 26, "SpendMeterFit": 27,
        "TokenLaneMeta": 28, "TokenSample": 29, "UsageLimitSample": 30,
        "Z001LiveMeterOutcome": 31, "Z002AccountPlanEvent": 32, "Z003PriceCatalogSnapshot": 33,
    ]

    /// `Z_NAME → Z_ENT` of a fresh on-disk store with this build's schema.
    func numbering() throws -> [String: Int] {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("entity-numbering-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("pacer.sqlite")
        do { _ = try PacerStore.makeModelContainer(at: url) }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        // Core Data's own history entities sit at 16000+ and are not ours.
        guard sqlite3_prepare_v2(db, "SELECT Z_NAME, Z_ENT FROM Z_PRIMARYKEY WHERE Z_ENT < 16000",
                                 -1, &stmt, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_finalize(stmt) }
        var out: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            out[String(cString: sqlite3_column_text(stmt, 0))] = Int(sqlite3_column_int(stmt, 1))
        }
        return out
    }

    @Test("every shipped entity keeps its number")
    func shippedEntitiesKeepTheirNumbers() throws {
        let now = try numbering()
        for (name, number) in Self.shipped.sorted(by: { $0.value < $1.value }) {
            #expect(now[name] == number, """
                \(name) is entity \(now[name].map(String.init) ?? "gone"), shipped as \(number): \
                every row of its table, and every history change naming it, would be rewritten \
                on each user's first launch. Name new models Z<NNN><Name> so they sort last; \
                never remove or rename a shipped one without a migration plan (#387).
                """)
        }
    }

    /// The `Z<NNN>` sequence number of a model name, if it has one.
    static func sequence(of name: String) -> Int? {
        let digits = name.dropFirst().prefix(3)
        guard name.first == "Z", digits.count == 3, digits.allSatisfy(\.isNumber),
              name.dropFirst(4).first?.isUppercase == true else { return nil }
        return Int(digits)
    }

    @Test("a model added since the last release is named to sort after all the others")
    func newModelsSortLast() throws {
        let now = try numbering()
        let added = now.keys.filter { Self.shipped[$0] == nil }.sorted()
        // A new name must also come after every SHIPPED sequence number and
        // entity number: `Z002Foo` beside a shipped `Z002AccountPlanEvent`, or a
        // `Z000Foo`, sorts among the shipped models and renumbers the ones
        // after it, which no check on the new models alone would see.
        let highestShippedSequence = Self.shipped.keys.compactMap(Self.sequence(of:)).max() ?? 0
        let highestShippedEntity = Self.shipped.values.max() ?? 0
        var sequence: [Int] = []
        for name in added {
            let n = Self.sequence(of: name)
            #expect(n != nil,
                    "\(name): a new model is named Z<three-digit sequence><Name>, e.g. Z001LiveMeterOutcome")
            if let n {
                sequence.append(n)
                #expect(n > highestShippedSequence,
                        "\(name): sequence \(n) is not after the highest shipped one (\(highestShippedSequence))")
            }
            #expect((now[name] ?? 0) > highestShippedEntity,
                    "\(name) is entity \(now[name] ?? 0), among the shipped ones (up to \(highestShippedEntity))")
        }
        #expect(Set(sequence).count == sequence.count, "two new models share a sequence number: \(added)")
    }

    @Test("the sequence check reads Z<NNN> names, and only those")
    func sequenceParsing() {
        #expect(Self.sequence(of: "Z003PriceCatalogSnapshot") == 3)
        #expect(Self.sequence(of: "Z000Foo") == 0)
        #expect(Self.sequence(of: "ZZ01Foo") == nil)
        #expect(Self.sequence(of: "Z001foo") == nil)
        #expect(Self.sequence(of: "TokenSample") == nil)
    }
}
