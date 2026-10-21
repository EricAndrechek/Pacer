import Foundation
@testable import PacerPace

/// A scratch directory holding a `metrics` fixture, which `PACER_API=file://…`
/// serves, and the run's state file.
final class PaceSandbox: Sendable {
    let dir: URL
    init(metrics: String?) throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let metrics { try setMetrics(metrics) }
    }
    deinit { try? FileManager.default.removeItem(at: dir) }

    var metricsURL: URL { dir.appendingPathComponent("metrics") }
    var stateURL: URL { dir.appendingPathComponent("state.json") }
    var stateText: String { (try? String(contentsOf: stateURL, encoding: .utf8)) ?? "" }

    func setMetrics(_ text: String) throws {
        try text.write(to: metricsURL, atomically: true, encoding: .utf8)
    }
}

struct PaceResult {
    let status: Int32
    let out: String
}

/// Output in the order it was written, stdout and stderr together, the way the
/// script's tests read it from one pipe.
final class PaceCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    func append(_ s: String) { lock.withLock { buffer += s } }
    var text: String { lock.withLock { buffer } }
}

/// Run `pace` in-process against a sandbox. The environment is built from
/// scratch, so the session running the tests (whose own
/// `CLAUDE_CODE_SESSION_ID` is set) cannot leak into them.
///
/// `sleep` replaces the real one: a `wait` that sleeps calls it with the
/// count so far, which is where a test changes the world between two polls.
/// More than 50 sleeps ends the wait by giving it headroom and records the
/// overrun, so a wait that misses its cue fails instead of spinning.
///
/// `onGet` sees every request (to count reads of Pacer), and `nap` replaces
/// the short pause a `status` takes while another reader refreshes. `later`
/// runs the command that many seconds from now, for a verdict's expiry.
func runPace(_ box: PaceSandbox, _ args: [String], api: String? = nil,
             unsetState: Bool = false, extra: [String: String] = [:],
             later: TimeInterval = 0,
             onSleep: ((Int) -> Void)? = nil,
             onGet: ((URLRequest) -> Void)? = nil,
             nap: ((TimeInterval) -> Void)? = nil) -> PaceResult {
    var env = ["HOME": box.dir.path, "PATH": "/usr/bin:/bin"]
    env["PACER_API"] = api ?? "file://\(box.dir.path)"
    if !unsetState { env["PACE_STATE"] = box.stateURL.path }
    for (key, value) in extra { env[key] = value }
    let capture = PaceCapture()
    var sleeps = 0
    let io = PaceIO(
        out: capture.append, err: capture.append, now: { Date().addingTimeInterval(later) },
        sleep: { _ in
            sleeps += 1
            onSleep?(sleeps)
            if sleeps > 50 {
                capture.append("TEST: wait overran 50 polls\n")
                try? box.setMetrics("pacer_rate_limit_used_ratio{account=\"x\",window=\"five_hour\"} 0\n")
            }
        },
        get: { request in
            onGet?(request)
            return PaceHTTP.get(request)
        },
        gitBranch: { _ in nil },
        nap: nap ?? { Thread.sleep(forTimeInterval: $0) })
    let status = Pace.run(args, environment: env, io: io)
    return PaceResult(status: status, out: capture.text)
}

/// Requests seen, from any thread.
final class PaceRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func record(_ request: URLRequest) {
        lock.withLock { paths.append(request.url?.lastPathComponent ?? "") }
    }
    var all: [String] { lock.withLock { paths } }
    func count(_ last: String) -> Int { all.filter { $0 == last }.count }
}

/// Rewrite a state file's `updatedAt` to `seconds` ago.
func age(_ box: PaceSandbox, by seconds: TimeInterval) throws {
    let then = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-seconds))
    let rewritten = box.stateText.replacingOccurrences(
        of: #""updatedAt": "[^"]+""#, with: #""updatedAt": "\#(then)""#, options: .regularExpression)
    try rewritten.write(to: box.stateURL, atomically: true, encoding: .utf8)
}

/// The smallest HTTP server that answers one status to every path. `file`,
/// when given, is re-read on every request instead of `body`. Binds port 0 and
/// prints the port it got, so parallel tests never share one.
final class PaceStubServer {
    private let task: Process
    let base: String

