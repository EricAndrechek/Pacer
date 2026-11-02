import Foundation
import Testing
import PacerCore
@testable import PacerPace

/// The CLI's run log (start/end lines per command) and `pacer feedback`'s
/// send to Sentry, both with the file and the network injected.
@Suite("pace telemetry")
struct PaceTelemetryTests {

    static let dsn = "https://abc123@o1.ingest.example.invalid/42"

    final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        func add(_ r: URLRequest) { lock.withLock { requests.append(r) } }
        var all: [URLRequest] { lock.withLock { requests } }
    }

    static func io(_ box: PaceSandbox, capture: PaceCapture, sent: Sent, dsn: String? = dsn,
                   enabled: Bool = true, succeed: Bool = true,
                   source: CLIRunLog.Source = .none) -> PaceIO {
        PaceIO(out: capture.append, err: capture.append, now: Date.init, sleep: { _ in },
               get: { PaceHTTP.get($0) }, gitBranch: { _ in nil },
               telemetry: PaceTelemetry(dsn: dsn, release: "com.example.pacer@1.2.3+4",
                                        environment: "production", installId: "install-1",
                                        enabled: { enabled },
                                        send: { sent.add($0); return succeed }),
               source: { source })
    }

    static func env(_ box: PaceSandbox, extra: [String: String] = [:]) -> [String: String] {
        var e = ["HOME": box.dir.path, "PATH": "/usr/bin:/bin", "PACE_STATE": box.stateURL.path,
                 "PACER_API": "file://\(box.dir.path)"]
        for (k, v) in extra { e[k] = v }
        return e
    }

    // MARK: - Run log

    @Test func aRunWritesAStartAndAnEndLine() throws {
        let box = try PaceSandbox(metrics: nil)
        let log = box.dir.appendingPathComponent("cli-runs.log")
        let capture = PaceCapture()
        let code = Pace.runLogged(["status", "--no-refresh"], environment: Self.env(box),
                                  io: Self.io(box, capture: capture, sent: Sent(), source: .offline),
                                  logURL: log)
        #expect(code == 3)
        let lines = CLIRunLog.lines(at: log)
        #expect(lines.map(\.kind) == [.start, .end])
        #expect(lines.map(\.subcommand) == ["status", "status"])
        #expect(lines[0].runId == lines[1].runId)
        #expect(lines[1].exitCode == 3)
        #expect(lines[1].source == "offline")
        #expect((lines[1].milliseconds ?? -1) >= 0)
    }

    @Test func noArgumentsIsReportAndUnknownNamesAreOther() throws {
        let box = try PaceSandbox(metrics: nil)
        let log = box.dir.appendingPathComponent("cli-runs.log")
        let capture = PaceCapture()
        _ = Pace.runLogged([], environment: Self.env(box),
                           io: Self.io(box, capture: capture, sent: Sent()), logURL: log)
        _ = Pace.runLogged(["/Users/someone/secret"], environment: Self.env(box),
                           io: Self.io(box, capture: capture, sent: Sent()), logURL: log)
        let names = CLIRunLog.lines(at: log).filter { $0.kind == .start }.map(\.subcommand)
        #expect(names == ["report", "other"])
        let raw = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        #expect(!raw.contains("secret"))
    }

    @Test func helpIsNotLogged() throws {
        let box = try PaceSandbox(metrics: nil)
        let log = box.dir.appendingPathComponent("cli-runs.log")
        let capture = PaceCapture()
        _ = Pace.runLogged(["gate", "--help"], environment: Self.env(box),
                           io: Self.io(box, capture: capture, sent: Sent()), logURL: log)
        _ = Pace.runLogged(["help"], environment: Self.env(box),
                           io: Self.io(box, capture: capture, sent: Sent()), logURL: log)
        #expect(!FileManager.default.fileExists(atPath: log.path))
    }

    // MARK: - Feedback

    @Test func feedbackSendsByDefaultAndSaysSo() throws {
        let box = try PaceSandbox(metrics: nil)
        let sent = Sent(), capture = PaceCapture()
        let code = Pace.run(["feedback", "gate said go at 99%"], environment: Self.env(box),
                            io: Self.io(box, capture: capture, sent: sent))
        #expect(code == 0)
        let request = try #require(sent.all.first)
        #expect(sent.all.count == 1)
        #expect(request.url?.absoluteString == "https://o1.ingest.example.invalid/api/42/envelope/")
        #expect(request.timeoutInterval == 3)
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("gate said go at 99%"))
        #expect(body.contains("install-1"))
        #expect(capture.text.contains("sent to Pacer's issue tracker"))
        #expect(capture.text.contains("--local"))
        // The local copy is still written first.
        let inbox = box.dir.appendingPathComponent(".claude/pace/feedback.jsonl")
        #expect(FileManager.default.fileExists(atPath: inbox.path))
    }

    @Test func localFlagEnvAndToggleSendNothing() throws {
        let cases: [(args: [String], extra: [String: String], enabled: Bool)] = [
            (["feedback", "--local", "text"], [:], true),
            (["feedback", "text"], ["PACER_FEEDBACK": "local"], true),
            (["feedback", "text"], [:], false),
        ]
        for c in cases {
            let box = try PaceSandbox(metrics: nil)
            let sent = Sent(), capture = PaceCapture()
            let code = Pace.run(c.args, environment: Self.env(box, extra: c.extra),
                                io: Self.io(box, capture: capture, sent: sent, enabled: c.enabled))
            #expect(code == 0)
            #expect(sent.all.isEmpty, "\(c.args) \(c.extra)")
            #expect(capture.text.contains("nothing was sent anywhere"))
            #expect(capture.text.contains("To file it as an issue"))
            // `--local` is a flag, not part of the report.
            let inbox = try String(contentsOf: box.dir.appendingPathComponent(".claude/pace/feedback.jsonl"),
                                   encoding: .utf8)
            #expect(!inbox.contains("--local"))
        }
    }

    @Test func noDSNSendsNothing() throws {
        let box = try PaceSandbox(metrics: nil)
        let sent = Sent(), capture = PaceCapture()
        _ = Pace.run(["feedback", "text"], environment: Self.env(box),
                     io: Self.io(box, capture: capture, sent: sent, dsn: ""))
        #expect(sent.all.isEmpty)
        #expect(capture.text.contains("nothing was sent anywhere"))
    }

    @Test func aFailedSendFallsBackToTheLinkAndStillSucceeds() throws {
        let box = try PaceSandbox(metrics: nil)
        let sent = Sent(), capture = PaceCapture()
        let code = Pace.run(["feedback", "text"], environment: Self.env(box),
                            io: Self.io(box, capture: capture, sent: sent, succeed: false))
        #expect(code == 0)
        #expect(sent.all.count == 1)
        #expect(capture.text.contains("could not be sent"))
        #expect(capture.text.contains("https://github.com/EricAndrechek/Pacer/issues/new?title="))
    }

    @Test func theSentMessageIsScrubbed() throws {
        let box = try PaceSandbox(metrics: nil)
        let sent = Sent(), capture = PaceCapture()
        _ = Pace.run(["feedback", "it failed reading /Users/fictional/work/notes.txt"],
                     environment: Self.env(box), io: Self.io(box, capture: capture, sent: sent))
        let body = String(decoding: try #require(sent.all.first).httpBody ?? Data(), as: UTF8.self)
        #expect(!body.contains("fictional"))
        #expect(body.contains("it failed reading"))
    }
}
