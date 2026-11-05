import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// The on-disk dedup index is a cache in front of the app's most load-bearing
/// correctness rule, so these tests are mostly about it REFUSING to be used.
/// A wrong index double-counts turns or drops them; a missing one costs a
/// rebuild. Every ambiguous case must resolve toward the rebuild.
@Suite struct DedupIndexTests {

    private func index(_ pairs: [(String, Int64)], rowCount: Int? = nil,
                       watermark: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> DedupIndex {
        var entries: [DedupIndex.Key: Int64] = [:]
        for (k, v) in pairs { entries[DedupIndex.Key(k)] = v }
        return DedupIndex(entries: entries, rowCount: rowCount ?? pairs.count, watermark: watermark)
    }

    // MARK: - Hashing

    /// The digest must be stable across processes — Swift's `Hasher` reseeds
    /// per process, which is precisely why it can't back a persisted index.
    @Test func keyIsDeterministic() {
        let a = DedupIndex.Key("msg_011Cd4KXwUpfcmeBuiHGHQ:req_abc")
        let b = DedupIndex.Key("msg_011Cd4KXwUpfcmeBuiHGHQ:req_abc")
        #expect(a == b)
        #expect(a.hi != 0 || a.lo != 0)
    }

    @Test func differentKeysDiffer() {
        #expect(DedupIndex.Key("msg_a:req_1") != DedupIndex.Key("msg_a:req_2"))
        #expect(DedupIndex.Key("msg_a:req_1") != DedupIndex.Key("msg_b:req_1"))
    }

    /// Realistic key shapes must not collide in the 128-bit space. A collision
    /// would silently drop a billable turn.
    @Test func realisticKeysDoNotCollide() {
        var seen = Set<DedupIndex.Key>()
        for i in 0..<20_000 {
            seen.insert(DedupIndex.Key("msg_011Cd4KXwUpfcmeBuiHG\(i):req_\(i * 7)"))
        }
        #expect(seen.count == 20_000)
    }

    // MARK: - Round trip

    @Test func encodesAndDecodes() throws {
        let original = index([("msg_a:req_1", 289), ("msg_b:req_2", 4), ("msg_c:req_3", 0)])
        let restored = try #require(DedupIndex.decode(original.encoded()))
        #expect(restored.entries == original.entries)
        #expect(restored.rowCount == original.rowCount)
        #expect(Int(restored.watermark.timeIntervalSince1970)
                == Int(original.watermark.timeIntervalSince1970))
    }

    @Test func survivesAFileRoundTrip() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dedup-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = index([("msg_a:req_1", 289)])
        try original.write(to: url)
        #expect(DedupIndex.load(from: url)?.entries == original.entries)
    }

    // MARK: - Refusing to be used

    @Test func rejectsGarbage() {
        #expect(DedupIndex.decode(Data([0x00, 0x01, 0x02])) == nil)
        #expect(DedupIndex.decode(Data()) == nil)
    }

    /// A partial write — power loss, a killed process — must not half-load.
    @Test func rejectsATruncatedFile() {
        let data = index([("msg_a:req_1", 1), ("msg_b:req_2", 2)]).encoded()
        #expect(DedupIndex.decode(data.dropLast(8)) == nil)
    }

    /// Trailing junk means the file isn't what it claims either.
    @Test func rejectsAnOverlongFile() {
        var data = index([("msg_a:req_1", 1)]).encoded()
        data.append(contentsOf: [0xFF, 0xFF])
        #expect(DedupIndex.decode(data) == nil)
    }

    /// The check that stops double-counting: an index that doesn't account for
    /// every keyed row in the store is discarded, not patched up.
    @Test func rejectsAnIndexThatMissesRows() {
        let idx = index([("msg_a:req_1", 1), ("msg_b:req_2", 2)], rowCount: 2)
        #expect(idx.isValid(againstKeyedRowCount: 2))
        #expect(!idx.isValid(againstKeyedRowCount: 3))   // store grew behind our back
        #expect(!idx.isValid(againstKeyedRowCount: 1))   // store shrank — restore? swap?
    }

    @Test func missingFileIsSimplyNoIndex() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("definitely-absent-\(UUID().uuidString).bin")
        #expect(DedupIndex.load(from: url) == nil)
    }

    // MARK: - Written after a store walk

    /// An index rebuilt by walking the store accounts for every row it read,
    /// so its watermark is the newest of them. It used to stay at 1970 when
    /// nothing was inserted before the write, and the next launch then read
    /// the whole table back as "newer than the index".
    @ScanActor
    @Test func anIndexWrittenAfterAWalkCoversWhatTheWalkRead() throws {
        let container = try ModelContainer(
            for: TokenSample.self, DailyAggregate.self, HourlyAggregate.self,
            ProjectDailyAggregate.self, SessionInfo.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let scratch = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        for i in 0..<12 {
            let at = base.addingTimeInterval(Double((i * 5) % 12) * 3_600)
            scratch.insert(TokenSample(
                sampledAt: at, date: TokenSample.formatDate(at), model: "claude-opus-5",
                inputTokens: 1, outputTokens: Int64(i), cacheReadTokens: 0,
                cacheCreation5mTokens: 0, cacheCreation1hTokens: 0,
                dedupKey: "msg_\(i):req_\(i)", sessionId: "s"))
        }
        try scratch.save()
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dedup-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }

        let persister = try SamplePersister(context: ModelContext(container), indexURL: url)
        try persister.ensurePreloaded()
        persister.writeDedupIndexIfNeeded(force: true)

        let written = try #require(DedupIndex.load(from: url))
        #expect(written.rowCount == 12)
        #expect(written.watermark == base.addingTimeInterval(11 * 3_600))
    }
}
