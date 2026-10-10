import Foundation
import PacerCore

/// One sample from Pacer's `/metrics`: a name, its labels, and the value as
/// the server wrote it.
///
/// The raw text is kept beside the parsed number because `json` prints several
/// fields exactly as Pacer sent them, which is what `pace.sh` did, and a
/// reformatted `6.3000000000000007` would be a different answer to anyone
/// diffing the two.
struct PaceMetricPoint: Equatable, Sendable {
    let name: String
    let labels: [String: String]
    let raw: String

    var value: Double { Double(raw) ?? 0 }
    func label(_ key: String) -> String { labels[key] ?? "" }

    /// A point Pacer built in this process, rendered the way `/metrics`
    /// renders it, so the store and the API read identically.
    init(_ metric: PacerMetric) {
        name = metric.name
        labels = Dictionary(metric.labels, uniquingKeysWith: { first, _ in first })
        raw = PacerMetrics.renderValue(metric.value)
    }

    init(name: String, labels: [String: String], raw: String) {
        self.name = name
        self.labels = labels
        self.raw = raw
    }
}

/// Reads the Prometheus text exposition Pacer serves at `/metrics`.
///
/// Only as general as Pacer's own renderer (`PacerMetrics.prometheusText`):
/// `name{label="value",…} number` lines, `#` comments, and label values
/// escaped with `\\`, `\"` and `\n`. Anything else on a line is skipped rather
/// than thrown, as `pace.sh`'s awk did: a line Pacer added later must not stop
/// a gate.
enum PaceMetricsText {

    static func parse(_ text: String) -> [PaceMetricPoint] {
        var out: [PaceMetricPoint] = []
        for line in text.split(whereSeparator: \.isNewline) {
            if let point = parse(line: Substring(line)) { out.append(point) }
        }
        return out
    }

    static func parse(line: Substring) -> PaceMetricPoint? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let first = trimmed.first, first != "#" else { return nil }

        var labels: [String: String] = [:]
        var rest: Substring
        let name: Substring
        if let brace = trimmed.firstIndex(of: "{") {
            name = trimmed[..<brace]
            guard let (parsed, after) = parseLabels(trimmed[trimmed.index(after: brace)...]) else {
                return nil
            }
            labels = parsed
            rest = after
        } else {
            guard let space = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
            name = trimmed[..<space]
            rest = trimmed[space...]
        }
        // The value is the last field, which is what `$NF` read: a timestamp
        // after it is not something Pacer writes.
        guard let value = rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).last,
              !name.isEmpty else { return nil }
        return PaceMetricPoint(name: String(name), labels: labels, raw: String(value))
    }

    /// `key="value",…}` → the labels and whatever follows the closing brace.
    private static func parseLabels(_ text: Substring) -> ([String: String], Substring)? {
        var labels: [String: String] = [:]
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "}" { return (labels, text[text.index(after: i)...]) }
            if text[i] == "," || text[i] == " " { i = text.index(after: i); continue }
            guard let eq = text[i...].firstIndex(of: "=") else { return nil }
            let key = String(text[i..<eq])
            var j = text.index(after: eq)
            guard j < text.endIndex, text[j] == "\"" else { return nil }
            j = text.index(after: j)
            var value = ""
            while j < text.endIndex, text[j] != "\"" {
                if text[j] == "\\", text.index(after: j) < text.endIndex {
                    j = text.index(after: j)
                    switch text[j] {
                    case "n": value.append("\n")
                    default: value.append(text[j])
                    }
                } else {
                    value.append(text[j])
                }
                j = text.index(after: j)
            }
            guard j < text.endIndex else { return nil }
            labels[key] = value
            i = text.index(after: j)
        }
        return nil
    }
}
