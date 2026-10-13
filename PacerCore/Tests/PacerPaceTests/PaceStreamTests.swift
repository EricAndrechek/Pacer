import Foundation
import Testing
@testable import PacerPace

/// #256: a sleeping `wait` wakes when Pacer pushes an event, and sleeps its
/// full interval when there is no stream.
@Suite("pace: waking on the stream")
struct PaceStreamTests {

    /// A one-endpoint SSE server: `/v1/stream` sends headers, then `event`
    /// after `delay` seconds, then holds the connection open. Prints its port.
    private final class StubStream {
        let process = Process()
        let base: String
        init(event: String, delay: Double) throws {
            let script = """
            import http.server, socketserver, sys, time
            class H(http.server.BaseHTTPRequestHandler):
                def log_message(self, *a): pass
                def do_GET(self):
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.end_headers()
                    self.wfile.write(b": hello\\n\\n"); self.wfile.flush()
                    time.sleep(\(delay))
                    self.wfile.write(b"event: \(event)\\ndata: {}\\n\\n"); self.wfile.flush()
                    time.sleep(30)
            s = socketserver.ThreadingTCPServer(("127.0.0.1", 0), H)
            print(s.server_address[1], flush=True)
            s.serve_forever()
            """
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-c", script]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            try process.run()
            let line = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            base = "http://127.0.0.1:\(line)"
        }
        deinit { process.terminate() }
    }

    @Test("an account event cuts the sleep short")
    func wakesOnAnEvent() throws {
        let stub = try StubStream(event: "account", delay: 0.5)
        let stream = try #require(PaceStream(apiBase: stub.base, token: nil))
        let started = Date()
        stream.sleep(20)
        #expect(Date().timeIntervalSince(started) < 5, "woke on the event, not after 20 s")
    }

    @Test("an event it does not care about does not")
    func ignoresOtherEvents() throws {
        let stub = try StubStream(event: "keepalive-ish", delay: 0.2)
        let stream = try #require(PaceStream(apiBase: stub.base, token: nil))
        let started = Date()
        stream.sleep(1.5)
        #expect(Date().timeIntervalSince(started) >= 1.4)
    }

    @Test("no stream: the full interval, as before")
    func sleepsFullyWithoutAStream() throws {
        let stream = try #require(PaceStream(apiBase: "http://127.0.0.1:1", token: nil))
        let started = Date()
        stream.sleep(1)
        #expect(Date().timeIntervalSince(started) >= 0.9)
        #expect(PaceStream(apiBase: "http://pacer.invalid:7223", token: nil) == nil, "loopback only")
    }
}
