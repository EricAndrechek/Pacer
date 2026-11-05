import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// Two versions of one entity, the way a release changes a `@Model`: the same
/// entity name ("Gadget"), with an optional column added. SwiftData names the
/// entity after the class, so the enclosing enums are invisible to it.
enum GadgetSchemaV1 {
    @Model final class Gadget {
        var name: String
        init(name: String) { self.name = name }
    }
}

enum GadgetSchemaV2 {
    @Model final class Gadget {
        var name: String
        var weight: Int?
        init(name: String, weight: Int? = nil) { self.name = name; self.weight = weight }
    }
}

/// `PacerStore.prepareStore` and the metadata check the launch path and the
/// widget rely on (#376). Every store here is a fresh file in a temporary
/// directory: nothing opens the App Group store.
@Suite("Preparing the store off the main thread")
struct PacerStorePrepareTests {

    private func tempStoreURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pacer-prepare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(PacerStore.storeFileName)
    }

    /// Write `names` with the V1 schema and close the store again.
    private func writeV1Store(at url: URL, names: [String]) throws {
        let container = try PacerStore.makeModelContainer(at: url, types: [GadgetSchemaV1.Gadget.self])
        let context = ModelContext(container)
        for name in names { context.insert(GadgetSchemaV1.Gadget(name: name)) }
        try context.save()
    }

    @Test("a missing store is absent, and absent never holds the widget back")
    func missingStoreIsAbsent() throws {
        let url = try tempStoreURL()
        #expect(PacerStore.schemaState(at: url) == .absent)
    }

    /// The case that matters most: a false "needs migration" would leave every
    /// widget blank for good, and send every ordinary launch down the slow path.
    @Test("a store written by this build's full schema reads as current")
    func fullSchemaStoreIsCurrent() throws {
        let url = try tempStoreURL()
        do {
            let container = try PacerStore.makeModelContainer(at: url)
            let context = ModelContext(container)
            context.insert(Heartbeat(source: "test"))
            try context.save()
        }
        #expect(PacerStore.schemaState(at: url) == .current)
        // And the read-only open goes ahead.
        let reopened = try PacerStore.openWithoutMigrating(at: url)
        #expect(try ModelContext(reopened).fetchCount(FetchDescriptor<Heartbeat>()) == 1)
    }

    @Test("an added optional column reads as needing migration")
    func addedColumnNeedsMigration() throws {
        let url = try tempStoreURL()
        try writeV1Store(at: url, names: ["a"])
        #expect(PacerStore.schemaState(at: url, types: [GadgetSchemaV1.Gadget.self]) == .current)
        #expect(PacerStore.schemaState(at: url, types: [GadgetSchemaV2.Gadget.self]) == .needsMigration)
    }

    @Test("readers never migrate: they throw until the app has")
    func readersDoNotMigrate() throws {
        let url = try tempStoreURL()
        try writeV1Store(at: url, names: ["a", "b"])
        #expect(throws: PacerStoreError.self) {
            _ = try PacerStore.openWithoutMigrating(at: url, types: [GadgetSchemaV2.Gadget.self])
        }
        // The refused open left the store as it was.
        #expect(PacerStore.schemaState(at: url, types: [GadgetSchemaV2.Gadget.self]) == .needsMigration)

        _ = try PacerStore.prepareStore(at: url, types: [GadgetSchemaV2.Gadget.self])
        let reader = try PacerStore.openWithoutMigrating(at: url, types: [GadgetSchemaV2.Gadget.self])
        #expect(try ModelContext(reader).fetchCount(FetchDescriptor<GadgetSchemaV2.Gadget>()) == 2)
    }

    /// `@MainActor` because that is where the app uses the container: its
    /// `mainContext` backs every `@Query`.
    @Test("prepare migrates an older store off the main thread and keeps its rows")
    @MainActor
    func prepareMigratesOffMain() async throws {
        let url = try tempStoreURL()
        let names = (0..<500).map { "gadget-\($0)" }
        try writeV1Store(at: url, names: names)

        // Detached, as the app runs it: no actor, a background thread.
        let prepared = try await Task.detached {
            try PacerStore.prepareStore(at: url, types: [GadgetSchemaV2.Gadget.self])
        }.value
        #expect(!prepared.onMainThread)
        #expect(prepared.before == .needsMigration)
        #expect(prepared.after == .current)
        #expect(prepared.migrated)

        // The returned container is usable here, on the main thread rather
        // than the one that opened it, through the main context the app's
        // views read, and the migration kept every row.
        let context = prepared.container.mainContext
        let rows = try context.fetch(FetchDescriptor<GadgetSchemaV2.Gadget>())
        #expect(Set(rows.map(\.name)) == Set(names))
        #expect(rows.allSatisfy { $0.weight == nil })
        // The new column is writable.
        rows.first?.weight = 7
        try context.save()

        // A second prepare is an ordinary open.
        let again = try PacerStore.prepareStore(at: url, types: [GadgetSchemaV2.Gadget.self])
        #expect(again.before == .current)
        #expect(!again.migrated)
    }

    /// The real schema, migrating the way a release that adds a `@Model` type
    /// does: a store written without the newest types, opened with all of them.
    @Test("prepare migrates a store missing this build's newest model types")
    func prepareAddsEntities() async throws {
        let url = try tempStoreURL()
        let older = Array(PacerStore.allModelTypes.dropLast(2))
        do {
            let container = try PacerStore.makeModelContainer(at: url, types: older)
            let context = ModelContext(container)
            for i in 0..<20 { context.insert(Heartbeat(source: "row-\(i)")) }
            try context.save()
        }
        #expect(PacerStore.schemaState(at: url) == .needsMigration)

        let prepared = try await Task.detached { try PacerStore.prepareStore(at: url) }.value
        #expect(prepared.migrated)
        #expect(try ModelContext(prepared.container).fetchCount(FetchDescriptor<Heartbeat>()) == 20)
        #expect(PacerStore.schemaState(at: url) == .current)
    }

    @Test("a store that is not a store fails to prepare rather than reading as current")
    func garbageStoreFails() throws {
        let url = try tempStoreURL()
        try Data("not a database".utf8).write(to: url)
        #expect(PacerStore.schemaState(at: url) == .unknown)
        #expect(throws: (any Error).self) { _ = try PacerStore.prepareStore(at: url) }
    }

    /// #380: the failure is reported by domain and code. Its description names
    /// the store's path (the user's home), so no value may carry any of it.
    @Test("a failed prepare reports domain, code, before-state and time, nothing from the description")
    func failedPrepareReport() throws {
        let url = try tempStoreURL()
        try Data("not a database".utf8).write(to: url)
        let before = PacerStore.schemaState(at: url)
        var caught: Error?
        do { _ = try PacerStore.prepareStore(at: url) } catch { caught = error }
        let error = try #require(caught)

        let report = StorePrepareTelemetry.failure(error, before: before, elapsed: 1.2345)
        let ns = error as NSError
        #expect(report["error.domain"] == .string(ns.domain))
        #expect(report["error.code"] == .string(String(ns.code)))
        #expect(report["store.before"] == .string("unknown"))
        #expect(report["elapsed_ms"] == .int(1235))
        let keys = Set(report.keys)
        let allowed: Set<String> = ["error.domain", "error.code", "error.underlying_domain",
                                    "error.underlying_code", "store.before", "elapsed_ms"]
        #expect(keys.isSubset(of: allowed))
        for value in report.values {
            guard case .string(let s) = value else { continue }
            #expect(!s.contains(url.deletingLastPathComponent().lastPathComponent))
            #expect(!s.contains("/"))
            #expect(s != error.localizedDescription)
        }
    }
}
