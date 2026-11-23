import Foundation

/// Which way, and by roughly how much, the raw archive disagrees with the
/// store when the hourly integrity check fails (#433).
///
/// The check-in carried only `data.archive_integrity.ok` / `.mismatch`, and one
/// Mac mismatched on every check for twelve days while its full reconcile
/// never converged. The reconcile only appends store turns the archive lacks
/// or holds with less output, so "never converges" has a few possible causes,
/// and each leaves a different shape:
/// - the archive short of rows or output the reconcile cannot match (turns
///   with no dedup key, which it leaves to the forward path): archive `under`;
/// - the archive holding what the store no longer does (a store row removed,
///   or its output lowered, after archiving; append-only can't follow):
///   archive `over`;
/// - the store's side being wrong rather than the archive: the check reads the
///   store through the hourly rollup, which the reconcile never reads, so a
///   rollup that disagrees with its own samples fails the check forever.
///   `rollup_rows` says whether it does.
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

    /// The counter keys for one failed check, one each:
    /// - `rows`: the archive's turns against the store's (the rollup's count),
    /// - `output`: the archive's output tokens against the store's,
    /// - `rollup_rows`: the rollup's count against the store's own samples
    ///   for the same days, when they were counted.
    public static func counterKeys(
        archivedRows: Int64, storedRows: Int64,
        archivedOutput: Int64, storedOutput: Int64,
        sampleRows: Int64?
    ) -> [String] {
        var keys = [
            key("rows", archivedRows, storedRows),
            key("output", archivedOutput, storedOutput),
        ]
        if let sampleRows { keys.append(key("rollup_rows", storedRows, sampleRows)) }
        return keys
    }
}
