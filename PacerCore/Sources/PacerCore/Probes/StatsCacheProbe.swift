import Foundation
import SwiftData

/// Reads `~/.claude/stats-cache.json` (Tier 4 in design.md) and mirrors
/// a small subset of its values into `ClaudeCodeMeta` for the debug
/// view to compare against Pacer's own JSONL-derived totals.
///
/// **This probe must NEVER feed user-facing aggregates.** Stats-cache
/// is lazy-written by Claude Code (lags by hours, sometimes a full
/// day) and has fewer categories than the JSONL data (no 5m/1h cache
/// split, no per-message timing). The reference-impl Go reference treats
/// it as an authoritative-on-modtime mirror; Pacer deliberately does
/// NOT — JSONL is the source of truth, this is sanity-check only.
///
/// We follow the reference-impl Go reference's version gate: only
/// `version == 3` is recognized. A different version means Claude Code
/// changed the format and our key list might be stale; we still write
/// the version field so the debug view can surface "your stats-cache
/// is on a newer/older format than we know how to parse" but skip the
/// other fields.
public struct StatsCacheProbe: Sendable {

    /// Schema version we know how to parse. Mirror of
    /// `supportedStatsCacheVersion` in the reference-impl Go ref
    /// (`statscache.go:18`).
    public static let supportedVersion = 3

    public enum ProbeError: Error, Sendable {
        case fileMissing(URL)
        case unreadable(underlying: Error)
        case malformedJSON(underlying: Error)
    }

    public struct ProbeResult: Sendable {
        public let version: Int?
        public let lastComputedDate: String?
        public let totalMessages: Int?
        /// True when the file's `version` matched what we know how to
        /// parse. False (with version != nil) means stats-cache is on a
        /// different schema — we surface what we can but the debug view
        /// should warn.
        public let versionRecognized: Bool
    }

    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Convenience: probe the standard `~/.claude/stats-cache.json`
    /// location. Honors `HOME` so tests can swap it.
    public static func defaultLocation() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/stats-cache.json")
    }

    public func probe() throws -> ProbeResult {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // Distinguish "file not present" (expected on a fresh
            // install) from other read errors so the caller can be
            // quiet about the former.
            if (error as NSError).code == NSFileReadNoSuchFileError {
                throw ProbeError.fileMissing(fileURL)
            }
            throw ProbeError.unreadable(underlying: error)
        }

        let json: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ProbeError.malformedJSON(
                    underlying: NSError(domain: "PacerCore", code: 1)
                )
            }
            json = parsed
        } catch let error as ProbeError {
            throw error
        } catch {
            throw ProbeError.malformedJSON(underlying: error)
        }

        let version = json["version"] as? Int
        let lastComputed = json["lastComputedDate"] as? String
        // totalMessages was confirmed present on the user's actual
        // stats-cache (top-level int). A missing field is benign — we
        // store nil and the debug view shows "unavailable."
        let totalMessages = (json["totalMessages"] as? Int)
            ?? (json["totalMessages"] as? NSNumber).map(\.intValue)

        let recognized = (version == Self.supportedVersion)
        return ProbeResult(
            version: version,
            lastComputedDate: lastComputed,
            totalMessages: totalMessages,
            versionRecognized: recognized
        )
    }

    /// Run the probe and write its result into `ClaudeCodeMeta`. Used
    /// by the daemon at scan time. Returns the result so callers can
    /// log without re-reading the meta table.
    @MainActor
    public func probeAndStore(in context: ModelContext) throws -> ProbeResult {
        let result = try probe()
        try writeMeta(context: context, key: ClaudeCodeMetaKey.statsCacheVersion,
                      value: result.version.map(String.init) ?? "unknown")
        if let last = result.lastComputedDate {
            try writeMeta(context: context, key: ClaudeCodeMetaKey.statsCacheLastComputedDate, value: last)
        }
        if let count = result.totalMessages {
            try writeMeta(context: context, key: ClaudeCodeMetaKey.statsCacheTotalMessages, value: String(count))
        }
        return result
    }

    @MainActor
    private func writeMeta(context: ModelContext, key: String, value: String) throws {
        // Upsert via @Attribute(.unique) on key. We fetch-existing-first
        // and mutate rather than insert-and-let-uniqueness-overwrite —
        // SwiftData's behavior for unique-collision insertion isn't
        // reliable across versions, but explicit fetch-then-mutate is.
        let descriptor = FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key }
        )
        if let existing = try context.fetch(descriptor).first {
            existing.value = value
        } else {
            context.insert(ClaudeCodeMeta(key: key, value: value))
        }
        try context.save()
    }
}
