import Foundation
import SwiftData

/// Generic key/value bag for daemon-internal state and debug probes.
/// Used for things that don't justify their own table: parser version,
/// last-full-scan timestamp, last-incremental-scan mtime cutoff, the
/// stats-cache.json mirror values for sanity checks, etc.
///
/// Values are always strings — callers serialize/deserialize as needed.
/// The whole point of this table is "don't migrate the schema for every
/// new tracked-state field," so giving values their own typed columns
/// would defeat that.
@Model
public final class ClaudeCodeMeta {
    @Attribute(.unique) public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// Well-known keys in `ClaudeCodeMeta`. Lives next to the model so
/// adding a key is a one-file change; readers/writers reference the
/// constant rather than typing the string. Anything not on this list
/// is allowed but should be added here when it stabilizes.
public enum ClaudeCodeMetaKey {
    /// Version of the parser+aggregation pipeline that produced the
    /// current `TokenSample`/`DailyAggregate` rows. Bumped when we ship
    /// a parsing change that would re-classify existing data, so the
    /// daemon knows to do a full re-scan on first launch after upgrade.
    public static let scanVersion = "scan_version"

    /// ISO-8601 timestamp of the last full historical scan (any root).
    /// Used for diagnostics; the actual decision to do a fresh full
    /// scan keys off `scanVersion`.
    public static let lastFullScanAt = "last_full_scan_at"

    /// ISO-8601 timestamp of the last successful incremental scan.
    /// Passed to `JSONLScanner` as the `mtimeAfter` cutoff so files
    /// untouched since aren't re-opened.
    public static let lastIncrementalScanAt = "last_incremental_scan_at"

    // MARK: - Stats-cache mirror (debug only — never feeds aggregates)
    //
    // These three are populated by `StatsCacheProbe` purely so a debug
    // view can render "what does Claude Code's own cache think today's
    // numbers are?" alongside our JSONL-derived totals. Read paths must
    // never touch them.

    public static let statsCacheVersion = "stats_cache_version"
    public static let statsCacheLastComputedDate = "stats_cache_last_computed_date"
    public static let statsCacheTotalMessages = "stats_cache_total_messages"
}
