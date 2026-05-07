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
        configurations: config
    )
}

private func writeFixture(_ json: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("stats-cache-\(UUID().uuidString).json")
    try Data(json.utf8).write(to: url)
    return url
}

@Test func probeReadsVersion3Fixture() throws {
    let url = try writeFixture("""
    {
      "version": 3,
      "lastComputedDate": "2026-04-30",
      "totalMessages": 42,
      "dailyActivity": []
    }
    """)
    defer { try? FileManager.default.removeItem(at: url) }

    let probe = StatsCacheProbe(fileURL: url)
    let result = try probe.probe()
    #expect(result.version == 3)
    #expect(result.versionRecognized == true)
    #expect(result.lastComputedDate == "2026-04-30")
    #expect(result.totalMessages == 42)
}

@Test func probeMarksUnknownVersionUnrecognized() throws {
    let url = try writeFixture("""
    {
      "version": 99,
      "lastComputedDate": "2026-04-30",
      "totalMessages": 7
    }
    """)
    defer { try? FileManager.default.removeItem(at: url) }

    let probe = StatsCacheProbe(fileURL: url)
    let result = try probe.probe()
    #expect(result.version == 99)
    // Critical: we still surface what we can, but mark recognized=false
    // so the debug view warns instead of pretending we know what the
    // values mean. Mirrors the reference-impl Go ref's "unsupported
    // stats-cache version N" log path.
    #expect(result.versionRecognized == false)
}

@Test func probeThrowsOnMissingFile() {
    let probe = StatsCacheProbe(fileURL: URL(fileURLWithPath: "/no/such/path/stats-cache.json"))
    #expect(throws: StatsCacheProbe.ProbeError.self) {
        try probe.probe()
    }
}

@Test func probeThrowsOnMalformedJSON() throws {
    let url = try writeFixture("not actually json")
    defer { try? FileManager.default.removeItem(at: url) }
    let probe = StatsCacheProbe(fileURL: url)
    #expect(throws: StatsCacheProbe.ProbeError.self) {
        try probe.probe()
    }
}

@Test func probeHandlesMissingOptionalFields() throws {
    // version-only fixture: lastComputedDate and totalMessages absent.
    // Should not throw — we surface what's present and mark the rest nil.
    let url = try writeFixture("""
    { "version": 3 }
    """)
    defer { try? FileManager.default.removeItem(at: url) }

    let probe = StatsCacheProbe(fileURL: url)
    let result = try probe.probe()
    #expect(result.version == 3)
    #expect(result.lastComputedDate == nil)
    #expect(result.totalMessages == nil)
}

@MainActor
@Test func probeAndStoreWritesMetaKeys() throws {
    let url = try writeFixture("""
    {
      "version": 3,
      "lastComputedDate": "2026-04-30",
      "totalMessages": 1000
    }
    """)
    defer { try? FileManager.default.removeItem(at: url) }

    let container = try makeInMemoryContainer()
    let context = ModelContext(container)

    let probe = StatsCacheProbe(fileURL: url)
    _ = try probe.probeAndStore(in: context)

    let metas = try context.fetch(FetchDescriptor<ClaudeCodeMeta>())
    let byKey = Dictionary(uniqueKeysWithValues: metas.map { ($0.key, $0.value) })
    #expect(byKey[ClaudeCodeMetaKey.statsCacheVersion] == "3")
    #expect(byKey[ClaudeCodeMetaKey.statsCacheLastComputedDate] == "2026-04-30")
    #expect(byKey[ClaudeCodeMetaKey.statsCacheTotalMessages] == "1000")
}

@MainActor
@Test func probeAndStoreUpsertsOnRepeat() throws {
    // First probe writes "3", second probe with different value
    // overwrites the row (no duplicate row).
    let urlA = try writeFixture("""
    { "version": 3, "lastComputedDate": "2026-04-30", "totalMessages": 100 }
    """)
    let urlB = try writeFixture("""
    { "version": 3, "lastComputedDate": "2026-05-01", "totalMessages": 250 }
    """)
    defer {
        try? FileManager.default.removeItem(at: urlA)
        try? FileManager.default.removeItem(at: urlB)
    }

    let container = try makeInMemoryContainer()
    let context = ModelContext(container)

    _ = try StatsCacheProbe(fileURL: urlA).probeAndStore(in: context)
    _ = try StatsCacheProbe(fileURL: urlB).probeAndStore(in: context)

    let metas = try context.fetch(FetchDescriptor<ClaudeCodeMeta>())
    // Three keys, not six.
    #expect(metas.count == 3)
    let byKey = Dictionary(uniqueKeysWithValues: metas.map { ($0.key, $0.value) })
    #expect(byKey[ClaudeCodeMetaKey.statsCacheLastComputedDate] == "2026-05-01")
    #expect(byKey[ClaudeCodeMetaKey.statsCacheTotalMessages] == "250")
}
