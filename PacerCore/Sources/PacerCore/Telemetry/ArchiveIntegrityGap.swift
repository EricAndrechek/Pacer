import Foundation

/// Which way, and by roughly how much, the raw archive disagrees with the
/// store when the hourly integrity check fails (#433).
///
/// The check-in carried only `data.archive_integrity.ok` / `.mismatch`, and one
/// Mac mismatched on every check for twelve days while its full reconcile
/// never converged. The reconcile appends store turns the archive lacks or
/// holds differently, so "never converges" has a few possible causes, and each
/// leaves a different shape:
/// - the archive short of rows or output the reconcile cannot match (turns
///   with no dedup key, which it leaves to the forward path): archive `under`;
/// - the archive holding what the store no longer does (a store row removed,
///   or its output lowered, after archiving; append-only can't follow):
///   archive `over`;
/// - the store's side being wrong rather than the archive: the check reads the
///   store through the hourly rollup, which the reconcile never reads, so a
///   rollup that disagrees with its own samples fails the check forever.
///   `rollup_rows` says whether it does. Not while a scan cycle is part-way
///   through: a bulk rebuild saves the samples before the rollups, so the
///   rollup reads short for a while. That check sends `rollup_rows.mid_scan`;
/// - the archive holding a copy of a turn the store has since rewritten at
///   equal output (a full re-read bringing pricing detail the row predated):
///   `rows` and `output` equal, and `input` or one of the cache keys not.
///   The likely reason that Mac sent `rows.equal` and `output.equal` on every
///   check from 0.8.2 on: the reconcile compared output only. It compares
///   every field the store rewrites now, and these keys name the one that
///   still differs, if any does.
///
/// Every key is our own enumerable words plus an order of magnitude
/// (`TelemetryBands.magnitude`): never a count.
public enum ArchiveIntegrityGap {

    public enum Direction: String, Sendable {
        /// The first side holds more than the second.
        case over
        case under
        case equal
    }

    public static let prefix = "data.archive_integrity."

    public static func direction(_ first: Int64, _ second: Int64) -> Direction {
        first > second ? .over : first < second ? .under : .equal
    }

    /// One key: `<prefix><what>.<direction>`, then `.e<magnitude>` of the gap
    /// unless the two agree.
    public static func key(_ what: String, _ first: Int64, _ second: Int64) -> String {
        let way = direction(first, second)
        let base = prefix + what + "." + way.rawValue
        guard way != .equal else { return base }
        let gap = first > second ? first - second : second - first
        return base + "." + TelemetryBands.magnitude(gap)
    }

    /// The token totals the check compares, for whole days before today:
    /// the archive's, or the store's read through its hourly rollup.
    public struct Sums: Equatable, Sendable {
        public var rows: Int64
        public var input: Int64
        public var output: Int64
        public var cacheRead: Int64
        public var cc5m: Int64
        public var cc1h: Int64

        public init(rows: Int64 = 0, input: Int64 = 0, output: Int64 = 0,
                    cacheRead: Int64 = 0, cc5m: Int64 = 0, cc1h: Int64 = 0) {
            self.rows = rows
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cc5m = cc5m
            self.cc1h = cc1h
        }
    }

    /// The counter keys for one failed check, one each:
    /// - `rows`: the archive's turns against the store's (the rollup's count),
    /// - `output`, `input`, `cache_read`, `cc5m`, `cc1h`: the archive's tokens
    ///   of that kind against the store's (`cc5m` and `cc1h` are the 5-minute
    ///   and 1-hour cache-creation tiers),
    /// - `rollup_rows`: the rollup's count against the store's own samples
    ///   for the same days, when they were counted; `rollup_rows.mid_scan`
    ///   instead when a scan cycle was part-way through.
    ///
    /// No rollup-against-samples key for tokens: summing the samples' tokens
    /// materializes every row before today, where their count is an index
    /// walk.
    public static func counterKeys(
        archived: Sums, stored: Sums, sampleRows: Int64?, midScan: Bool = false
    ) -> [String] {
        var keys = [
            key("rows", archived.rows, stored.rows),
            key("output", archived.output, stored.output),
            key("input", archived.input, stored.input),
            key("cache_read", archived.cacheRead, stored.cacheRead),
            key("cc5m", archived.cc5m, stored.cc5m),
            key("cc1h", archived.cc1h, stored.cc1h),
        ]
        if midScan {
            keys.append(prefix + "rollup_rows.mid_scan")
        } else if let sampleRows {
            keys.append(key("rollup_rows", stored.rows, sampleRows))
        }
        return keys
    }
}
