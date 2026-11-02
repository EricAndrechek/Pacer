import Foundation

/// Removes anything that identifies a person, a project or a credential from
/// text before it leaves the Mac in a crash report, metric or problem report.
///
/// **Why a scrubber and not just care at each call site**: the strings that
/// reach telemetry are mostly not ours. An `Error`'s description quotes the
/// file it failed on, a crash reason quotes a path, a person types their email
/// into a problem report, an agent pastes a command line with a token in it.
/// Every send path runs its text through here, so a path that slips through a
/// call site still never reaches Sentry.
///
/// What it replaces, in order (order matters: a home path contains the user
/// name the dashed form also contains):
/// - the home directory and any `/Users/<name>` path → `~`;
/// - Claude Code's dashed project folders (`-Users-<name>-Code-acme`, the
///   name `~/.claude/projects/` gives each project) → `<project>`;
/// - email addresses → `<email>`;
/// - credentials: `Bearer …`, `sk-ant-…`, `sk-…`, `ghp_…`, `gho_…`,
///   `github_pat_…`, and long hex or base64 runs → `<redacted>`.
///
/// It deliberately leaves UUIDs alone: crash reports need image UUIDs to be
/// symbolicated, and a random UUID identifies nothing.
public enum TelemetryScrubber {

    public static func scrub(_ text: String, home: String = NSHomeDirectory()) -> String {
        guard !text.isEmpty else { return text }
        var out = text
        if !home.isEmpty, home != "/" {
            out = out.replacingOccurrences(of: home, with: "~")
        }
        for (regex, replacement) in rules {
            out = regex.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out), withTemplate: replacement)
        }
        return out
    }

    /// Scrub every string value of a dictionary, recursively. Keys are kept:
    /// they are ours (attribute names), never user data.
    public static func scrub(_ values: [String: Any], home: String = NSHomeDirectory()) -> [String: Any] {
        values.mapValues { scrubValue($0, home: home) }
    }

    private static func scrubValue(_ value: Any, home: String) -> Any {
        switch value {
        case let s as String: return scrub(s, home: home)
        case let d as [String: Any]: return scrub(d, home: home)
        case let a as [Any]: return a.map { scrubValue($0, home: home) }
        default: return value
        }
    }

    // Built once, not per call.
    private static let rules: [(NSRegularExpression, String)] = [
        // Any other user's home, and ours when the caller passed a different one.
        (#"/Users/[^/\s:"']+"#, "~"),
        // `~/.claude/projects/-Users-alice-Code-acme/…` keeps `~/.claude/projects/`
        // but loses the encoded project path. Runs after the home rule, so the
        // `-Users-` here is the dashed form, which the home rule cannot see.
        (#"-Users-[A-Za-z0-9._-]+"#, "<project>"),
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<email>"),
        (#"(?i)bearer\s+[A-Za-z0-9._~+/=-]+"#, "<redacted>"),
        (#"\b(?:sk-ant-|sk-|ghp_|gho_|ghs_|github_pat_)[A-Za-z0-9_-]{8,}"#, "<redacted>"),
        // Long hex not shaped like a UUID (UUIDs have dashes, so a 32+ run of
        // pure hex is a key, a hash or a token).
        (#"\b[0-9a-fA-F]{32,}\b"#, "<redacted>"),
        // Long base64-ish runs (tokens, keys). 40+ so ordinary words and
        // identifiers survive.
        (#"[A-Za-z0-9+/_-]{40,}={0,2}"#, "<redacted>"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
}
