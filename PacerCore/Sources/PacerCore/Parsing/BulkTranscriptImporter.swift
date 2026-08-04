import Foundation

/// A faster way to parse *all* transcripts at once, injected rather than
/// imported.
///
/// The only implementation is DuckDB-backed and lives in the app target,
/// because the widget extension links PacerCore and must never pull in a
/// ~26 MB analytical engine for a chart it renders from rollups. Rather than
/// let that dependency leak downwards, PacerCore states the shape it wants
/// and takes whatever the app hands it — so the widget passes nothing, tests
/// pass a stub, and `ScanCoordinator` keeps exactly one code path either way.
///
/// This is deliberately **not** a replacement for `JSONLScanner`. The scanner
/// is FSEvents-hinted and resumes from per-file byte offsets, so a live cycle
/// touches only the bytes that changed (33-80 ms, ~0% idle CPU). A bulk
/// importer re-reads whole files and only wins when we genuinely want all of
/// them: a first launch, or re-deriving history after a parsing rule changes.
/// Measured on a 1,697-file corpus, that case is 74.8 s through the line
/// parser versus 12.4 s through DuckDB.
public protocol BulkTranscriptImporter: Sendable {
    /// Parse every `*.jsonl` under `roots`.
    ///
    /// Implementations must return entries **in ascending timestamp order**
    /// (the rollups' pending-sample lists and the session recomputer both
    /// assume arrival order) and must apply the same acceptance rules as
    /// `JSONLLineParser` — assistant turns only, no `<synthetic>` model,
    /// parseable timestamp, and the legacy summed-cache-creation fallback.
    func importAll(roots: [URL], aliases: [String: String]) throws -> BulkImportResult
}

public struct BulkImportResult: Sendable {
    /// Accepted entries, ascending by timestamp. May already be deduplicated
    /// by the implementation — `SamplePersister` is idempotent either way.
    public var entries: [ParsedUsageEntry]
    /// What each file looked like when it was read, so the caller can seed
    /// the live scanner's cursors at that point. Without this the very next
    /// cycle re-reads every byte the import just consumed and the whole
    /// exercise saves nothing.
    public var fileMarks: [String: FileMark]
    public var seconds: Double

    public init(entries: [ParsedUsageEntry], fileMarks: [String: FileMark], seconds: Double) {
        self.entries = entries
        self.fileMarks = fileMarks
        self.seconds = seconds
    }

    public struct FileMark: Sendable {
        public var size: Int64
        public var mtime: Date

        public init(size: Int64, mtime: Date) {
            self.size = size
            self.mtime = mtime
        }
    }
}
