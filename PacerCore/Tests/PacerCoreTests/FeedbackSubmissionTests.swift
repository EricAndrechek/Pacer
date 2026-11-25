import Foundation
import Testing
@testable import PacerCore

@Suite("Feedback redactor: credentials out, everything else kept")
struct FeedbackRedactorTests {

    // Fakes in the shape of the real thing; none is a live credential.
    static let apiKey = "sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-AbCdEfGhIjKlMnOpQrSt"
    static let oauth = "sk-ant-oat01-ZyXwVuTsRqPoNmLkJiHgFeDcBa9876543210abcdefghij"
    static let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
    static let randomToken = "Qm9vZ1hY3k2LmZ7aWxsYXJkcz8xOTk3VGhpc0lzQUxvbmdUb2tlbjQ1Njc4OTA"
    // Vendor-shaped fakes, built from pieces so no line of this file is itself
    // a credential-shaped string: GitHub's push protection refuses a commit
    // carrying one, fake or not.
    static let github = "ghp" + "_" + "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8"
    static let sentryOrg = "sntrys" + "_" + "eyJpYXQiOjE3MDAwMDAwMDAuMCwidXJsIjoiaHR0cHM6Ly9zZW50cnkuaW8ifQ==_AbCdEf0123456789"
    static let posthogPersonal = "phx" + "_" + "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"
    static let slackBot = ["xoxb", "123456789012", "1234567890123", "AbCdEfGhIjKlMnOpQrStUvWx"].joined(separator: "-")
    static let slackUser = ["xoxp", "123456789012", "1234567890123", "1234567890123",
                            "abcdef0123456789abcdef0123456789"].joined(separator: "-")
    static let awsKeyId = "AK" + "IA" + "IOSFODNN7EXAMPLE"
    static let awsSecret = "wJalrXUtnFEMI" + "/K7MDENG/" + "bPxRfiCYEXAMPLEKEY"
    static let google = "AI" + "za" + "SyD-9tSrke72PouQMnMX-a7eZSW0jkFMBWY"
    static let openai = "sk" + "-" + "proj-AbCdEfGhIjKlMnOpQrStUvWx0123456789"

    @Test("an Anthropic API key and an OAuth token are removed")
    func anthropic() {
        let out = FeedbackRedactor.redact("key \(Self.apiKey) and token \(Self.oauth) here")
        #expect(out.text == "key <redacted> and token <redacted> here")
        #expect(out.removed == 2)
    }

    @Test("an Authorization header loses its value and keeps its name")
    func authorizationHeader() {
        let out = FeedbackRedactor.redact("curl -v\nAuthorization: Bearer abcdefghijklmnop0123456789\nAccept: */*")
        #expect(out.text == "curl -v\nAuthorization: <redacted>\nAccept: */*")
        #expect(out.removed == 1)
        let basic = FeedbackRedactor.redact("proxy-authorization: Basic dXNlcjpwYXNzd29yZA==")
        #expect(basic.text == "proxy-authorization: <redacted>")
    }

