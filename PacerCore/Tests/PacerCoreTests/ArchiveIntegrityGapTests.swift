import Foundation
import Testing
@testable import PacerCore

/// What a failed archive integrity check sends (#433): the direction of each
/// gap and its order of magnitude, never a count.
@Suite("Archive integrity gap")
struct ArchiveIntegrityGapTests {

    typealias Sums = ArchiveIntegrityGap.Sums

    /// Rows and output as given; input and cache equal on both sides, so
    /// their keys read `equal`.
    static func keys(archivedRows: Int64, storedRows: Int64,
                     archivedOutput: Int64, storedOutput: Int64,
                     sampleRows: Int64?, midScan: Bool = false) -> [String] {
        ArchiveIntegrityGap.counterKeys(
            archived: Sums(rows: archivedRows, input: 10, output: archivedOutput,
                           cacheRead: 20, cc5m: 30, cc1h: 40),
            stored: Sums(rows: storedRows, input: 10, output: storedOutput,
                         cacheRead: 20, cc5m: 30, cc1h: 40),
            sampleRows: sampleRows, midScan: midScan)
    }

    static let tokensEqual = [
        "data.archive_integrity.input.equal",
        "data.archive_integrity.cache_read.equal",
        "data.archive_integrity.cc5m.equal",
        "data.archive_integrity.cc1h.equal",
    ]

    @Test("an archive short of rows and output says under, with each gap's magnitude")
    func archiveUnder() {
        let keys = Self.keys(
            archivedRows: 1_168_990, storedRows: 1_169_063,
            archivedOutput: 512_000_000, storedOutput: 512_004_321,
            sampleRows: 1_169_063)
        #expect(keys == [
            "data.archive_integrity.rows.under.e1",
            "data.archive_integrity.output.under.e3",
        ] + Self.tokensEqual + [
            "data.archive_integrity.rollup_rows.equal",
        ])
    }

    @Test("an archive holding what the store no longer does says over")
    func archiveOver() {
        // Same rows, more output: a store row lowered after it was archived.
        let keys = Self.keys(
            archivedRows: 200, storedRows: 200,
            archivedOutput: 9_500, storedOutput: 8_000, sampleRows: 200)
        #expect(keys == [
            "data.archive_integrity.rows.equal",
            "data.archive_integrity.output.over.e3",
        ] + Self.tokensEqual + [
            "data.archive_integrity.rollup_rows.equal",
        ])
    }

    @Test("a rollup that disagrees with its own samples is told apart from the archive")
    func rollupOff() {
        // The archive matches the samples; the rollup counts 3 turns too many.
        let keys = Self.keys(
            archivedRows: 1_000, storedRows: 1_003,
            archivedOutput: 50_000, storedOutput: 50_000, sampleRows: 1_000)
        #expect(keys.last == "data.archive_integrity.rollup_rows.over.e0")
        // Not counted (the count failed): no key for it.
        let without = Self.keys(
            archivedRows: 1_000, storedRows: 1_003,
            archivedOutput: 50_000, storedOutput: 50_000, sampleRows: nil)
        #expect(without.count == 6)
    }

    @Test("mid-scan, the rollup is not compared with its samples: it may be catching up")
    func midScan() {
        // A bulk rebuild saved the samples; the rollup has not caught up.
        let keys = Self.keys(
            archivedRows: 1_000, storedRows: 900,
            archivedOutput: 50_000, storedOutput: 45_000, sampleRows: 1_000, midScan: true)
        #expect(keys == [
            "data.archive_integrity.rows.over.e2",
            "data.archive_integrity.output.over.e3",
        ] + Self.tokensEqual + [
            "data.archive_integrity.rollup_rows.mid_scan",
        ])
    }

    @Test("a mismatch only in input or cache names the field, with its direction and magnitude")
    func inputOrCacheOnly() {
        // The shape one Mac sent for weeks (#433): rows and output equal.
        let keys = ArchiveIntegrityGap.counterKeys(
            archived: Sums(rows: 10, input: 4_000, output: 700, cacheRead: 9_000_000, cc5m: 0, cc1h: 0),
            stored: Sums(rows: 10, input: 6_500, output: 700, cacheRead: 7_000_000, cc5m: 0, cc1h: 0),
            sampleRows: 10)
        #expect(keys == [
            "data.archive_integrity.rows.equal",
            "data.archive_integrity.output.equal",
            "data.archive_integrity.input.under.e3",        // 6,500 - 4,000 = 2,500
            "data.archive_integrity.cache_read.over.e6",    // 9M - 7M = 2,000,000
            "data.archive_integrity.cc5m.equal",
            "data.archive_integrity.cc1h.equal",
            "data.archive_integrity.rollup_rows.equal",
        ])
    }

    @Test("each token field reads its own pair of sums")
    func eachFieldItsOwnKey() {
        // A different gap, and a different way, per field, so a field wired
        // to the wrong sum shows as the wrong magnitude or direction.
        let keys = ArchiveIntegrityGap.counterKeys(
            archived: Sums(rows: 3, input: 105, output: 9, cacheRead: 1_000, cc5m: 0, cc1h: 4_000),
            stored: Sums(rows: 3, input: 100, output: 9, cacheRead: 1_050, cc5m: 500, cc1h: 0),
            sampleRows: nil)
        #expect(keys == [
            "data.archive_integrity.rows.equal",
            "data.archive_integrity.output.equal",
            "data.archive_integrity.input.over.e0",         // 5
            "data.archive_integrity.cache_read.under.e1",   // 50
            "data.archive_integrity.cc5m.under.e2",         // 500
            "data.archive_integrity.cc1h.over.e3",          // 4,000
        ])
    }

    @Test("keys carry no number but a magnitude")
    func noCounts() {
        let keys = Self.keys(
            archivedRows: 123_456, storedRows: 7, archivedOutput: 0,
            storedOutput: 98_765_432, sampleRows: 7)
        #expect(keys == [
            "data.archive_integrity.rows.over.e5",
            "data.archive_integrity.output.under.e7",
        ] + Self.tokensEqual + [
            "data.archive_integrity.rollup_rows.equal",
        ])
        for key in keys {
            #expect(!key.contains("123") && !key.contains("987"))
        }
    }
}
