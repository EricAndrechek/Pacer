@preconcurrency import CoreData
import Foundation
import SQLite3
import SwiftData
import Testing
@testable import PacerCore

/// The release side of `make upgrade-matrix` (`bin/upgrade-matrix.sh`): a
/// store written by an OLDER release, made by that release's own code, so the
/// current tree can be shown to open it in one step however many releases it
/// skips (Sparkle installs the newest release directly, never the ones in
/// between).
///
/// The script copies this file, unchanged, into a worktree of each recent
/// release tag and builds it there beside that tag's DuckDB importer and
/// archive. So it is written against the OLDEST release the matrix covers
/// (0.8.0): `PacerStore.makeModelContainer(at:)`, `PacerStore.allModelTypes`,
/// `ScanCoordinator.runOnce()`, `ArchiveSync` and Core Data, nothing newer.
/// `make test` compiles it at HEAD too (disabled), which keeps it compiling.
///
/// Modes, `PACER_UPGRADE_MATRIX_MODE`:
///
///   produce  a NEW store at `PACER_UPGRADE_MATRIX_STORE` from the frozen tree
///            `PACER_UPGRADE_MATRIX_CLAUDE_DIR` (a directory holding
///            `projects/`): one full scan, as that release's first launch ran
///            it, through its DuckDB importer, then its raw archive at
///            `PACER_UPGRADE_MATRIX_ARCHIVE` (DuckDB build only). Prints the
///            TOTALS line `IngestHarness` prints.
///   seed     one row in every EMPTY entity of the store at
///            `PACER_UPGRADE_MATRIX_STORE`, through Core Data with this build's
///            model. A transcript ingest leaves accounts, limit samples,
///            forecasts and settings tables empty, and a migration that only
///            ever met empty tables proves nothing about one that has rows to
///            move (a new mandatory attribute without a default only fails
///            when a row exists).
///   schema   this build's managed object model, as text (entities, version
///            hashes, attributes with type, optionality and default, indexes,
///            uniqueness constraints), to `PACER_UPGRADE_MATRIX_OUT`. The
///            script diffs these release to release.
///
/// Never the live store: a path under `Group Containers` is refused.
@Suite("Upgrade matrix probe", .enabled(if: upgradeMatrixMode != nil), .serialized)
struct UpgradeMatrixProbe {

    static var env: [String: String] { ProcessInfo.processInfo.environment.filter { !$0.value.isEmpty } }

    #if canImport(CDuckDB)
    static func bulkImporter() -> BulkTranscriptImporter? { ArchiveImporter() }
    #else
    static func bulkImporter() -> BulkTranscriptImporter? { nil }
    #endif

    func log(_ s: String) { print("[matrix] \(s)") }

