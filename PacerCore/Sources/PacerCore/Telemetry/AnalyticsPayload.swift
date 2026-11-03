import Foundation

/// Turns `AnalyticsEvent`s into the JSON PostHog's `/batch/` endpoint takes,
/// and is the last place every string is cleaned before it leaves.
///
/// Pure and in PacerCore so the exact outgoing payload is unit-tested (a
/// fixture with fake ids, paths and emails must come out clean). The network
/// client that posts it lives in `App/Telemetry/` (AGENTS.md → Telemetry).
///
/// **Cleaning, in order**, for every property, `$set` and `$set_once` value:
/// 1. keys that name a forbidden kind of data (`email`, `path`, `prompt`,
///    `account_id`, `org_id`, `project`, ...) are dropped outright;
/// 2. strings go through `TelemetryScrubber` (paths, emails, credentials);
/// 3. UUIDs are replaced with `<id>`: account ids are org UUIDs, and the
///    scrubber keeps UUIDs for crash symbolication, which analytics never
///    needs. Only `distinct_id` and the event's own `uuid` are UUID-shaped.
/// 4. anything still shaped like a file path (`~/…`, `/Volumes/…`,
///    `/private/…`, …) becomes `<path>` (API routes like `/v1/snapshot` stay):
///    the scrubber keeps the part below the home folder for crash reports,
///    and that part names projects;
/// 5. strings are cut to 200 characters.
public enum AnalyticsPayload {

    /// Key segments (split on `.` and `_` boundaries as whole words) that
    /// are never sent, whatever the value.
    static let forbiddenKeys: Set<String> = [
        "email", "path", "paths", "prompt", "prompts", "account_id", "org_id", "organization_id",
        "project", "project_name", "projects", "cost_usd", "error_description", "message", "token_count",
    ]

    /// Properties every event carries: what PostHog groups by, and what
    /// makes a debug build filterable.
    public struct Context: Sendable, Equatable {
        public var distinctId: String
        public var appVersion: String
        public var appBuild: String
        public var buildConfig: String
        public var macOS: String
        public var libVersion: String

        public init(distinctId: String, appVersion: String, appBuild: String,
                    buildConfig: String, macOS: String, libVersion: String = "1") {
            self.distinctId = distinctId; self.appVersion = appVersion; self.appBuild = appBuild
            self.buildConfig = buildConfig; self.macOS = macOS; self.libVersion = libVersion
        }
    }

    /// One `/batch/` item.
    public static func item(_ event: AnalyticsEvent, context: Context,
                            home: String = NSHomeDirectory()) -> [String: Any] {
        var properties = clean(event.properties, home: home)
        properties["distinct_id"] = context.distinctId
        properties["$lib"] = "pacer-macos"
        properties["$lib_version"] = context.libVersion
        properties["$os"] = "macOS"
        properties["$os_version"] = context.macOS
        properties["$app_version"] = context.appVersion
        properties["$app_build"] = context.appBuild
        properties["build.config"] = context.buildConfig
        properties["$process_person_profile"] = true
        let set = clean(event.set, home: home)
        if !set.isEmpty { properties["$set"] = set }
        let setOnce = clean(event.setOnce, home: home)
        if !setOnce.isEmpty { properties["$set_once"] = setOnce }
        return [
            "event": event.name,
            "uuid": event.id.uuidString.lowercased(),
            "timestamp": timestamp(event.timestamp),
            "properties": properties,
        ]
    }

    /// The whole request body.
    public static func batch(_ items: [[String: Any]], apiKey: String) -> [String: Any] {
        ["api_key": apiKey, "batch": items]
    }

    // MARK: - Cleaning

    public static func clean(_ properties: Analytics.Properties,
                             home: String = NSHomeDirectory()) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in properties where !isForbidden(key) {
            if let v = json(value, home: home) { out[key] = v }
        }
        return out
    }

    static func isForbidden(_ key: String) -> Bool {
        let lower = key.lowercased()
        if forbiddenKeys.contains(lower) { return true }
        let segments = lower.split(separator: ".").map(String.init)
        return segments.contains { forbiddenKeys.contains($0) }
    }

    private static func json(_ value: Analytics.Value, home: String) -> Any? {
        switch value {
        case .string(let s): return cleanString(s, home: home)
        case .int(let i): return i
        case .double(let d): return d.isFinite ? d : nil
        case .bool(let b): return b
        case .list(let values): return values.compactMap { json($0, home: home) }
        case .object(let object):
            var out: [String: Any] = [:]
            for (k, v) in object where !isForbidden(k) {
                if let j = json(v, home: home) { out[k] = j }
            }
            return out
        }
    }

    public static func cleanString(_ s: String, home: String = NSHomeDirectory()) -> String {
        var out = TelemetryScrubber.scrub(s, home: home)
        out = uuid.stringByReplacingMatches(
            in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "<id>")
        out = path.stringByReplacingMatches(
            in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "<path>")
        return out.count > 200 ? String(out.prefix(200)) : out
    }

    private static let uuid = try! NSRegularExpression(
        pattern: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#)

    private static let path = try! NSRegularExpression(pattern: #"(?:~|\B/(?:Volumes|private|tmp|var|opt|Applications|Library))/[^\s"']*"#)

    nonisolated(unsafe) private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func timestamp(_ date: Date) -> String { stamp.string(from: date) }
}

/// The install id both Sentry and PostHog know this Mac by: Sentry's own
/// `INSTALLATION` file in its cache folder (`TelemetryController.cacheDirectory`,
/// in the App Group). The CLI's problem reports read the same file.
public enum AnalyticsIdentity {

    public static let fileName = "INSTALLATION"

    /// The id in `directory/INSTALLATION`, created in Sentry's own format (an
    /// uppercase UUID string, `SentryInstallation`) when it is missing, so
    /// Sentry adopts it if it starts later. Nil only when the folder cannot
    /// be written.
    public static func installId(in directory: URL) -> String? {
        let file = directory.appendingPathComponent(fileName)
        if let raw = try? String(contentsOf: file, encoding: .utf8) {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty { return id }
        }
        let id = UUID().uuidString
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(id.utf8).write(to: file, options: .withoutOverwriting)
            return id
        } catch {
            // Lost a race with Sentry writing it: read theirs.
            if let raw = try? String(contentsOf: file, encoding: .utf8) {
                let theirs = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !theirs.isEmpty { return theirs }
            }
            return nil
        }
    }
}
