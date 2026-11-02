import Foundation

/// Turns a macOS crash report (`~/Library/Logs/DiagnosticReports/*.ips`) for
/// one of Pacer's processes into a Sentry native event, so the app can report
/// crashes of the processes that cannot report themselves.
///
/// **Why**: the widget extension has no network and a tight memory budget, and
/// the `pacer` CLI is run constantly by agents and must stay a fast offline
/// process, so neither runs the Sentry SDK. But macOS writes a crash report
/// for every crashing process, and the app (not sandboxed) can read them. The
/// app also catches its own crashes the SDK never saw (a kill by the system,
/// a crash before the SDK started).
///
/// **Why a hand-built event, not Sentry's Apple crash report attachment**:
/// tested 2026-11-02 against the real project. The attachment route accepts
/// the file but does not parse the JSON `.ips` format (no stack trace). A
/// native event with `debug_meta.images` (image UUID + load address) and
/// absolute frame addresses is symbolicated server-side against Apple's
/// symbols and our uploaded dSYMs. See docs/telemetry-plan.md.
///
/// Pure: no file system, no network. The app lists, reads and sends.
public enum CrashReportForwarder {

    /// Process names whose crashes Pacer reports. `pacer` is the CLI.
    public static let processes: Set<String> = ["Pacer", "PacerWidgets", "pacer"]

    public struct Report: Sendable, Equatable {
        public let incidentId: String
        public let processName: String
        public let appVersion: String
        public let buildVersion: String
        public let captureTime: Date?
        /// The Sentry event, already scrubbed. JSON-serializable.
        public let eventJSON: Data
    }

    /// Nil when the text is not a crash report for one of `processes`, or is
    /// malformed (a report macOS is still writing, a hand edit).
    public static func report(fromIPS text: String, home: String = NSHomeDirectory(),
                              release: (_ version: String, _ build: String) -> String?,
                              environment: String) -> Report? {
        guard let split = text.firstIndex(of: "\n") else { return nil }
        guard let header = json(text[..<split]), let body = json(text[text.index(after: split)...])
        else { return nil }
        let name = (body["procName"] as? String) ?? (header["app_name"] as? String) ?? ""
        guard processes.contains(name) else { return nil }
        guard let images = body["usedImages"] as? [[String: Any]],
              let threads = body["threads"] as? [[String: Any]],
              let faulting = body["faultingThread"] as? Int, threads.indices.contains(faulting)
        else { return nil }

        let incident = (header["incident_id"] as? String) ?? (body["incident"] as? String) ?? UUID().uuidString
        let version = (header["app_version"] as? String) ?? ""
        let build = (header["build_version"] as? String) ?? ""
        let capture = (body["captureTime"] as? String).flatMap(parseCaptureTime)

        func frames(of thread: [String: Any]) -> [[String: Any]] {
            let raw = (thread["frames"] as? [[String: Any]]) ?? []
            return raw.compactMap { f -> [String: Any]? in
                guard let index = f["imageIndex"] as? Int, images.indices.contains(index),
                      let offset = (f["imageOffset"] as? NSNumber)?.uint64Value,
                      let base = (images[index]["base"] as? NSNumber)?.uint64Value
                else { return nil }
                var frame: [String: Any] = [
                    "instruction_addr": hex(base + offset),
                    "image_addr": hex(base),
                    "package": (images[index]["name"] as? String) ?? "",
                ]
                // macOS already resolved what it could; keeps frames readable
                // before (or without) uploaded dSYMs. Sentry replaces it with
                // its own symbolication where it has symbols.
                if let symbol = f["symbol"] as? String { frame["function"] = symbol }
                return frame
            }.reversed()  // Sentry wants the oldest frame first
        }

        let exception = (body["exception"] as? [String: Any]) ?? [:]
        let type = (exception["type"] as? String) ?? "Crash"
        let signal = (exception["signal"] as? String) ?? ""
        let termination = ((body["termination"] as? [String: Any])?["indicator"] as? String) ?? ""

        let debugImages: [[String: Any]] = images.compactMap { img in
            guard let uuid = img["uuid"] as? String, uuid != "00000000-0000-0000-0000-000000000000",
                  let base = (img["base"] as? NSNumber)?.uint64Value, base != 0 else { return nil }
            return ["type": "macho", "debug_id": uuid, "image_addr": hex(base),
                    "image_size": (img["size"] as? NSNumber)?.intValue ?? 0,
                    "code_file": (img["name"] as? String) ?? "",
                    "arch": (img["arch"] as? String) ?? "arm64"]
        }

        let os = (body["osVersion"] as? [String: Any]) ?? [:]
        let train = (os["train"] as? String) ?? ""
        var event: [String: Any] = [
            "timestamp": (capture ?? Date()).timeIntervalSince1970,
            "platform": "cocoa",
            "level": "fatal",
            "environment": environment,
            "tags": ["process": name, "source": "diagnostic-report"],
            "fingerprint": ["{{ default }}", name],
            "exception": ["values": [[
                "type": type,
                "value": [signal, termination].filter { !$0.isEmpty }.joined(separator: " · "),
                "mechanism": ["type": "mach", "handled": false,
                              "meta": ["signal": ["name": signal]]],
                "stacktrace": ["frames": frames(of: threads[faulting])],
            ] as [String: Any]]],
            "debug_meta": ["images": debugImages],
            "contexts": [
                "os": ["name": "macOS", "version": train.split(separator: " ").last.map(String.init) ?? "",
                       "build": (os["build"] as? String) ?? ""],
                "app": ["app_name": name, "app_version": version, "app_build": build],
            ],
        ]
        if let release = release(version, build) { event["release"] = release }
        var scrubbed = TelemetryScrubber.scrub(event, home: home)
        // Added after scrubbing: an event id is 32 hex characters, exactly the
        // shape the scrubber removes as a token, and Sentry rejects the whole
        // envelope without it (HTTP 400, found on a real forward 2026-11-02).
        scrubbed["event_id"] = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        guard let data = try? JSONSerialization.data(withJSONObject: scrubbed) else { return nil }
        return Report(incidentId: incident, processName: name, appVersion: version,
                      buildVersion: build, captureTime: capture, eventJSON: data)
    }

    /// Crash report file names start with the process name and a dash.
    /// Lets the app skip reading the hundreds of system reports.
    public static func isCandidate(fileName: String) -> Bool {
        guard fileName.hasSuffix(".ips") else { return false }
        return processes.contains { fileName.hasPrefix($0 + "-") }
    }

    private static func json<S: StringProtocol>(_ text: S) -> [String: Any]? {
        guard let data = String(text).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func hex(_ value: UInt64) -> String { "0x" + String(value, radix: 16) }

    // "2026-11-02 11:07:31.6421 -0500"
    private static func parseCaptureTime(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss.SSSS Z", "yyyy-MM-dd HH:mm:ss.SS Z", "yyyy-MM-dd HH:mm:ss Z"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}
