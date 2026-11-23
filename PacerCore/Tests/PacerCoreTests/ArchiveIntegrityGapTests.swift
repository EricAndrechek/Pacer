import Foundation
import Testing
@testable import PacerCore

/// What a failed archive integrity check sends (#433): the direction of each
/// gap and its order of magnitude, never a count.
@Suite("Archive integrity gap")
struct ArchiveIntegrityGapTests {

    @Test("an archive short of rows and output says under, with each gap's magnitude")
    func archiveUnder() {
        let keys = ArchiveIntegrityGap.counterKeys(
            archivedRows: 1_168_990, storedRows: 1_169_063,
            archivedOutput: 512_000_000, storedOutput: 512_004_321,
            sampleRows: 1_169_063)
        #expect(keys == [
            "data.archive_integrity.rows.under.e1",
            "data.archive_integrity.output.under.e3",
            "data.archive_integrity.rollup_rows.equal",
        ])
    }

    @Test("an archive holding what the store no longer does says over")
    func archiveOver() {
        // Same rows, more output: a store row lowered after it was archived.
        let keys = ArchiveIntegrityGap.counterKeys(
            archivedRows: 200, storedRows: 200,
            archivedOutput: 9_500, storedOutput: 8_000, sampleRows: 200)
        #expect(keys == [
            "data.archive_integrity.rows.equal",
            "data.archive_integrity.output.over.e3",
            "data.archive_integrity.rollup_rows.equal",
        ])
    }

    @Test("a rollup that disagrees with its own samples is told apart from the archive")
    func rollupOff() {
        // The archive matches the samples; the rollup counts 3 turns too many.
        let keys = ArchiveIntegrityGap.counterKeys(
            archivedRows: 1_000, storedRows: 1_003,
            archivedOutput: 50_000, storedOutput: 50_000, sampleRows: 1_000)
        #expect(keys.last == "data.archive_integrity.rollup_rows.over.e0")
        // Not counted (the count failed): no key for it.
        let without = ArchiveIntegrityGap.counterKeys(
            archivedRows: 1_000, storedRows: 1_003,
            archivedOutput: 50_000, storedOutput: 50_000, sampleRows: nil)
        #expect(without.count == 2)
    }

    @Test("keys carry no number but a magnitude")
    func noCounts() {
        let keys = ArchiveIntegrityGap.counterKeys(
            archivedRows: 123_456, storedRows: 7, archivedOutput: 0,
            storedOutput: 98_765_432, sampleRows: 7)
        #expect(keys == [
            "data.archive_integrity.rows.over.e5",
            "data.archive_integrity.output.under.e7",
            "data.archive_integrity.rollup_rows.equal",
        ])
        for key in keys {
            #expect(!key.contains("123") && !key.contains("987"))
        }
    }
}