    @ScanActor
    @Test func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        switch upgradeMatrixMode {
        case "produce": try await produce()
        case "seed": try seed()
        case "schema": try schema()
        default: Issue.record("PACER_UPGRADE_MATRIX_MODE must be produce, seed or schema")
        }
    }

    static func storeURL() throws -> URL {
        let url = URL(fileURLWithPath: try #require(env["PACER_UPGRADE_MATRIX_STORE"]))
        try #require(!url.resolvingSymlinksInPath().path.contains("/Group Containers/"), "point it at a copy")
        return url
    }

    // MARK: - produce

    @ScanActor
    func produce() async throws {
        let env = Self.env
        let fm = FileManager.default
        let storeURL = try Self.storeURL()
        try #require(!fm.fileExists(atPath: storeURL.path), "produce writes a NEW store: \(storeURL.path)")
        let claudeDir = try #require(env["PACER_UPGRADE_MATRIX_CLAUDE_DIR"])
        try #require(fm.fileExists(atPath: claudeDir + "/projects"), "no projects/ under \(claudeDir)")
        let scratch = fm.temporaryDirectory.appendingPathComponent("pacer-matrix-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        // The bundled catalog and curated file (or a pinned catalog copy), so
        // the store does not depend on what the network said that day.
        let table = PricingTable()
        try await table.ensureLoaded(cacheURL: URL(fileURLWithPath: env["PACER_UPGRADE_MATRIX_CATALOG"]
            ?? scratch.appendingPathComponent("no-catalog.json").path))
        await SampleCostCache.reload(table, curatedCacheURL: scratch.appendingPathComponent("no-curated.json"))

        let began = Date()
        let container = try PacerStore.makeModelContainer(at: storeURL)
        let importer = Self.bulkImporter()
        log("ingest: \(importer == nil ? "line parser" : "DuckDB bulk importer")")
        let home = scratch.appendingPathComponent("home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let coordinator = ScanCoordinator(
            container: container,
            configuration: .init(costMode: .auto, watcherMode: .manual, probeStatsCache: false,
                                 bulkImporter: importer,
                                 desktopSessions: DesktopSessionDirectory(dataDirectories: [])),
            resolver: ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": claudeDir]),
            homeDirectory: home)
        let report = try await Self.runCycle(coordinator)
        log(String(format: "cycle: %@ in %.1f s, %d entries from %d files, inserted %d",
                   report.wasFullScan ? "full" : "incremental", report.durationSeconds,
                   report.scanProgress.entriesParsed, report.scanProgress.filesScanned,
                   report.persisterStats.inserted))

        #if canImport(CDuckDB)
        if let archive = env["PACER_UPGRADE_MATRIX_ARCHIVE"] {
            let url = URL(fileURLWithPath: archive)
            try #require(!url.resolvingSymlinksInPath().path.contains("/Group Containers/"), "an archive copy")
            ArchiveSync(container: container, archiveURL: url).syncNewTurns()
            log("archive: synced to \(url.lastPathComponent)")
        }
        #endif
        log(String(format: "produced in %.1f s", Date().timeIntervalSince(began)))
        log(try Self.totalsLine(storeURL))
    }

    /// One cycle off the actor, at a priority a busy build machine does not
    /// starve; the store it leaves does not depend on the priority.
    @ScanActor
    static func runCycle(_ coordinator: ScanCoordinator) async throws -> ScanCoordinator.ScanReport {
        let outcome: Result<ScanCoordinator.ScanReport, Error> = await withCheckedContinuation { done in
            Task.detached(priority: .userInitiated) {
                do { done.resume(returning: .success(try await coordinator.runOnce())) }
                catch { done.resume(returning: .failure(error)) }
            }
        }
        return try outcome.get()
    }

    /// `IngestHarness.Totals.line`, character for character, read the same way.
    static func totalsLine(_ store: URL) throws -> String {
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = """
            SELECT count(*), total(ZINPUTTOKENS), total(ZOUTPUTTOKENS), total(ZCACHEREADTOKENS),
                   total(ZCACHECREATION5MTOKENS), total(ZCACHECREATION1HTOKENS) FROM ZTOKENSAMPLE
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw CocoaError(.fileReadUnknown) }
        let v = (0..<6).map { Int64(sqlite3_column_double(stmt, Int32($0))) }
        return "TOTALS rows=\(v[0]) input=\(v[1]) output=\(v[2]) cacheRead=\(v[3]) cc5m=\(v[4]) cc1h=\(v[5]) "
            + "all=\(v[1] + v[2] + v[3] + v[4] + v[5])"
    }

    // MARK: - seed

    func seed() throws {
        let storeURL = try Self.storeURL()
        let model = try #require(NSManagedObjectModel.makeManagedObjectModel(for: PacerStore.allModelTypes))
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: storeURL)
        try #require(model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata),
                     "seed runs with the build that wrote the store")
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        // SwiftData opens its stores with history tracking; opening one
        // without it makes Core Data force the store read-only.
        _ = try coordinator.addPersistentStore(
            type: .sqlite, at: storeURL,
            options: [NSPersistentHistoryTrackingKey: true as NSNumber,
                      NSPersistentStoreRemoteChangeNotificationPostOptionKey: true as NSNumber])
        var seeded = 0, present = 0, failed: [String] = []
        for entity in model.entities.sorted(by: { ($0.name ?? "") < ($1.name ?? "") }) where !entity.isAbstract {
            let name = entity.name ?? "?"
            let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
            let outcome: String = context.performAndWait {
                do {
                    let count = try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: name))
                    if count > 0 { return "present \(count)" }
                    let row = NSManagedObject(entity: entity, insertInto: context)
                    for (key, attribute) in entity.attributesByName {
                        if let value = Self.seedValue(attribute) { row.setValue(value, forKey: key) }
                    }
                    try context.save()
                    return "seeded"
                } catch {
                    context.rollback()
                    return "FAILED \((error as NSError).domain) \((error as NSError).code)"
                }
            }
            switch outcome {
            case "seeded": seeded += 1
            case let o where o.hasPrefix("present"): present += 1
            default: failed.append(name)
            }
            log("seed \(name): \(outcome)")
        }
        log("seed: \(seeded) entities seeded, \(present) already had rows, \(failed.count) failed \(failed)")
        #expect(failed.isEmpty)
    }

    /// A value of the attribute's own type: every column gets data, so a
    /// migration that drops, retypes or loses one shows up in the compare.
    static func seedValue(_ attribute: NSAttributeDescription) -> Any? {
        if let composite = attribute as? NSCompositeAttributeDescription {
            var value: [String: Any] = [:]
            for element in composite.elements {
                if let v = seedValue(element) { value[element.name] = v }
            }
            return value
        }
        switch attribute.attributeType {
        case .integer16AttributeType: return NSNumber(value: Int16(7))
        case .integer32AttributeType: return NSNumber(value: Int32(7))
        case .integer64AttributeType: return NSNumber(value: Int64(7))
        case .decimalAttributeType: return NSDecimalNumber(string: "7.5")
        case .doubleAttributeType: return NSNumber(value: 7.5)
        case .floatAttributeType: return NSNumber(value: Float(7.5))
        case .stringAttributeType: return "seed-\(attribute.name)"
        case .booleanAttributeType: return NSNumber(value: true)
        case .dateAttributeType: return Date(timeIntervalSince1970: 1_790_000_000)
        case .binaryDataAttributeType: return Data("seed-\(attribute.name)".utf8)
        case .UUIDAttributeType: return UUID(uuidString: "00000000-0000-4000-8000-000000000007")
        case .URIAttributeType: return URL(string: "https://example.com/seed")
        default: return nil
        }
    }

    // MARK: - schema

    func schema() throws {
        let out = URL(fileURLWithPath: try #require(Self.env["PACER_UPGRADE_MATRIX_OUT"]))
        let model = try #require(NSManagedObjectModel.makeManagedObjectModel(for: PacerStore.allModelTypes))
        var lines: [String] = []
        for entity in model.entities.sorted(by: { ($0.name ?? "") < ($1.name ?? "") }) {
            let name = entity.name ?? "?"
            lines.append("entity \(name) hash=\(entity.versionHash.base64EncodedString())")
            for (key, attribute) in entity.attributesByName.sorted(by: { $0.key < $1.key }) {
                lines.append("  attr \(name).\(key) " + Self.describe(attribute))
            }
            for (key, relationship) in entity.relationshipsByName.sorted(by: { $0.key < $1.key }) {
                lines.append("  rel \(name).\(key) -> \(relationship.destinationEntity?.name ?? "?")"
                    + " optional=\(relationship.isOptional) toMany=\(relationship.isToMany)")
            }
            for index in entity.indexes.sorted(by: { $0.name < $1.name }) {
                let elements = index.elements.map { $0.propertyName ?? $0.property?.name ?? "?" }
                lines.append("  index \(name)(\(elements.joined(separator: ",")))")
            }
            let unique = entity.uniquenessConstraints
                .map { "(" + $0.map { "\($0)" }.joined(separator: ",") + ")" }.sorted()
            if !unique.isEmpty { lines.append("  unique \(name) \(unique.joined(separator: " "))") }
        }
        try (lines.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
        log("schema: \(model.entities.count) entities to \(out.path)")
    }

    static func describe(_ attribute: NSAttributeDescription) -> String {
        var parts = ["type=\(attribute.attributeType.rawValue)", "optional=\(attribute.isOptional)"]
        if let d = attribute.defaultValue { parts.append("default=\(d)") }
        if let c = attribute.attributeValueClassName { parts.append("class=\(c)") }
        if let t = attribute.valueTransformerName { parts.append("transformer=\(t)") }
        if let r = attribute.renamingIdentifier, r != attribute.name { parts.append("renamedFrom=\(r)") }
        if let composite = attribute as? NSCompositeAttributeDescription {
            parts.append("{" + composite.elements.sorted(by: { $0.name < $1.name })
                .map { "\($0.name): \(describe($0))" }.joined(separator: "; ") + "}")
        }
        return parts.joined(separator: " ")
    }
}

/// Outside the suite: a `@Suite` trait can't read its own type's members.
private var upgradeMatrixMode: String? {
    UpgradeMatrixProbe.env["PACER_UPGRADE_MATRIX_MODE"]
}
