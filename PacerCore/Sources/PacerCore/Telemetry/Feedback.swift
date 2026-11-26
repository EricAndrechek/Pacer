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

    /// What the empty text box asks.
    public var prompt: String {
        switch self {
        case .idea: return "What would make Pacer better? A line is plenty."
        case .problem: return "What went wrong, and what did you expect?"
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
    /// The sidebar's row: a noun, like the rows around it, and no wider than
    /// they are, so the sidebar's minimum width does not grow for it.
    public static let button = "Feedback"
    public static let windowTitle = "Send Feedback"

    /// The window's heading, and under it what to send and who reads it.
    public static let heading = "Help shape Pacer"
    public static let subheading = "Ideas, problems, anything. The developer reads every one."
    public static let emailPrompt = "Email, if you'd like a reply"
    public static let attachFile = "Attach File…"
    /// Adds a picture of the dashboard, and names it once added.
    public static let attachWindow = "Include Pacer's Window"
    public static let windowAttachment = "Pacer's window"
    public static let attachWindowHelp = "A picture of the dashboard as it is now, costs and project names included."
    public static let attachWindowClosedHelp = "Open the dashboard to include a picture of it."
    public static let sentTitle = "Thank you"
    public static let sentDetail = "Sent to the developer."

    public static let tooLarge = "Over 8 MB in all. Remove a file, or open a GitHub issue."
    public static let badEmail = "That email doesn't look right."
    public static let tooLong = "Up to 10,000 characters."
    public static let capped = "Today's limit is reached."
    public static let filesLimit = "Up to 3 files, not empty: PNG, JPEG, text, JSON or QuickTime."

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
        // A PEM private key, the whole block.
        rule(#"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----"#),
        // `Authorization: Bearer …`, `Proxy-Authorization: Basic …`: only with a
        // scheme or a token after it, so "authorization: works on account 1"
        // stays as written.
        rule(#"(?i)\b((?:proxy-)?authorization)\s*[:=]\s*(?:(?:bearer|basic|token)\s+[^\s"',;]+|[A-Za-z0-9._~+/=-]{12,})"#,
             "$1: \(placeholder)"),
        // A bearer token anywhere else (`curl -H "Bearer …"`, a log line).
        rule(#"(?i)\b(bearer)\s+[A-Za-z0-9._~+/=-]{12,}"#, "$1 \(placeholder)"),
        // Anthropic API keys and OAuth tokens: `sk-ant-api03-…`, `sk-ant-oat01-…`.
        rule(#"\bsk-ant-[A-Za-z0-9_-]{8,}"#),
        // OpenAI and others of the family: `sk-…`, `sk-proj-…`.
        rule(#"\bsk-[A-Za-z0-9_-]{20,}"#),
        // GitHub tokens.
        rule(#"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})"#),
        // Sentry auth tokens (org `sntrys_`, user `sntryu_`).
        rule(#"\bsntry[su]_[A-Za-z0-9+/=_-]{20,}"#),
        // PostHog personal API keys. A project token (`phc_`) is public by
        // design and stays.
        rule(#"\bphx_[A-Za-z0-9]{20,}"#),
        // Slack tokens.
        rule(#"\bxox[abpr]-[A-Za-z0-9-]{10,}"#),
        // AWS access key ids.
        rule(#"\bAKIA[0-9A-Z]{16}\b"#),
        // Google API keys.
        rule(#"\bAIza[0-9A-Za-z_-]{35}"#),
        // JWTs: three base64url segments, the first a JSON header (`eyJ`).
        rule(#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*"#),
        // A value named as a secret: `ANTHROPIC_AUTH_TOKEN=…`, `?access_token=…`,
        // `"client_secret": "…"`, `password: …`. Values that are paths, URLs,
        // numbers or a public `phc_` token stay.
        rule(#"(?i)\b([A-Za-z0-9_.-]*(?:token|secret|passw(?:or)?d|api[_-]?key|access[_-]?key|private[_-]?key|credential)s?)(["']?\s*[:=]\s*["']?)([^\s"'&,;<>]{16,})"#,
             "$1$2\(placeholder)", accepts: { looksLikeSecretValue($0) }),
        // Any other long random token: 40+ base64 characters with upper and
        // lower case and several digits, including one right after `=` or `:`
        // (`token:…`, a query string). Hex ids (commits, hashes) are kept, and
        // so are paths: a run that starts at a `/` or follows `~` or `.` is a
        // path, not a token, and a URL's `//` starts with one.
        rule(#"(?<![A-Za-z0-9+/_~.-])[A-Za-z0-9+/_-]{40,}={0,2}(?![A-Za-z0-9+/=_-])"#,
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
        if run.hasPrefix("/") || isPublic(run) { return false }
        let core = run.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        if core.allSatisfy(\.isHexDigit) { return false }
        let digits = core.filter(\.isNumber).count
        return digits >= 4 && core.contains(where: \.isUppercase) && core.contains(where: \.isLowercase)
    }

    /// A PostHog project token is public by design (it only sends events),
    /// so a report can quote it.
    static func isPublic(_ token: String) -> Bool { token.hasPrefix("phc_") }

    /// The value part of a `name=value` match (after its `=` or `:` and any
    /// quote) is a secret unless it is a path, a URL, a public token, or has
    /// no letter or no digit (a count, a word).
    static func looksLikeSecretValue(_ match: String) -> Bool {
        guard let separator = match.firstIndex(where: { $0 == "=" || $0 == ":" }) else { return false }
        let value = match[match.index(after: separator)...]
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
        if value.hasPrefix("/") || value.hasPrefix("~") || value.contains("://") || isPublic(value) { return false }
        return value.contains(where: \.isLetter) && value.contains(where: \.isNumber)
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
    /// The endpoint's per-file cap, decoded (`site/worker/feedback.ts`).
    public static let maxAttachmentBytes = 8 * 1024 * 1024
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
    /// none empty, each of an accepted type and 8 MB or less, 8 MB in all once
    /// encoded. The window checks before sending, so it can say so instead of
    /// failing.
    public static func attachmentsFit(sizes: [Int]) -> Bool {
        sizes.count <= maxAttachments && sizes.allSatisfy { $0 > 0 && $0 <= maxAttachmentBytes }
            && sizes.reduce(0) { $0 + encodedSize($1) } <= maxEncodedAttachmentBytes
    }

    /// The endpoint's email shape (`EMAIL` in `site/worker/feedback.ts`),
    /// checked here so a typo is caught before the send, not by a 400.
    public static func isEmail(_ text: String) -> Bool {
        let shape = #"^[^\s@<>()\[\]\\,;:"]{1,64}@[^\s@<>()\[\]\\,;:"]+\.[^\s@<>()\[\]\\,;:"]{2,63}$"#
        return text.count <= 254 && text.range(of: shape, options: .regularExpression) != nil
    }

    /// A file name the endpoint takes (`FILENAME`): no separators, controls
    /// (C0, DEL, C1), zero-width or bidi marks (which can make `exe.txt` read as
    /// `txt.exe`), at most 128 characters with the extension kept.
    public static func cleanFilename(_ raw: String) -> String {
        let hidden: [ClosedRange<UInt32>] = [
            0x00...0x1F, 0x7F...0x9F, 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069, 0xFEFF...0xFEFF,
        ]
        let kept = raw.unicodeScalars.filter { scalar in
            scalar != "/" && scalar != "\\" && !hidden.contains { $0.contains(scalar.value) }
        }
        var name = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name == "." || name == ".." { name = "attachment" }
        guard name.count > 128 else { return name }
        let ext = (name as NSString).pathExtension
        let suffix = ext.isEmpty || ext.count > 16 ? "" : "." + ext
        let stem = suffix.isEmpty ? name : String(name.dropLast(suffix.count))
        return String(stem.prefix(128 - suffix.count)) + suffix
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
        guard let data = SafeJSON.data(body, options: [.sortedKeys]) else {
            throw CocoaError(.propertyListWriteInvalid)
        }
        return data
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

    /// One ephemeral session for the app's life: a session per send would
    /// never be invalidated, and each holds its delegate and caches until then.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 180
        return URLSession(configuration: config)
    }()

    public static let urlSession: Transport = { request in
        try await session.data(for: request)
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
