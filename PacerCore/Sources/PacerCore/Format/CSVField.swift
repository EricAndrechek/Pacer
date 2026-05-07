import Foundation

/// Pure-function CSV field utilities so the App-side exporter can lean
/// on tested helpers rather than re-implementing escaping inline. Lives
/// in PacerCore because (a) it's reusable from any future export
/// surface (widgets, daemon dump, IPC) and (b) PacerCore is where our
/// test target lives.
public enum CSVField {

    /// Escape a single field per RFC 4180:
    ///   - If it contains a comma, double-quote, or newline, wrap it in
    ///     double-quotes and double up any internal quotes.
    ///   - Otherwise, return it unchanged.
    /// Empty strings stay empty (not `""`); CSV consumers treat them
    /// as null/absent.
    public static func escape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    /// Format USD as a fixed-precision decimal. 6 decimals matches
    /// ccusage's JSON output and avoids dropping pennies on per-day
    /// rollups before users open the file.
    public static func formatUSD(_ usd: Double) -> String {
        String(format: "%.6f", usd)
    }

    /// Build a CSV row from already-escaped or scalar values. Adds the
    /// terminating newline (LF, not CRLF — RFC 4180 prefers CRLF but
    /// every modern tool reads either, and LF keeps things consistent
    /// with macOS conventions).
    public static func row(_ fields: [String]) -> String {
        fields.joined(separator: ",") + "\n"
    }
}
