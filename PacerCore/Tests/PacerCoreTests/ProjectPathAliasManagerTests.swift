import Foundation
import SwiftData
import Testing
@testable import PacerCore

private func makeInMemoryContainer() throws -> ModelContainer {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(
        for: Heartbeat.self,
        TokenSample.self,
        DailyAggregate.self,
        ProjectDailyAggregate.self,
        RateLimitSample.self,
        SessionInfo.self,
        ClaudeCodeMeta.self,
        JSONLFileCursor.self,
        ProjectPathAlias.self,
        configurations: config
    )
}

@MainActor
@Suite struct ProjectPathAliasManagerTests {

    @Test func upsertInsertsNewAlias() throws {
        let container = try makeInMemoryContainer()
        let manager = ProjectPathAliasManager(context: ModelContext(container))

        try manager.upsert(sourcePath: "/old", canonicalPath: "/new")
        let snapshot = try manager.snapshot()
        #expect(snapshot == ["/old": "/new"])
    }

    @Test func upsertOverwritesExistingAlias() throws {
        let container = try makeInMemoryContainer()
        let manager = ProjectPathAliasManager(context: ModelContext(container))

        try manager.upsert(sourcePath: "/old", canonicalPath: "/new")
        try manager.upsert(sourcePath: "/old", canonicalPath: "/newer")
        let snapshot = try manager.snapshot()
        #expect(snapshot == ["/old": "/newer"])
    }

    @Test func upsertRejectsSelfAlias() {
        let container = try! makeInMemoryContainer()
        let manager = ProjectPathAliasManager(context: ModelContext(container))

        #expect(throws: ProjectPathAliasManager.AliasError.selfAlias(path: "/same")) {
            try manager.upsert(sourcePath: "/same", canonicalPath: "/same")
        }
    }

    @Test func upsertRejectsEmptyPaths() {
        let container = try! makeInMemoryContainer()
        let manager = ProjectPathAliasManager(context: ModelContext(container))

        #expect(throws: ProjectPathAliasManager.AliasError.emptyPath) {
            try manager.upsert(sourcePath: "", canonicalPath: "/dest")
        }
        #expect(throws: ProjectPathAliasManager.AliasError.emptyPath) {
            try manager.upsert(sourcePath: "/source", canonicalPath: "   ")
        }
    }

    @Test func upsertRejectsImmediateCycle() throws {
        let container = try makeInMemoryContainer()
        let manager = ProjectPathAliasManager(context: ModelContext(container))

        try manager.upsert(sourcePath: "/A", canonicalPath: "/B")
        // Now adding B → A would close the loop.
        #expect(throws: ProjectPathAliasManager.AliasError.self) {
            try manager.upsert(sourcePath: "/B", canonicalPath: "/A")
        }
    }

    @Test func upsertRejectsTransitiveCycle() throws {
        let container = try makeInMemoryContainer()
        let manager = ProjectPathAliasManager(context: ModelContext(container))

        try manager.upsert(sourcePath: "/A", canonicalPath: "/B")
        try manager.upsert(sourcePath: "/B", canonicalPath: "/C")
        // A→B→C exists; adding C→A would close a 3-node cycle.
        #expect(throws: ProjectPathAliasManager.AliasError.self) {
            try manager.upsert(sourcePath: "/C", canonicalPath: "/A")
        }
    }

    @Test func upsertAllowsChainExtension() throws {
        // A→B exists, then add B→C. This extends the chain to A→B→C
        // — legal, no cycle.
        let container = try makeInMemoryContainer()
        let manager = ProjectPathAliasManager(context: ModelContext(container))

        try manager.upsert(sourcePath: "/A", canonicalPath: "/B")
        try manager.upsert(sourcePath: "/B", canonicalPath: "/C")
        let snap = try manager.snapshot()
        #expect(snap["/A"] == "/B")
        #expect(snap["/B"] == "/C")
        #expect(
            ProjectPathCanonicalizer.canonicalize("/A", aliases: snap) == "/C"
        )
    }

    @Test func removeIsIdempotent() throws {
        let container = try makeInMemoryContainer()
        let manager = ProjectPathAliasManager(context: ModelContext(container))

        try manager.upsert(sourcePath: "/old", canonicalPath: "/new")
        try manager.remove(sourcePath: "/old")
        #expect(try manager.snapshot().isEmpty)
        // Second remove is a no-op, not an error.
        try manager.remove(sourcePath: "/old")
        #expect(try manager.snapshot().isEmpty)
    }

    @Test func listSortedByRecency() async throws {
        let container = try makeInMemoryContainer()
        let manager = ProjectPathAliasManager(context: ModelContext(container))

        try manager.upsert(sourcePath: "/first", canonicalPath: "/dest")
        // Force a measurable gap so the sort order is stable.
        try await Task.sleep(nanoseconds: 1_000_000)
        try manager.upsert(sourcePath: "/second", canonicalPath: "/dest")

        let rows = try manager.listSortedByRecency()
        #expect(rows.count == 2)
        #expect(rows.first?.sourcePath == "/second")
    }

    @Test func fingerprintStableForSameMap() {
        let a = ScanCoordinator.fingerprint(aliases: [
            "/a": "/b",
            "/c": "/d",
        ])
        let b = ScanCoordinator.fingerprint(aliases: [
            "/c": "/d",
            "/a": "/b",
        ])
        // Same content, different insertion order → same fingerprint.
        #expect(a == b)
    }

    @Test func fingerprintDifferentForDifferentMap() {
        #expect(
            ScanCoordinator.fingerprint(aliases: ["/a": "/b"])
            != ScanCoordinator.fingerprint(aliases: ["/a": "/c"])
        )
        #expect(
            ScanCoordinator.fingerprint(aliases: [:])
            != ScanCoordinator.fingerprint(aliases: ["/a": "/b"])
        )
    }
}
