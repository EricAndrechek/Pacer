import Foundation

/// A project rollup row split by model: for each model, all five token parts
/// and the cost of each (`CostBreakdown`), stored in the row's
/// `modelBreakdownJSON` and read back here.
///
/// Every other rollup keeps the five parts; the project rollups used to keep
/// only input + output tokens and a cost total per model, so a project's By
/// model card could show neither its models' real token counts nor what each
/// part cost. They now carry the whole split, summed per sample alongside the
/// row's own columns, so a row's models add up to the row.
///
/// ## Encoding
///
/// A JSON object keyed by model, each value `{"t": [5 ints], "c": [5 doubles]}`:
/// the token counts, then the cost of each, both in `TokenBreakdown`'s field
/// order — input, output, cache read, 5m write, 1h write — spelled out in
/// `Wire` below rather than taken from `CostComponent`'s drawing order, which
/// is free to change. Positional arrays rather than named fields because the
/// table holds a row per project per day per account, each with a few models:
/// the names would be most of the bytes. Keys are sorted so a bucket's bytes
/// depend only on its values. Doubles round-trip exactly through
/// `JSONEncoder`, so a decoded split is the one that was summed.
public enum ProjectModelBreakdowns {

    /// One model's share on the wire.
    private struct Wire: Codable {
        /// Tokens: input, output, cache read, 5m write, 1h write.
        var t: [Int64]
        /// The cost of each, in the same order.
        var c: [Double]

        init(_ b: CostBreakdown) {
            t = [b.tokens.inputTokens, b.tokens.outputTokens, b.tokens.cacheReadTokens,
                 b.tokens.cacheCreation5mTokens, b.tokens.cacheCreation1hTokens]
            c = [b.cost.input, b.cost.output, b.cost.cacheRead,
                 b.cost.cacheWrite5m, b.cost.cacheWrite1h]
        }

        /// Nil unless both arrays carry exactly the five parts.
        var breakdown: CostBreakdown? {
            guard t.count == 5, c.count == 5 else { return nil }
            return CostBreakdown(
                cost: CostComponents(
                    input: c[0], output: c[1], cacheRead: c[2],
                    cacheWrite5m: c[3], cacheWrite1h: c[4]),
                tokens: TokenBreakdown(
                    inputTokens: t[0], outputTokens: t[1], cacheReadTokens: t[2],
                    cacheCreation5mTokens: t[3], cacheCreation1hTokens: t[4]))
        }
    }

    /// The stored form of `models`.
    public static func encode(_ models: [String: CostBreakdown]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(models.mapValues(Wire.init))) ?? Data()
    }

    /// The split stored in `data`. No data is no models; nil means the bytes
    /// are not a split (malformed, or a model without all five parts), which
    /// the incremental path treats as "rebuild this bucket from its samples".
    public static func decode(_ data: Data?) -> [String: CostBreakdown]? {
        decode(data, using: JSONDecoder())
    }

    static func decode(_ data: Data?, using decoder: JSONDecoder) -> [String: CostBreakdown]? {
        guard let data, !data.isEmpty else { return [:] }
        guard let wire = try? decoder.decode([String: Wire].self, from: data) else { return nil }
        var out: [String: CostBreakdown] = [:]
        out.reserveCapacity(wire.count)
        for (model, w) in wire {
            guard let b = w.breakdown else { return nil }
            out[model] = b
        }
        return out
    }

    /// Every row's split summed by model: a project's (or a day's, or a
    /// collection's) models over whatever rows are passed. Decodes each row
    /// once with one decoder. Rows that do not decode contribute nothing,
    /// the same as a row with no models.
    public static func sum(_ rows: [any ProjectDailyReadable]) -> [String: CostBreakdown] {
        let decoder = JSONDecoder()
        var out: [String: CostBreakdown] = [:]
        for row in rows {
            guard let models = decode(row.modelBreakdownJSON, using: decoder) else { continue }
            for (model, b) in models { out[model, default: .zero] += b }
        }
        return out
    }
}

public extension ProjectDailyReadable {
    /// This row split by model: each model's five token parts and the cost
    /// of each. Its models' tokens sum to the row's `tokens`, and their costs
    /// to its `costComponents` (to float rounding). Decodes on every read,
    /// so a view caches what it derives from it.
    var modelBreakdowns: [String: CostBreakdown] {
        ProjectModelBreakdowns.decode(modelBreakdownJSON) ?? [:]
    }
}
