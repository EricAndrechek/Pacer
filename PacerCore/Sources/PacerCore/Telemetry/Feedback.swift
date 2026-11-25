import Foundation
import UniformTypeIdentifiers

/// What someone is sending from the Send Feedback window. Goes with the report
/// (`FeedbackSubmission.kind`) and with `feedback_sent`, so ideas and problems
/// can be read apart.
public enum FeedbackKind: String, Sendable, CaseIterable, Identifiable {
    case idea, problem, other

    public var id: String { rawValue }

    /// The segmented control's label.
    public var title: String {
        switch self {
        case .idea: return "Idea"
        case .problem: return "Problem"
        case .other: return "Something else"
        }
    }

    /// The question above the text box.
    public var prompt: String {
        switch self {
        case .idea: return "What would make Pacer better?"
        case .problem: return "What went wrong?"
        case .other: return "What's on your mind?"
        }
    }

    /// The report as a GitHub issue body: its kind first. The endpoint takes
    /// the kind as its own field instead.
    public func report(_ message: String) -> String { "[\(title)] \(message)" }
}

/// The feedback strings, one place for every entry point.
public enum FeedbackCopy {
    /// The status menu, the Help menu and Settings → Privacy.
    public static let menuItem = "Send Feedback…"
    /// The sidebar footer's button.
    public static let button = "Send Feedback"
    public static let windowTitle = "Send Feedback"

    public static let tooLarge = "Over 8 MB in all. Remove a file, or open a GitHub issue."
    public static let tooLong = "Up to 10,000 characters."
    public static let capped = "Today's limit is reached."
    public static let filesLimit = "Up to 3 files: PNG, JPEG, text, JSON or QuickTime."

    /// What the window says when a send did not go through; nil when it did.
    public static func failure(_ outcome: FeedbackSender.Outcome) -> String? {
        switch outcome {
        case .sent: return nil
        case .refused(let reason): return "Couldn't send: \(reason)."
        case .rateLimited: return "Too many reports right now. Try again later."
        case .failed: return "Couldn't send."
        }
    }

    /// The note beside Send when the message had credentials in it.
    public static func removed(_ count: Int) -> String? {
        switch count {
        case ...0: return nil
        case 1: return "1 token removed"
        default: return "\(count) tokens removed"
        }
    }
}

/// Takes credentials out of a feedback message, and nothing else.
///
/// Why not `TelemetryScrubber`: a feedback message is what the person chose to
/// write and send, on their click, and the paths, emails and ids in it are
/// often the point of the report (the owner's decision, 2026-11-25). The full
/// scrubber turns those into `<path>` and `<email>`. What nobody means to
/// send is a secret pasted along with a log: an API key, an OAuth or bearer
/// token, an `Authorization:` header, a JWT or another long random token.
/// Those go; the window says how many.
public enum FeedbackRedactor {

    public static let placeholder = "<redacted>"

    public struct Result: Sendable, Equatable {
        public let text: String
        /// How many credentials were taken out.
        public let removed: Int
    }

    private struct Rule: @unchecked Sendable {
        let regex: NSRegularExpression
        /// The replacement, `$1`-style; most rules keep a label and drop the secret.
        let template: String
        /// Further say on a match the pattern alone cannot judge.
        let accepts: (@Sendable (String) -> Bool)?
    }

    private static func rule(_ pattern: String, _ template: String = placeholder,
                             options: NSRegularExpression.Options = [],
                             accepts: (@Sendable (String) -> Bool)? = nil) -> Rule {
        // The patterns are constants; a typo is a programming error caught by
        // the tests on the first run.
        Rule(regex: try! NSRegularExpression(pattern: pattern, options: options),
             template: template, accepts: accepts)
    }

