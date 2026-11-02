import Foundation

/// The two things outside the app's SDK that send to Sentry, built by hand:
/// `pacer feedback` (the CLI must not start the SDK) and the crash reports the
/// app forwards for the widget and the CLI (`CrashReportForwarder`).
///
/// An envelope is newline-separated JSON: a header, then item header + payload
/// pairs. Spec: develop.sentry.dev/sdk/data-model/envelopes. The DSN's public
/// key is the only credential, and it is public by design (it ships in the app).
public enum SentryEnvelope {

    public struct DSN: Sendable, Equatable {
        public let key: String
        public let host: String
        public let projectId: String

        /// `https://<key>@<host>/<projectId>`
        public init?(_ dsn: String) {
            guard let url = URL(string: dsn), let key = url.user, let host = url.host,
                  !url.lastPathComponent.isEmpty, url.lastPathComponent != "/" else { return nil }
            self.key = key; self.host = host; self.projectId = url.lastPathComponent
        }

        public var envelopeURL: URL { URL(string: "https://\(host)/api/\(projectId)/envelope/")! }

        public var authHeader: String {
            "Sentry sentry_version=7, sentry_key=\(key), sentry_client=pacer/1"
        }
    }

    /// A user feedback item. `message` is scrubbed and capped at Sentry's 4096
    /// code points. Optional context goes in tags (our own enumerable values).
    public static func feedback(message: String, release: String?, environment: String,
                                tags: [String: String] = [:], installId: String? = nil,
                                home: String = NSHomeDirectory(), now: Date = Date()) -> Data? {
        let text = String(TelemetryScrubber.scrub(message, home: home).prefix(4096))
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var payload: [String: Any] = [
            "event_id": id, "timestamp": now.timeIntervalSince1970, "platform": "cocoa",
            "environment": environment, "tags": tags,
            "contexts": ["feedback": ["message": text, "source": "cli"]],
        ]
        if let release { payload["release"] = release }
        if let installId { payload["user"] = ["id": installId] }
        return envelope(eventId: id, type: "feedback", payload: payload)
    }

    /// An error event (already built, e.g. by `CrashReportForwarder`).
    public static func event(_ eventJSON: Data) -> Data? {
        guard let obj = try? JSONSerialization.jsonObject(with: eventJSON) as? [String: Any],
              let id = obj["event_id"] as? String else { return nil }
        return envelope(eventId: id, type: "event", payload: obj)
    }

    private static func envelope(eventId: String, type: String, payload: [String: Any]) -> Data? {
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let header = try? JSONSerialization.data(withJSONObject: ["event_id": eventId]),
              let item = try? JSONSerialization.data(withJSONObject: ["type": type, "length": body.count])
        else { return nil }
        var out = Data()
        for part in [header, item, body] { out.append(part); out.append(0x0A) }
        return out
    }

    public static func request(_ envelope: Data, dsn: DSN, timeout: TimeInterval = 3) -> URLRequest {
        var r = URLRequest(url: dsn.envelopeURL, timeoutInterval: timeout)
        r.httpMethod = "POST"
        r.setValue("application/x-sentry-envelope", forHTTPHeaderField: "Content-Type")
        r.setValue(dsn.authHeader, forHTTPHeaderField: "X-Sentry-Auth")
        r.httpBody = envelope
        return r
    }
}
