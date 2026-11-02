import Foundation
import Synchronization

/// "Have we seen this before, on this Mac?" for the format-drift signals: a
/// model id the pricing catalog does not know, a Claude Code version, a
/// `limits[]` kind the usage endpoint never sent before.
///
/// The point of those signals is to learn that Anthropic or Claude Code
/// changed something, once, from the first Mac that meets it. So each value is
/// reported the first time it is seen and then remembered in the app's
/// defaults, capped so a flood of junk cannot grow the store or the quota.
/// The hot path (a value seen already this launch) is one lock and a set
/// lookup; the callers that sit on a per-row path also skip repeats of the
/// previous value before calling in.
public enum FormatDrift {

    /// Remembered values across all kinds. Past this, new values are not
    /// reported at all: a Mac that has met 200 distinct values is not
    /// learning anything new for us.
    public static let capacity = 200

    private static let defaultsKey = "pacer.telemetry.formatDrift"
    private static let launchSeen = Mutex<Set<String>>([])

    /// True the first time `value` is seen for `kind` on this Mac, and
    /// remembers it. False for a repeat, a value that is not plain
    /// identifier-like text (it would be free text, which never leaves the
    /// Mac), and once the cap is reached.
    @discardableResult
    public static func firstSighting(
        _ kind: String, _ value: String, store: UserDefaults = PacerPreferences.store
    ) -> Bool {
        guard isReportable(value) else { return false }
        let entry = "\(kind)|\(value)"
        return launchSeen.withLock { seen in
            // The launch set is keyed per store only in tests, which pass a
            // fresh suite and reset it; the app has exactly one store.
            if seen.contains(entry) { return false }
            var saved = store.stringArray(forKey: defaultsKey) ?? []
            seen.insert(entry)
            guard !saved.contains(entry), saved.count < capacity else { return false }
            saved.append(entry)
            store.set(saved, forKey: defaultsKey)
            return true
        }
    }

    /// Forget the in-memory set (tests only: a new defaults suite is empty
    /// but the launch set would still remember).
    static func resetLaunchState() { launchSeen.withLock { $0.removeAll() } }

    /// Model ids, versions and endpoint kinds are short and made of letters,
    /// digits and `. _ - : + /`. Anything else (spaces, paths with user names,
    /// sentences) is refused.
    static func isReportable(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else { return false }
        return value.unicodeScalars.allSatisfy {
            ($0.value < 128 && (CharacterSet.alphanumerics.contains($0) || "._-:+/".unicodeScalars.contains($0)))
        } && !value.contains("..") && !value.hasPrefix("/")
    }

    /// A model id the price ledger has no price for, first sighting only.
    public static func noteUnknownModel(_ model: String) {
        if firstSighting("model", model) {
            Telemetry.count("format.unknown_model", attributes: ["model": .string(model)])
        }
    }

    /// A Claude Code version string read from a transcript line.
    public static func noteClaudeCodeVersion(_ version: String) {
        if firstSighting("cc_version", version) {
            Telemetry.count("format.claude_code_version", attributes: ["version": .string(version)])
        }
    }

    /// A usage-endpoint `limits[]` kind never seen on this Mac.
    public static func noteUsageEndpointKind(_ kind: String) {
        if firstSighting("limits_kind", kind) {
            Telemetry.count("format.usage_endpoint", attributes: ["kind": .string(kind), "change": .string("new_kind")])
        }
    }

    /// Latency bucket label used by main-thread stall and click metrics.
    public static func clickBucket(delaySeconds s: Double) -> String {
        switch s * 1000 {
        case ..<50: return "lt50"
        case ..<100: return "50_100"
        case ..<250: return "100_250"
        case ..<1000: return "250_1000"
        default: return "gt1000"
        }
    }
}