    enum StartFailure: Error { case neverListened(afterSeconds: Int) }

    init(status: Int, body: String, file: URL? = nil) throws {
        let payload = file.map { "open(\"\($0.path)\", \"rb\").read()" }
            ?? "b\"\"\"\(body)\"\"\""
        // `HTTPServer.server_bind` names the server with `socket.getfqdn`, a
        // reverse DNS lookup of 127.0.0.1. On CI runners it takes tens of
        // seconds, and each server's test held a cooperative thread for all
        // of it. On a 3-core runner that saturated the pool for minutes (#328's
        // CI hang). `S` binds the same socket without the lookup.
        let script = """
        import socketserver
        from http.server import BaseHTTPRequestHandler, HTTPServer
        class H(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(\(status))
                self.send_header("Content-Type", "text/plain")
                self.end_headers()
                self.wfile.write(\(payload))
            def log_message(self, *a): pass
        class S(HTTPServer):
            def server_bind(self):
                socketserver.TCPServer.server_bind(self)
                self.server_name, self.server_port = "127.0.0.1", self.server_address[1]
        server = S(("127.0.0.1", 0), H)
        print(server.server_port, flush=True)
        server.serve_forever()
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", script]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Waits for the port with a deadline. `availableData` alone blocks a
        // cooperative thread until Python prints or exits, so a server that
        // did neither would hang the run instead of failing the test.
        var line = Data()
        let reader = out.fileHandleForReading
        let started = Date()
        let deadline = started.addingTimeInterval(60)
        while !line.contains(UInt8(ascii: "\n")) {
            var ready = pollfd(fd: reader.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let remaining = Int32(deadline.timeIntervalSinceNow * 1000)
            guard remaining > 0, poll(&ready, 1, remaining) > 0 else { break }
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            line.append(chunk)
        }
        guard let port = String(data: line, encoding: .utf8)
            .flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        else {
            process.terminate()
            throw StartFailure.neverListened(afterSeconds: Int(Date().timeIntervalSince(started)))
        }
        task = process
        base = "http://127.0.0.1:\(port)"
    }

    func stop() { task.terminate() }
}

/// The fixtures the bash script's tests used, shared by the port's tests and
/// the parity harness.
enum PaceFixtures {
    /// One 5-hour block with headroom, a 7-day block, and a scoped per-model
    /// cap over any sane threshold, plus a second login.
    static let metrics = """
    # HELP pacer_rate_limit_used_ratio Current rate-limit utilization (0–1).
    # TYPE pacer_rate_limit_used_ratio gauge
    pacer_rate_limit_used_ratio{account="org-work",window="five_hour"} 0.12
    pacer_rate_limit_used_ratio{account="org-work",window="seven_day"} 0.32
    pacer_rate_limit_used_ratio{account="org-work",window="weekly_scoped|Fable|"} 0.95
    pacer_rate_limit_used_ratio{account="org-home",window="five_hour"} 0.88
    # HELP pacer_rate_limit_reset_seconds Seconds until the rate-limit window resets.
    # TYPE pacer_rate_limit_reset_seconds gauge
    pacer_rate_limit_reset_seconds{account="org-work",window="five_hour"} 6000
    pacer_rate_limit_reset_seconds{account="org-work",window="seven_day"} 321340
    pacer_rate_limit_reset_seconds{account="org-work",window="weekly_scoped|Fable|"} 321340
    pacer_rate_limit_reset_seconds{account="org-home",window="five_hour"} 300
    # HELP pacer_account_info Account identity; value is always 1.
    # TYPE pacer_account_info gauge
    pacer_rate_limit_will_hit{account="org-work",window="five_hour"} 1
    pacer_rate_limit_hit_eta_seconds{account="org-work",window="five_hour"} 2700
    pacer_rate_limit_burn_percent_per_hour{account="org-work",window="five_hour"} 24
    pacer_account_info{account="org-work",name="Account work",active="true"} 1
    pacer_account_info{account="org-home",name="Account home",active="false"} 1
    pacer_up 1
    """
}