    /// In order: specific shapes first, so a header line is one removal, not
    /// a header and then its token again.
    private static let rules: [Rule] = [
        // `Authorization: Bearer …`, `Proxy-Authorization: Basic …`, to the end of the line.
        rule(#"(?i)\b((?:proxy-)?authorization)\s*[:=]\s*[^\r\n]+"#, "$1: \(placeholder)"),
        // A bearer token anywhere else (`curl -H "Bearer …"`, a log line).
        rule(#"(?i)\b(bearer)\s+[A-Za-z0-9._~+/=-]{12,}"#, "$1 \(placeholder)"),
        // Anthropic API keys and OAuth tokens: `sk-ant-api03-…`, `sk-ant-oat01-…`.
        rule(#"\bsk-ant-[A-Za-z0-9_-]{8,}"#),
        // Other vendors' keys of the same family: `sk-…`, `sk-proj-…`.
        rule(#"\bsk-[A-Za-z0-9_-]{32,}"#),
        // GitHub tokens.
        rule(#"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})"#),
        // JWTs: three base64url segments, the first a JSON header (`eyJ`).
        rule(#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*"#),
        // Any other long random token: 40+ base64 characters with upper and
        // lower case and several digits. Hex ids (commits, hashes) are kept,
        // and so are paths: a run that starts at a `/` or follows `~`, `.` or
        // `:` (a URL) is a path, not a token.
        rule(#"(?<![A-Za-z0-9+/=_~.:-])[A-Za-z0-9+/_-]{40,}={0,2}(?![A-Za-z0-9+/=_-])"#,
             accepts: { looksRandom($0) }),
    ]

    public static func redact(_ text: String) -> Result {
        var current = text
        var removed = 0
        for rule in rules {
            let range = NSRange(current.startIndex..., in: current)
            let matches = rule.regex.matches(in: current, range: range)
            guard !matches.isEmpty else { continue }
            var output = ""
            var cursor = current.startIndex
            for match in matches {
                guard let whole = Range(match.range, in: current) else { continue }
                let found = String(current[whole])
                if let accepts = rule.accepts, !accepts(found) { continue }
                output += current[cursor..<whole.lowerBound]
                output += rule.regex.replacementString(for: match, in: current, offset: 0, template: rule.template)
                cursor = whole.upperBound
                removed += 1
            }
            output += current[cursor...]
            current = output
        }
        return Result(text: current, removed: removed)
    }

    /// A long run is a token when it reads like random data: both cases,
    /// four digits or more, and not all hex. A path that slipped through the
    /// pattern (`Sources/PacerCore/Update/UpdateStatusModel`) has words, not
    /// digits.
    static func looksRandom(_ run: String) -> Bool {
        if run.hasPrefix("/") { return false }
        let core = run.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        if core.allSatisfy(\.isHexDigit) { return false }
        let digits = core.filter(\.isNumber).count
        return digits >= 4 && core.contains(where: \.isUppercase) && core.contains(where: \.isLowercase)
    }
}

/// One Send Feedback report, as `POST https://pacer.andrechek.com/api/feedback`
/// takes it (`site/worker/feedback.ts`, which checks every field against a
/// fixed shape and answers 400 with a reason for anything else). The site
/// forwards it to Sentry user feedback, so a report goes the same way whatever
/// the crash-reports toggle says, and needs no GitHub account. The message
/// arrives already redacted (`FeedbackRedactor`).
public struct FeedbackSubmission: Sendable, Equatable {

    public struct Attachment: Sendable, Equatable {
        public var filename: String
        public var contentType: String
        public var data: Data

        public init(filename: String, contentType: String, data: Data) {
            self.filename = filename
            self.contentType = contentType
            self.data = data
        }
    }

    public static let endpoint = URL(string: "https://pacer.andrechek.com/api/feedback")!
    public static let maxAttachments = 3
    /// The endpoint's per-file cap, decoded.
    public static let maxAttachmentBytes = 10 * 1024 * 1024
    /// All attachments together, base64-encoded. Lower than the endpoint's
    /// body cap: the Worker runs on Cloudflare's free plan, about 10 ms of CPU
    /// a request, and a bigger body can fail there (error 1102).
    public static let maxEncodedAttachmentBytes = 8 * 1024 * 1024
    /// Unicode scalars, as the endpoint counts them.
    public static let maxMessageCharacters = 10_000

    /// The types the endpoint accepts. Anything else is refused, so the file
    /// picker offers only these (`contentType(forFileExtension:)`).
    public static let acceptedContentTypes: [String] = [
        "image/png", "image/jpeg", "text/plain", "application/json", "video/quicktime",
    ]

    public var kind: FeedbackKind
    public var message: String
    public var email: String?
    /// X.Y.Z: a release's version, or a dev build's last tag
    /// (`AppVersionLabel.reportVersion`).
    public var appVersion: String
    public var appBuild: String
    /// A dev build's `git describe` (`AppVersionLabel.reportDescribe`).
    public var devDescribe: String?
    /// "26.1".
    public var macOS: String
    /// The hardware model, `hw.model` ("Mac15,9").
    public var model: String
    public var locale: String?
    /// Only while the "Usage data" toggle is on: it links the report to the
    /// install's usage events.
    public var installId: String?
    public var attachments: [Attachment]

    public init(kind: FeedbackKind, message: String, email: String?, appVersion: String, appBuild: String,
                devDescribe: String?, macOS: String, model: String, locale: String?, installId: String?,
                attachments: [Attachment]) {
        self.kind = kind
        self.message = message
        let address = email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.email = address.isEmpty ? nil : address
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.devDescribe = devDescribe
        self.macOS = macOS
        self.model = model
        self.locale = locale.flatMap(Self.locale)
        self.installId = installId
        self.attachments = attachments
    }

    /// Base64's size for `bytes` bytes.
    public static func encodedSize(_ bytes: Int) -> Int { (bytes + 2) / 3 * 4 }

    /// Whether these attachments fit what the endpoint takes: three at most,
    /// each of an accepted type and 10 MB or less, 8 MB in all once encoded.
    /// The window checks before sending, so it can say so instead of failing.
    public static func attachmentsFit(sizes: [Int]) -> Bool {
        sizes.count <= maxAttachments && sizes.allSatisfy { $0 <= maxAttachmentBytes }
            && sizes.reduce(0) { $0 + encodedSize($1) } <= maxEncodedAttachmentBytes
    }

    public var attachmentsFit: Bool {
        Self.attachmentsFit(sizes: attachments.map(\.data.count))
            && attachments.allSatisfy { Self.acceptedContentTypes.contains($0.contentType) }
    }

    /// The accepted MIME type for a file, from its extension; nil when the
    /// endpoint would refuse it. JSON is asked before plain text, since a type
    /// can conform to both.
    public static func contentType(forFileExtension ext: String) -> String? {
        guard let type = UTType(filenameExtension: ext) else { return nil }
        let order: [(UTType, String)] = [
            (.png, "image/png"), (.jpeg, "image/jpeg"), (.json, "application/json"),
            (.quickTimeMovie, "video/quicktime"), (.plainText, "text/plain"),
        ]
        return order.first { type.conforms(to: $0.0) }?.1
    }

    /// `Locale.current.identifier` in the endpoint's shape: no `@calendar=…`
    /// or `@rg=…` keywords, else nothing.
    public static func locale(_ identifier: String) -> String? {
        let base = identifier.split(separator: "@", maxSplits: 1).first.map(String.init) ?? ""
        let shape = #"^[A-Za-z]{2,3}(?:[-_][0-9A-Za-z]{1,8}){0,5}$"#
        return base.range(of: shape, options: .regularExpression) != nil ? base : nil
    }

    /// The JSON body. Optional fields are left out rather than sent as null.
    public func jsonBody() throws -> Data {
        var body: [String: Any] = [
            "kind": kind.rawValue,
            "message": message,
            "appVersion": appVersion,
            "appBuild": appBuild,
            "macOS": macOS,
            "model": model,
            "attachments": attachments.map {
                ["filename": $0.filename, "contentType": $0.contentType, "base64": $0.data.base64EncodedString()]
            },
        ]
        if let email { body["email"] = email }
        if let devDescribe { body["devDescribe"] = devDescribe }
        if let locale { body["locale"] = locale }
        if let installId { body["installId"] = installId }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// `userAgent` must start `Pacer/`: the endpoint serves nothing else.
    public func request(userAgent: String) throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try jsonBody()
        return request
    }
}

/// Sends a `FeedbackSubmission`. The transport is injectable for tests.
public enum FeedbackSender {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// What the endpoint said (`site/worker/feedback.ts`).
    public enum Outcome: Sendable, Equatable {
        /// 2xx, `{ok: true}`: Sentry has it.
        case sent
        /// 400: a field the endpoint refused, with its short reason, which the
        /// person may be able to fix (an email that is not one).
        case refused(String)
        /// 429: Sentry is rate limiting reports. Later will work.
        case rateLimited
        /// Anything else (403, 413, 415, 502, 503) or no answer at all
        /// (offline, timed out): the GitHub issue is the way.
        case failed(status: Int?)
    }

    public static let urlSession: Transport = { request in
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 180
        return try await URLSession(configuration: config).data(for: request)
    }

    public static func send(_ submission: FeedbackSubmission, userAgent: String,
                            transport: Transport = urlSession) async -> Outcome {
        guard let request = try? submission.request(userAgent: userAgent) else { return .failed(status: nil) }
        do {
            let (data, response) = try await transport(request)
            guard let http = response as? HTTPURLResponse else { return .failed(status: nil) }
            return outcome(status: http.statusCode, body: data)
        } catch {
            return .failed(status: nil)
        }
    }

    static func outcome(status: Int, body: Data) -> Outcome {
        switch status {
        case 200..<300: return .sent
        case 429: return .rateLimited
        case 400:
            // `{ok: false, error}`; the reason is the endpoint's own fixed
            // wording, shortened in case it ever is not.
            let reason = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? String
            let short = reason.map { String($0.prefix(120)) }.flatMap { $0.isEmpty ? nil : $0 }
            return .refused(short ?? "the report was refused")
        default: return .failed(status: status)
        }
    }
}