    @Test("a bearer token elsewhere is removed; the word bearer in prose is not")
    func bearer() {
        let out = FeedbackRedactor.redact(#"-H "x: Bearer abcdefghijklmnop0123456789""#)
        #expect(out.text == #"-H "x: Bearer <redacted>""#)
        #expect(FeedbackRedactor.redact("I am the bearer of bad news").removed == 0)
    }

    @Test("a JWT and a long random token are removed")
    func jwtAndRandom() {
        #expect(FeedbackRedactor.redact("jwt \(Self.jwt)").text == "jwt <redacted>")
        let out = FeedbackRedactor.redact("got \(Self.randomToken) back")
        #expect(out.text == "got <redacted> back")
        #expect(out.removed == 1)
    }

    @Test("GitHub tokens are removed")
    func github() {
        let out = FeedbackRedactor.redact(Self.github)
        #expect(out.text == "<redacted>")
    }

    @Test("paths, emails, hex ids, UUIDs, URLs and plain prose are kept")
    func keeps() {
        let kept = [
            "/Users/alice/Code/acme-secret/Sources/PacerCore/Update/UpdateStatusModel2024.swift",
            "~/Library/Group Containers/YZXWMJ5VBY.com.ericandrechek.pacer/pacer.sqlite",
            "~/.claude/projects/-Users-alice-Code-acme-secret/0a1b2c3d.jsonl",
            "alice.smith@example.com",
            "c4bc89de1180fe83c60eeb25673caab894ec80d4",
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            "7f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b",
            "https://github.com/ericandrechek/Pacer/issues/new?title=Something1234LongerThanForty",
            "PacerCore/Sources/PacerCore/Update/UpdateStatusModel",
            "NSHostingControllerSizingOptionsStandardBoundsAndMore",
            "The 5-hour limit hit 100% at 14:05 on account 2 of 4, after 1,234,567 tokens.",
            "authorization failed",
            "authorization: works on account 1 but not 2",
            "max_tokens: 4096 and input_tokens=1234567890123456",
            "token_path=/Users/alice/.config/pacer/token-store.json",
            "oauth_callback_token_url=https://localhost:8080/callback/abc",
            "POSTHOG_PROJECT_TOKEN=phc_rCT9m6F6y7DwcDSJ5BgHpZECFyvpmsPoyUiLx5pa693A",
            "commit:c4bc89de1180fe83c60eeb25673caab894ec80d4",
            "TERM_SESSION_ID=w0t0p0:7F1E2D3C-4B5A-6978-8A9B-0C1D2E3F4A5B",
        ]
        for text in kept {
            let out = FeedbackRedactor.redact(text)
            #expect(out.text == text, "\(text)")
            #expect(out.removed == 0, "\(text)")
        }
    }

    @Test("a token right after = or : is removed")
    func afterEqualsOrColon() {
        for text in ["ANTHROPIC_AUTH_TOKEN=\(Self.randomToken)", "https://x.example/cb?access_token=\(Self.randomToken)&a=1",
                     "token:\(Self.randomToken)", "id:\(Self.randomToken)"] {
            let out = FeedbackRedactor.redact(text)
            #expect(out.removed == 1, "\(text)")
            #expect(!out.text.contains(Self.randomToken), "\(text)")
        }
        // A short secret is caught by its name.
        #expect(FeedbackRedactor.redact("password: hunter2hunter2hunter2").text == "password: <redacted>")
        #expect(FeedbackRedactor.redact(#""client_secret": "a1b2c3d4e5f6g7h8i9""#).text
                == #""client_secret": "<redacted>""#)
    }

    @Test("vendor keys by their prefix; a PostHog project token is public and stays")
    func vendorKeys() {
        let secrets = [
            Self.sentryOrg,
            "sntryu" + "_" + String(repeating: "a1b2c3d4", count: 8),
            Self.posthogPersonal,
            "gho" + "_" + "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8",
            "ghs" + "_" + "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8",
            "github" + "_pat_" + "11ABCDEFG0123456789_abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJ",
            Self.slackBot,
            Self.slackUser,
            Self.awsKeyId,
            Self.google,
            Self.openai,
            "sk" + "-" + "AbCdEfGhIjKlMnOpQrStUvWx0123456789AbCdEfGhIjKl",
        ]
        for secret in secrets {
            let out = FeedbackRedactor.redact("x \(secret) y")
            #expect(out.text == "x <redacted> y", "\(secret)")
            #expect(out.removed == 1, "\(secret)")
        }
        let project = "phc_rCT9m6F6y7DwcDSJ5BgHpZECFyvpmsPoyUiLx5pa693A"
        #expect(FeedbackRedactor.redact("token \(project)").text == "token \(project)")
    }

    @Test("a private key block goes whole")
    func privateKey() {
        let text = """
        before
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACBhYmNkZWZnaGlqa2xtbm9wcXJzdHV2d3h5ejAxMjM0NQAAAJg=
        -----END OPENSSH PRIVATE KEY-----
        after
        """
        let out = FeedbackRedactor.redact(text)
        #expect(out.text == "before\n<redacted>\nafter")
        #expect(out.removed == 1)
        #expect(FeedbackRedactor.redact("-----BEGIN RSA PRIVATE KEY-----\nMIIE\n-----END RSA PRIVATE KEY-----").removed == 1)
    }

    @Test("an env dump loses every secret and keeps everything else")
    func envDump() {
        let dump = """
        SHELL=/bin/zsh
        HOME=/Users/alice
        PATH=/opt/homebrew/bin:/usr/bin:/bin
        LANG=en_US.UTF-8
        EDITOR=vim
        CLAUDE_CONFIG_DIR=/Users/alice/.claude
        ANTHROPIC_API_KEY=\(Self.apiKey)
        ANTHROPIC_AUTH_TOKEN=\(Self.randomToken)
        CLAUDE_CODE_OAUTH_TOKEN=\(Self.oauth)
        GITHUB_TOKEN=\(Self.github)
        SENTRY_AUTH_TOKEN=\(Self.sentryOrg)
        POSTHOG_PERSONAL_API_KEY=\(Self.posthogPersonal)
        POSTHOG_PROJECT_TOKEN=phc_rCT9m6F6y7DwcDSJ5BgHpZECFyvpmsPoyUiLx5pa693A
        AWS_ACCESS_KEY_ID=\(Self.awsKeyId)
        AWS_SECRET_ACCESS_KEY=\(Self.awsSecret)
        SLACK_BOT_TOKEN=\(Self.slackBot)
        GOOGLE_API_KEY=\(Self.google)
        OPENAI_API_KEY=\(Self.openai)
        DATABASE_PASSWORD=Tr0ub4dor-3xyzabcdEF
        GIT_COMMIT=c4bc89de1180fe83c60eeb25673caab894ec80d4
        """
        let out = FeedbackRedactor.redact(dump)
        #expect(out.removed == 12)
        for kept in ["SHELL=/bin/zsh", "HOME=/Users/alice", "PATH=/opt/homebrew/bin:/usr/bin:/bin",
                     "LANG=en_US.UTF-8", "EDITOR=vim", "CLAUDE_CONFIG_DIR=/Users/alice/.claude",
                     "POSTHOG_PROJECT_TOKEN=phc_rCT9m6F6y7DwcDSJ5BgHpZECFyvpmsPoyUiLx5pa693A",
                     "GIT_COMMIT=c4bc89de1180fe83c60eeb25673caab894ec80d4"] {
            #expect(out.text.contains(kept), "\(kept)")
        }
        for gone in ["sk-ant", Self.randomToken, Self.github, Self.sentryOrg, Self.posthogPersonal, Self.awsKeyId,
                     Self.awsSecret, Self.slackBot, Self.google, Self.openai, "Tr0ub4dor"] {
            #expect(!out.text.contains(gone), "\(gone)")
        }
    }

    @Test("a report with a log in it keeps the log and loses the secret")
    func mixed() {
        let text = """
        It crashed when I opened /Users/alice/Code/acme/app.swift (commit c4bc89de1180fe83c60eeb25673caab894ec80d4).
        Request: Authorization: Bearer \(Self.oauth)
        Reply to alice@example.com
        """
        let out = FeedbackRedactor.redact(text)
        #expect(out.removed == 1)
        #expect(out.text.contains("/Users/alice/Code/acme/app.swift"))
        #expect(out.text.contains("c4bc89de1180fe83c60eeb25673caab894ec80d4"))
        #expect(out.text.contains("alice@example.com"))
        #expect(!out.text.contains("sk-ant"))
    }

    @Test("the note beside Send counts what came out")
    func note() {
        #expect(FeedbackCopy.removed(0) == nil)
        #expect(FeedbackCopy.removed(1) == "1 token removed")
        #expect(FeedbackCopy.removed(3) == "3 tokens removed")
    }
}

@Suite("Feedback submission: the endpoint's body and the send")
struct FeedbackSubmissionTests {

    private func submission(email: String? = " a@example.com ", installId: String? = nil,
                            devDescribe: String? = nil,
                            attachments: [FeedbackSubmission.Attachment] = []) -> FeedbackSubmission {
        FeedbackSubmission(kind: .problem, message: "It broke", email: email, appVersion: "0.9.4",
                           appBuild: "1780503333", devDescribe: devDescribe, macOS: "26.1", model: "Mac15,9",
                           locale: "en_US", installId: installId, attachments: attachments)
    }

    private func body(_ s: FeedbackSubmission) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: s.jsonBody()) as? [String: Any])
    }

    @Test("the fields the endpoint takes, by name")
    func fields() throws {
        let json = try body(submission(installId: "0D3C8A41-1F2B-4C5D-9E8F-0123456789AB",
                                       devDescribe: "v0.9.4-14-g9eb8c89-dirty",
                                       attachments: [.init(filename: "a.txt", contentType: "text/plain",
                                                           data: Data("hi".utf8))]))
        #expect(json["kind"] as? String == "problem")
        #expect(json["message"] as? String == "It broke")
        #expect(json["email"] as? String == "a@example.com")
        #expect(json["appVersion"] as? String == "0.9.4")
        #expect(json["appBuild"] as? String == "1780503333")
        #expect(json["devDescribe"] as? String == "v0.9.4-14-g9eb8c89-dirty")
        #expect(json["macOS"] as? String == "26.1")
        #expect(json["model"] as? String == "Mac15,9")
        #expect(json["locale"] as? String == "en_US")
        #expect(json["installId"] as? String == "0D3C8A41-1F2B-4C5D-9E8F-0123456789AB")
        let attachments = try #require(json["attachments"] as? [[String: String]])
        #expect(attachments == [["filename": "a.txt", "contentType": "text/plain", "base64": "aGk="]])
    }

    @Test("optional fields are left out, not sent as null")
    func optionalFields() throws {
        let json = try body(submission(email: "  "))
        for key in ["email", "installId", "devDescribe"] { #expect(json[key] == nil, "\(key)") }
        #expect((json["attachments"] as? [Any])?.isEmpty == true)
    }

    @Test("attachments fit: three at most, 10 MB each, 8 MB in all once encoded, accepted types only")
    func attachmentLimits() {
        let mb = 1024 * 1024
        #expect(FeedbackSubmission.encodedSize(3) == 4)
        #expect(FeedbackSubmission.encodedSize(4) == 8)
        #expect(FeedbackSubmission.attachmentsFit(sizes: []))
        #expect(FeedbackSubmission.attachmentsFit(sizes: [mb, 2 * mb, 3 * mb - 4]))
        // 6 MB raw is 8 MB encoded: the cap exactly. A byte more is over.
        #expect(FeedbackSubmission.attachmentsFit(sizes: [6 * mb]))
        #expect(!FeedbackSubmission.attachmentsFit(sizes: [6 * mb + 1]))
        #expect(!FeedbackSubmission.attachmentsFit(sizes: [1, 1, 1, 1]))
        #expect(!FeedbackSubmission.attachmentsFit(sizes: [9 * mb]))
        // An empty file is refused.
        #expect(!FeedbackSubmission.attachmentsFit(sizes: [0]))
        #expect(FeedbackSubmission.maxAttachmentBytes == 8 * mb)
        let png = FeedbackSubmission.Attachment(filename: "w.png", contentType: "image/png", data: Data(count: 10))
        let zip = FeedbackSubmission.Attachment(filename: "x.zip", contentType: "application/zip", data: Data(count: 10))
        #expect(submission(attachments: [png]).attachmentsFit)
        #expect(!submission(attachments: [png, zip]).attachmentsFit)
    }

    @Test("file names are cleaned: no separators, controls or bidi marks, 128 characters with the extension")
    func filenames() {
        #expect(FeedbackSubmission.cleanFilename("pacer.log") == "pacer.log")
        #expect(FeedbackSubmission.cleanFilename("a/b\\c.txt") == "abc.txt")
        #expect(FeedbackSubmission.cleanFilename("evil\u{202E}txt.exe.png") == "eviltxt.exe.png")
        #expect(FeedbackSubmission.cleanFilename("z\u{200B}w\u{FEFF}j\u{2066}.json") == "zwj.json")
        #expect(FeedbackSubmission.cleanFilename("tab\there\u{0085}.txt") == "tabhere.txt")
        #expect(FeedbackSubmission.cleanFilename("\u{202A}") == "attachment")
        #expect(FeedbackSubmission.cleanFilename("..") == "attachment")
        let long = FeedbackSubmission.cleanFilename(String(repeating: "x", count: 300) + ".log")
        #expect(long.count == 128)
        #expect(long.hasSuffix("x.log"))
    }

    @Test("an email is checked for the endpoint's shape before sending")
    func emails() {
        #expect(FeedbackSubmission.isEmail("alice@example.com"))
        #expect(FeedbackSubmission.isEmail("a.b+c@sub.example.co"))
        #expect(!FeedbackSubmission.isEmail("alice"))
        #expect(!FeedbackSubmission.isEmail("alice@example"))
        #expect(!FeedbackSubmission.isEmail("alice @example.com"))
        #expect(!FeedbackSubmission.isEmail("a@b.c"))
        #expect(!FeedbackSubmission.isEmail(String(repeating: "a", count: 250) + "@example.com"))
    }

    @Test("a file's type, as the endpoint accepts it, from its extension")
    func contentTypes() {
        #expect(FeedbackSubmission.contentType(forFileExtension: "png") == "image/png")
        #expect(FeedbackSubmission.contentType(forFileExtension: "JPG") == "image/jpeg")
        #expect(FeedbackSubmission.contentType(forFileExtension: "json") == "application/json")
        #expect(FeedbackSubmission.contentType(forFileExtension: "mov") == "video/quicktime")
        #expect(FeedbackSubmission.contentType(forFileExtension: "txt") == "text/plain")
        #expect(FeedbackSubmission.contentType(forFileExtension: "log") == "text/plain")
        #expect(FeedbackSubmission.contentType(forFileExtension: "zip") == nil)
        #expect(FeedbackSubmission.contentType(forFileExtension: "pdf") == nil)
    }

    @Test("the locale in the endpoint's shape, without @ keywords")
    func locale() {
        #expect(FeedbackSubmission.locale("en_CA") == "en_CA")
        #expect(FeedbackSubmission.locale("en_US@rg=cazzzz") == "en_US")
        #expect(FeedbackSubmission.locale("zh-Hans_CN") == "zh-Hans_CN")
        #expect(FeedbackSubmission.locale("") == nil)
        #expect(FeedbackSubmission.locale("not a locale") == nil)
        #expect(submission().locale == "en_US")
    }

    @Test("a POST of JSON to the site's endpoint")
    func request() throws {
        let request = try submission().request(userAgent: "Pacer/0.9.4")
        #expect(request.url?.absoluteString == "https://pacer.andrechek.com/api/feedback")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Pacer/0.9.4")
        #expect(request.httpBody != nil)
    }

    private static func respond(_ status: Int, _ body: String = #"{"ok":true}"#) -> FeedbackSender.Transport {
        { request in
            (Data(body.utf8),
             HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func send(_ status: Int, _ body: String = #"{"ok":true}"#) async -> FeedbackSender.Outcome {
        await FeedbackSender.send(submission(), userAgent: "Pacer/0.9.4", transport: Self.respond(status, body))
    }

    @Test("what the endpoint answers, as the window acts on it")
    func outcomes() async {
        #expect(await send(200) == .sent)
        #expect(await send(400, #"{"ok":false,"error":"email is not an email address"}"#)
                == .refused("email is not an email address"))
        #expect(await send(400, "not json") == .refused("the report was refused"))
        #expect(await send(429, #"{"ok":false,"error":"Sentry is rate limiting reports"}"#) == .rateLimited)
        for status in [403, 413, 415, 502, 503] {
            #expect(await send(status, #"{"ok":false,"error":"x"}"#) == .failed(status: status))
        }
        let offline: FeedbackSender.Transport = { _ in throw URLError(.notConnectedToInternet) }
        #expect(await FeedbackSender.send(submission(), userAgent: "Pacer/0.9.4", transport: offline)
                == .failed(status: nil))
    }

    @Test("what the window says for each")
    func failureCopy() {
        #expect(FeedbackCopy.failure(.sent) == nil)
        #expect(FeedbackCopy.failure(.refused("email is not an email address"))
                == "Couldn't send: email is not an email address.")
        #expect(FeedbackCopy.failure(.rateLimited) == "Too many reports right now. Try again later.")
        #expect(FeedbackCopy.failure(.failed(status: 502)) == "Couldn't send.")
        #expect(FeedbackCopy.tooLarge == "Over 8 MB in all. Remove a file, or open a GitHub issue.")
    }

    @Test("every field passes the endpoint's own shape checks")
    func endpointShapes() throws {
        let release = AppVersionLabel(info: ["CFBundleShortVersionString": "0.9.4", "CFBundleVersion": "1780503333"],
                                      isDebugBuild: false)
        let dev = AppVersionLabel(info: [AppVersionLabel.describeKey: "v0.9.4-14-g9eb8c89",
                                         AppVersionLabel.shaKey: "9eb8c89aa", AppVersionLabel.dirtyKey: "1"],
                                  isDebugBuild: true)
        let noTag = AppVersionLabel(info: [AppVersionLabel.shaKey: "9eb8c89aa"], isDebugBuild: true)
        // site/worker/feedback.ts: SHORT_VERSION and DEV_DESCRIBE.
        let shortVersion = #"^\d{1,4}\.\d{1,4}\.\d{1,4}(?:-[0-9A-Za-z][0-9A-Za-z.-]*)?$"#
        let devDescribe = #"^[0-9A-Za-z][0-9A-Za-z._+-]{0,79}$"#
        for label in [release, dev, noTag] {
            #expect(label.reportVersion.range(of: shortVersion, options: .regularExpression) != nil, "\(label)")
            if let describe = label.reportDescribe {
                #expect(describe.range(of: devDescribe, options: .regularExpression) != nil, "\(describe)")
            }
        }
    }
}
